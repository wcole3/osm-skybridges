#!/usr/bin/env python3
"""Live config tuner for the skybridge pipeline (`make tuner`).

Serves the deck.gl viewer (web/) on http://127.0.0.1:8000 plus a small /api/*
for the tuning panel. stdlib only — no pip.

SANDBOX-FIRST: knob experiments run against a separate DATABASE (osm_sandbox,
same cluster) seeded with a focus-radius subset of the live raw import, and
export to web/data/sandbox/. The live database, live web/data/*.geojson and
sql/01_prepare.sql are only touched by the explicit "Apply to real dataset" /
"Save as defaults" actions. Database-level isolation is deliberate: the
pipeline's unqualified DROP TABLEs make schema/search_path isolation unsafe.

API:
  GET  /api/config   -> {sandbox_ready, state..., knobs:[{key,value,file_default,dirty,stage,min,max,step,descr}]}
  GET  /api/status   -> {state: idle|running|error, mode, stage, run_seq, error_tail, dirty}
  POST /api/set      {key, value}  queue a sandbox re-derive (stage-scoped, coalescing)
  POST /api/apply    push all overrides to the LIVE db, re-derive + re-export live
  POST /api/save     persist overrides into sql/01_prepare.sql (same rewrite as `make tune`)
  POST /api/revert   reset overrides + sandbox config to file defaults, re-derive sandbox
  POST /api/reseed   rebuild the sandbox database from the live raw tables
"""
import json
import os
import subprocess
import sys
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

from configfile import ROOT, file_defaults, fmt_num, rewrite_default

WEB = os.path.join(ROOT, 'web')

PGURI = os.environ.get('PGURI', 'postgresql://osm:osm@localhost:5439/osm')
SANDBOX_DB = 'osm_sandbox'
SANDBOX_URI = PGURI.rsplit('/', 1)[0] + '/' + SANDBOX_DB
SRID = os.environ.get('SRID', '0') or '0'
CLON = os.environ.get('CLON', '-77.0230')
CLAT = os.environ.get('CLAT', '38.9051')
CRADIUS = os.environ.get('CRADIUS', '2600')
SANDBOX_RADIUS = os.environ.get('SANDBOX_RADIUS') or CRADIUS
# 'real' (default): sandbox = focus-radius COPY of the live raw import.
# 'sample' (make tuner-sample): sandbox = synthetic fixtures from
# sql/96_sample_data.sql — instant feedback, no live data/ingest required.
TUNER_DATA = os.environ.get('TUNER_DATA', 'real')

# stage -> pipeline files that must re-run (order matters; 99 always gates).
# 02 and 03 both feed cand_raw, so 'detect' re-runs from 02 (03 alone would
# duplicate candidate rows).
STAGE_SQL = {
    'prepare':  ['01_prepare.sql', '02_detect_tagged.sql', '03_detect_geometry.sql',
                 '04_score_dedupe.sql', '05_correct.sql', '06_finalize.sql', '99_selfcheck.sql'],
    'detect':   ['02_detect_tagged.sql', '03_detect_geometry.sql',
                 '04_score_dedupe.sql', '05_correct.sql', '06_finalize.sql', '99_selfcheck.sql'],
    'correct':  ['05_correct.sql', '06_finalize.sql', '99_selfcheck.sql'],
    'finalize': ['06_finalize.sql', '99_selfcheck.sql'],
    'export':   [],
}
STAGE_ORDER = ['export', 'finalize', 'correct', 'detect', 'prepare']  # light -> heavy
# stage -> (export sql, output file) pairs to refresh afterwards. The config
# snapshot rides along on EVERY stage — knob values changed by definition.
CONFIG_EXPORT = ('97_export_config.sql', 'config.json')
EXPORTS_ALL = [
    ('90_export_buildings.sql', 'buildings.geojson'),
    ('92_export_corrected_buildings.sql', 'buildings_corrected.geojson'),
    ('90_export_skybridges.sql', 'skybridges.geojson'),
    ('93_export_cuts.sql', 'cuts.geojson'),
]
STAGE_EXPORTS = {
    'prepare':  EXPORTS_ALL + [CONFIG_EXPORT],
    'detect':   EXPORTS_ALL[1:] + [CONFIG_EXPORT],
    'correct':  EXPORTS_ALL[1:] + [CONFIG_EXPORT],
    'finalize': EXPORTS_ALL[1:] + [CONFIG_EXPORT],
    'export':   EXPORTS_ALL[:2] + [CONFIG_EXPORT],
}


