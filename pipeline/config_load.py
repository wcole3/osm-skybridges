#!/usr/bin/env python3
"""Ingest a shared settings file into this checkout (`make config-load`).

Reads a config JSON (as written by `make config-export` / `make export` —
web/data/config.json, exports/config.json — or a bare {"key": value} object),
validates every key against the config block in sql/01_prepare.sql, and
persists the values there with the same rewrite `make tune` uses. The caller
(`make config-load`) then re-derives + re-exports, so the received settings
fully take effect and survive rebuilds (and show up in `git diff`).

Usage: python3 pipeline/config_load.py <file.json>
Exit codes: 0 applied; 2 bad input (unknown key / unreadable / not numeric).
"""
import json
import sys

from configfile import file_defaults, fmt_num, rewrite_default


def main():
    if len(sys.argv) != 2:
        sys.exit('usage: python3 pipeline/config_load.py <config.json>   '
                 '(or: make config-load FILE=<config.json>)')
    path = sys.argv[1]
    try:
        with open(path) as fh:
            doc = json.load(fh)
    except (OSError, json.JSONDecodeError) as e:
        sys.exit(f'[config-load] cannot read {path}: {e}')

    values = doc.get('values', doc) if isinstance(doc, dict) else None
    if not isinstance(values, dict) or not values:
        sys.exit(f'[config-load] {path}: expected a JSON object with a "values" '
                 'map (or a bare {"key": number} object)')

    defaults = file_defaults()
    unknown = sorted(set(values) - set(defaults))
    if unknown:
        sys.exit(f'[config-load] unknown key(s) {", ".join(unknown)} — not in the '
                 f'config block of sql/01_prepare.sql.\n'
                 f'valid keys: {", ".join(sorted(defaults))}')
    try:
        numeric = {k: float(v) for k, v in values.items()}
    except (TypeError, ValueError) as e:
        sys.exit(f'[config-load] non-numeric value in {path}: {e}')

    changed = []
    for key, val in sorted(numeric.items()):
        if abs(defaults[key] - val) > 1e-12:
            rewrite_default(key, val)
            changed.append(f'  {key}: {fmt_num(defaults[key])} -> {fmt_num(val)}')
    if changed:
        print(f'[config-load] applied {len(changed)} change(s) to sql/01_prepare.sql:')
        print('\n'.join(changed))
    else:
        print('[config-load] all values already match the current defaults — nothing to do')


if __name__ == '__main__':
    main()
