"""Turns luacov.report.out into an istanbul json-summary (lines only) for the plugin files.

Usage (repo root, after `busted -c && luacov`): python3 spec/luacov_summary.py docs/test-report/coverage.json
"""
import json
import re
import sys

rows = {}
for line in open("luacov.report.out"):
    m = re.match(r"^(kindlemtp\.koplugin/\S+)\s+(\d+)\s+(\d+)\s+", line)
    if m:
        rows[m.group(1)] = (int(m.group(2)), int(m.group(3)))


def summary(hits, missed):
    return {"statements": {"covered": hits, "total": hits + missed}, "branches": {"covered": 0, "total": 0}}


out = {name: summary(*v) for name, v in rows.items()}
out["total"] = summary(sum(v[0] for v in rows.values()), sum(v[1] for v in rows.values()))
json.dump(out, open(sys.argv[1], "w"), indent=1)