PSQL_ENV = {**os.environ, 'PGCONNECT_TIMEOUT': '5'}   # fail fast when db is down


def psql(uri, args, sql_file=None, cmd=None, extra_vars=None, capture=True):
    """Run psql against `uri`; returns CompletedProcess."""
    argv = ['psql', uri, '-v', 'ON_ERROR_STOP=1', '-v', f'srid={SRID}']
    for k, v in (extra_vars or {}).items():
        argv += ['-v', f'{k}={v}']
    if sql_file:
        argv += ['-f', sql_file]
    if cmd:
        argv += ['-c', cmd]
    argv += args
    return subprocess.run(argv, capture_output=capture, text=True, env=PSQL_ENV)


def q(uri, sql):
    """One-shot query -> list of | -split rows. Raises on error."""
    p = psql(uri, ['-At'], cmd=sql)
    if p.returncode != 0:
        raise RuntimeError(p.stderr.strip())
    return [line.split('|') for line in p.stdout.splitlines() if line]


# file_defaults / rewrite_default / fmt_num come from pipeline/configfile.py —
# shared with `make config-load`, so every settings-writing path emits the
# same bytes into sql/01_prepare.sql.


class Engine:
    """Single worker; one pending slot; jobs coalesce (latest wins, heaviest
    stage wins). Never runs two psql pipelines concurrently."""

    def __init__(self):
        self.lock = threading.Lock()
        self.wake = threading.Condition(self.lock)
        self.pending = None          # {'stage': str, 'target': 'sandbox'|'live'}
        self.overrides = {}          # key -> value (the session's tuned values)
        self.state = 'idle'          # idle | running | error
        self.mode = 'sandbox'
        self.stage = ''
        self.run_seq = 0
        self.error_tail = ''
        self.last_secs = 0.0
        self.meta = {}               # key -> {stage,min,max,step,descr}
        threading.Thread(target=self._worker, daemon=True).start()

    # ── job intake ──────────────────────────────────────────────────────────
    def submit(self, stage, target='sandbox'):
        """One pending slot; jobs coalesce. Stage: heavier wins. Target
        precedence: reseed > live > sandbox (a queued apply/reseed must not be
        downgraded by a slider event; overrides are read at run time anyway)."""
        rank = {'sandbox': 0, 'live': 1, 'reseed': 2}
        with self.wake:
            if self.pending:
                stage = max(self.pending['stage'], stage, key=STAGE_ORDER.index)
                target = max(self.pending['target'], target, key=rank.__getitem__)
            self.pending = {'stage': stage, 'target': target}
            self.wake.notify()

    # ── worker ───────────────────────────────────────────────────────────────
    def _worker(self):
        while True:
            with self.wake:
                while not self.pending:
                    self.wake.wait()
                job = self.pending
                self.pending = None
                self.state, self.mode, self.stage = 'running', job['target'], job['stage']
                self.error_tail = ''
            t0 = time.time()
            try:
                if job['target'] == 'reseed':
                    seed_sandbox()
                    self._run('prepare', SANDBOX_URI, sandbox_dir())
                else:
                    uri = SANDBOX_URI if job['target'] == 'sandbox' else PGURI
                    out = sandbox_dir() if job['target'] == 'sandbox' else os.path.join(WEB, 'data')
                    self._run(job['stage'], uri, out)
                with self.lock:
                    self.state, self.run_seq = 'idle', self.run_seq + 1
                    self.last_secs = time.time() - t0
            except Exception as e:  # selfcheck failure or psql error
                with self.lock:
                    self.state = 'error'
                    self.error_tail = str(e)[-2000:]

    def _apply_overrides(self, uri):
        if not self.overrides:
            return
        sets = '; '.join(
            f"UPDATE config SET value={fmt_num(v)} WHERE key='{k}'" for k, v in self.overrides.items())
        p = psql(uri, [], cmd=sets)
        if p.returncode != 0:
            raise RuntimeError(p.stderr)

    def _run(self, stage, uri, outdir):
        """UPDATE config -> stage sql (ON_ERROR_STOP; 99 gates) -> exports."""
        self._apply_overrides(uri)
        for f in STAGE_SQL[stage]:
            p = psql(uri, [], sql_file=os.path.join(ROOT, 'sql', f))
            if p.returncode != 0:
                raise RuntimeError(f'{f} failed:\n' + (p.stderr or p.stdout)[-2000:])
            if f == '01_prepare.sql':
                # 01 drops + recreates config -> re-impose the session's values
                self._apply_overrides(uri)
        os.makedirs(outdir, exist_ok=True)
        ev = {'clon': CLON, 'clat': CLAT, 'radius': CRADIUS}
        for f, name in STAGE_EXPORTS[stage]:
            p = psql(uri, ['-At'], sql_file=os.path.join(ROOT, 'sql', f), extra_vars=ev)
            if p.returncode != 0:
                raise RuntimeError(f'{f} failed:\n' + p.stderr[-2000:])
            tmp = os.path.join(outdir, name + '.tmp')
            with open(tmp, 'w') as fh:
                fh.write(p.stdout)
            os.replace(tmp, os.path.join(outdir, name))  # atomic: never half-read
        if uri == PGURI:  # applying live: refresh the QA queue too
            p = psql(uri, ['-At'], sql_file=os.path.join(ROOT, 'sql', '91_export_qa.sql'))
            if p.returncode == 0:
                tmp = os.path.join(ROOT, 'qa', 'qa_flags.geojson.tmp')
                with open(tmp, 'w') as fh:
                    fh.write(p.stdout)
                os.replace(tmp, os.path.join(ROOT, 'qa', 'qa_flags.geojson'))

    # ── views ────────────────────────────────────────────────────────────────
    def status(self):
        with self.lock:
            return {'state': self.state, 'mode': self.mode, 'stage': self.stage,
                    'run_seq': self.run_seq, 'error_tail': self.error_tail,
                    'last_secs': round(self.last_secs, 1),
                    'dirty': sorted(self.overrides)}

    def config_view(self):
        defaults = file_defaults()
        rows = q(SANDBOX_URI,
                 "SELECT c.key, c.value, m.stage, m.min, m.max, m.step, m.descr "
                 "FROM config c JOIN config_meta m USING (key) ORDER BY m.stage, c.key")
        knobs = []
        for key, val, stage, mn, mx, step, descr in rows:
            val = self.overrides.get(key, float(val))
            fd = defaults.get(key)
            knobs.append({'key': key, 'value': val, 'file_default': fd,
                          'dirty': fd is None or abs(val - fd) > 1e-9,
                          'stage': stage, 'min': float(mn), 'max': float(mx),
                          'step': float(step), 'descr': descr})
        return {'sandbox': True, 'data_mode': TUNER_DATA, 'radius': SANDBOX_RADIUS,
                **self.status(), 'knobs': knobs}


