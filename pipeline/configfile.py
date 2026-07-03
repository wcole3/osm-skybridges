"""Shared helpers for the config block in sql/01_prepare.sql.

The ('key', value) rows there are the single durable source of the processing
settings: `make tune`, the live tuner's "save as defaults", and
`make config-load` all rewrite them with the SAME regex, so every path produces
identical bytes (and a clean `git diff`). Used by pipeline/tuner.py and
pipeline/config_load.py.
"""
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PREPARE_SQL = os.path.join(ROOT, 'sql', '01_prepare.sql')

CONFIG_ROW_RE = re.compile(r"\('([a-z_]+)',\s*([0-9.]+)\)")


def fmt_num(v):
    s = f'{float(v):g}'
    return s if ('.' in s or 'e' in s) else s + '.0'


def file_defaults():
    """key -> default value, parsed from the 01_prepare config block."""
    with open(PREPARE_SQL) as fh:
        return {k: float(v) for k, v in CONFIG_ROW_RE.findall(fh.read())}


def rewrite_default(key, value):
    """Persist one knob default into sql/01_prepare.sql — same bytes `make tune`
    would write (the Makefile's sed, ported)."""
    with open(PREPARE_SQL) as fh:
        text = fh.read()
    pat = re.compile(r"(\('%s', *)[0-9.]+( *\))" % re.escape(key))
    if not pat.search(text):
        raise RuntimeError(f'unknown config key {key!r} in 01_prepare.sql')
    with open(PREPARE_SQL, 'w') as fh:
        fh.write(pat.sub(lambda m: m.group(1) + fmt_num(value) + m.group(2), text))