def sandbox_dir():
    return os.path.join(WEB, 'data', 'sandbox')


def sandbox_ready():
    """Sandbox exists, is derived, AND was seeded with the same data mode —
    otherwise `make tuner` after `make tuner-sample` (or vice versa) would
    silently serve the wrong dataset."""
    try:
        q(SANDBOX_URI, 'SELECT 1 FROM buildings_final LIMIT 1')
        return q(SANDBOX_URI, 'SELECT data_mode FROM sandbox_meta')[0][0] == TUNER_DATA
    except Exception:
        return False


def seed_sandbox():
    """(Re)build osm_sandbox: raw tables + either a focus-radius COPY of the
    live import (TUNER_DATA=real) or the synthetic fixtures (=sample)."""
    what = ('synthetic fixtures' if TUNER_DATA == 'sample'
            else f'radius {SANDBOX_RADIUS} m around {CLON},{CLAT}')
    print(f'[tuner] seeding sandbox ({what}) …', flush=True)
    for cmd in (f'DROP DATABASE IF EXISTS {SANDBOX_DB} WITH (FORCE)',
                f'CREATE DATABASE {SANDBOX_DB}'):
        p = psql(PGURI, [], cmd=cmd)
        if p.returncode != 0:
            raise RuntimeError(p.stderr)
    for f in ('95_sandbox_seed.sql', '00_init.sql'):   # raw tables + helper fns
        p = psql(SANDBOX_URI, [], sql_file=os.path.join(ROOT, 'sql', f))
        if p.returncode != 0:
            raise RuntimeError(p.stderr)
    if TUNER_DATA == 'sample':
        p = psql(SANDBOX_URI, [], sql_file=os.path.join(ROOT, 'sql', '96_sample_data.sql'),
                 extra_vars={'clon': CLON, 'clat': CLAT})
        if p.returncode != 0:
            raise RuntimeError(p.stderr)
    else:
        # text COPY pipe: geometry travels as hex EWKB — safe across databases
        # (binary COPY is not: type OIDs differ per database).
        where = (f"ST_DWithin(geom::geography, "
                 f"ST_SetSRID(ST_MakePoint({CLON}, {CLAT}), 4326)::geography, {SANDBOX_RADIUS})")
        for table, cols in (('osm_polygons', 'osm_id, tags, geom, osm_type'),
                            ('osm_lines', 'osm_id, tags, geom')):
            src = subprocess.Popen(
                ['psql', PGURI, '-v', 'ON_ERROR_STOP=1',
                 '-c', f'COPY (SELECT {cols} FROM {table} WHERE {where}) TO STDOUT'],
                stdout=subprocess.PIPE, env=PSQL_ENV)
            dst = subprocess.run(
                ['psql', SANDBOX_URI, '-v', 'ON_ERROR_STOP=1',
                 '-c', f'COPY {table} ({cols}) FROM STDIN'],
                stdin=src.stdout, capture_output=True, text=True, env=PSQL_ENV)
            src.stdout.close()
            if src.wait() != 0 or dst.returncode != 0:
                raise RuntimeError(f'seeding {table} failed: {dst.stderr}')
    p = psql(SANDBOX_URI, [], cmd=("DROP TABLE IF EXISTS sandbox_meta; "
             f"CREATE TABLE sandbox_meta AS SELECT '{TUNER_DATA}'::text AS data_mode"))
    if p.returncode != 0:
        raise RuntimeError(p.stderr)
    n = q(SANDBOX_URI, 'SELECT count(*) FROM osm_polygons')[0][0]
    print(f'[tuner] sandbox seeded: {n} polygons', flush=True)


ENGINE = Engine()


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=WEB, **kw)

    def log_message(self, fmt, *args):  # quieter: only API + errors
        if '/api/' in (args[0] if args else ''):
            sys.stderr.write('[tuner] %s\n' % (fmt % args))

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.split('?')[0] == '/api/config':
            try:
                return self._json(ENGINE.config_view())
            except Exception as e:
                return self._json({'error': str(e)}, 500)
        if self.path.split('?')[0] == '/api/status':
            return self._json(ENGINE.status())
        return super().do_GET()

    def do_POST(self):
        path = self.path.split('?')[0]
        try:
            n = int(self.headers.get('Content-Length') or 0)
            body = json.loads(self.rfile.read(n) or b'{}') if n else {}
        except Exception:
            return self._json({'error': 'bad json'}, 400)
        try:
            if path == '/api/set':
                key, val = body.get('key'), float(body.get('value'))
                meta = ENGINE.meta.get(key)
                if not meta:
                    return self._json({'error': f'unknown key {key!r}'}, 400)
                val = min(max(val, meta['min']), meta['max'])
                ENGINE.overrides[key] = val
                ENGINE.submit(meta['stage'], 'sandbox')
                return self._json({'ok': True, 'value': val})
            if path == '/api/apply':
                if not ENGINE.overrides:
                    return self._json({'error': 'nothing to apply'}, 400)
                stage = max((ENGINE.meta[k]['stage'] for k in ENGINE.overrides
                             if k in ENGINE.meta), key=STAGE_ORDER.index, default='correct')
                ENGINE.submit(stage, 'live')
                return self._json({'ok': True, 'stage': stage})
            if path == '/api/save':
                for k, v in ENGINE.overrides.items():
                    rewrite_default(k, v)
                return self._json({'ok': True, 'saved': sorted(ENGINE.overrides)})
            if path == '/api/revert':
                defaults = file_defaults()
                stages = [ENGINE.meta[k]['stage'] for k in ENGINE.overrides if k in ENGINE.meta]
                ENGINE.overrides = {}
                sets = '; '.join(f"UPDATE config SET value={fmt_num(v)} WHERE key='{k}'"
                                 for k, v in defaults.items())
                p = psql(SANDBOX_URI, [], cmd=sets)
                if p.returncode != 0:
                    return self._json({'error': p.stderr}, 500)
                ENGINE.submit(max(stages, key=STAGE_ORDER.index) if stages else 'correct', 'sandbox')
                return self._json({'ok': True})
            if path == '/api/reseed':
                ENGINE.submit('prepare', 'reseed')
                return self._json({'ok': True})
        except Exception as e:
            return self._json({'error': str(e)}, 500)
        return self._json({'error': 'unknown endpoint'}, 404)


def main():
    # Preflight — fail fast with a real message instead of hanging on TCP:
    # (1) database server reachable? (2) real mode also needs loaded OSM data.
    try:
        q(PGURI, 'SELECT 1')
    except Exception as e:
        sys.exit(f'[tuner] cannot reach the database at {PGURI}\n'
                 f'        start it with `make up` (make tuner does this for you '
                 f'when run via make)\n        ({e})')
    if TUNER_DATA != 'sample':
        try:
            q(PGURI, 'SELECT 1 FROM osm_polygons LIMIT 1')
        except Exception:
            sys.exit('[tuner] no OSM data loaded in the live database — run '
                     '`make all` once first,\n        or use `make tuner-sample` '
                     '(built-in synthetic fixtures, no download needed)')
    if not sandbox_ready():
        seed_sandbox()
        # first full derive + export so the viewer has sandbox data on arrival
        ENGINE._run('prepare', SANDBOX_URI, sandbox_dir())
    # cache knob metadata for request validation
    ENGINE.meta = {r[0]: {'stage': r[1], 'min': float(r[2]), 'max': float(r[3]),
                          'step': float(r[4]), 'descr': r[5]}
                   for r in q(SANDBOX_URI, 'SELECT key, stage, min, max, step, descr FROM config_meta')}
    addr = ('127.0.0.1', int(os.environ.get('TUNER_PORT') or 8000))
    try:
        server = ThreadingHTTPServer(addr, Handler)
    except OSError as e:
        sys.exit(f'[tuner] cannot bind http://{addr[0]}:{addr[1]}/ ({e.strerror})\n'
                 f'        something else is using the port (another viewer/tuner, '
                 f'or a Windows app\n        sharing localhost under WSL) — retry '
                 f'with: make tuner TUNER_PORT=8081')
    print(f'[tuner] sandbox viewer + tuning panel: http://{addr[0]}:{addr[1]}/  (Ctrl-C to stop)', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
