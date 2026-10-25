#!/usr/bin/env python3
"""Compare exact h2spec JUnit case outcomes across protocol/adapter fixtures.

All four strict conformance runs must pass: 147 cases, no failures or skips.
Missing/partial data and inconsistent case inventories also cause a failure.
"""
import json
import pathlib
import sys
import xml.etree.ElementTree as ET

if len(sys.argv) != 3:
    raise SystemExit("usage: h2spec-compare.py REPORT_DIRECTORY OUTPUT_JSON")

folder = pathlib.Path(sys.argv[1])
names = ["standalone", "rebuild-native", "rebuild-perl", "standalone-repeat"]
summary = {}

for name in names:
    path = folder / f"{name}.xml"
    if not path.is_file() or not path.stat().st_size:
        raise SystemExit(f"missing or empty h2spec JUnit report: {path}")

    # h2spec 2.6.0 emits malformed XML when an HTTP/2 frame diagnostic
    # contains raw protocol control bytes or XML metacharacters inside
    # its <failure> innerxml. Parse only Go's structurally produced
    # testsuite/testcase tags and attributes; do not parse diagnostic
    # text as XML or alter the preserved original report.
    import html
    import re

    source = path.read_text(encoding="utf-8", errors="replace")
    suite_tag = re.compile(r"<testsuite\b(?P<attrs>[^>]*)>(?P<body>.*?)</testsuite>", re.S)
    case_tag = re.compile(
        r"<testcase\b(?P<attrs>[^>]*?)(?:\s*/>|>(?P<body>.*?)</testcase>)", re.S
    )
    attrs_re = re.compile(r'([a-zA-Z_][a-zA-Z_0-9]*)="([^"]*)"')

    def attributes(text):
        return {key: html.unescape(value) for key, value in attrs_re.findall(text)}

    cases = {}
    suites = list(suite_tag.finditer(source))
    if not suites:
        raise SystemExit(f"{name}: no h2spec test suites in JUnit output")

    for suite in suites:
        section = attributes(suite.group("attrs")).get("package", "")
        for match in case_tag.finditer(suite.group("body")):
            attrs = attributes(match.group("attrs"))
            title = attrs.get("classname") or attrs.get("name") or "(unnamed)"
            key = f"{section} :: {title}"
            if key in cases:
                raise SystemExit(f"{name}: duplicate h2spec test case: {key}")
            body = match.group("body") or ""
            result = (
                "failed" if "<failure" in body or "<error" in body
                else "skipped" if "<skipped" in body
                else "passed"
            )
            cases[key] = result
    if len(cases) != 147:
        raise SystemExit(f"{name}: expected 147 cases, got {len(cases)}")
    summary[name] = {
        "passed": sum(v == "passed" for v in cases.values()),
        "skipped": sum(v == "skipped" for v in cases.values()),
        "failed": sum(v == "failed" for v in cases.values()),
        "failures": sorted(k for k, v in cases.items() if v == "failed"),
        "cases": cases,
    }

reference = summary["standalone"]["cases"]
for name in names[1:]:
    if reference.keys() != summary[name]["cases"].keys():
        raise SystemExit(f"{name}: h2spec case inventory differs from standalone")

print("STAGE C identical-runner HTTP2 conformance comparison", flush=True)
for name in names:
    item = summary[name]
    print(f"{name}: {item['passed']} passed, {item['skipped']} skipped, "
          f"{item['failed']} failed / {len(item['cases'])} total", flush=True)

for name in names[1:]:
    different = [
        (key, reference[key], summary[name]["cases"][key])
        for key in reference if reference[key] != summary[name]["cases"][key]
    ]
    print(f"Compared with standalone: {name}: {len(different)} differing cases", flush=True)
    for key, before, after in sorted(different):
        print(f"  {key}: standalone={before} {name}={after}", flush=True)

for name in names:
    print(f"Failing cases for {name}:", flush=True)
    for case in summary[name]["failures"]:
        print(f"  {case}", flush=True)

output = {
    "tool": "h2spec v2.6.0",
    "engines": {
        name: {k: v for k, v in summary[name].items() if k != "cases"}
        for name in names
    },
    "differences_against_standalone": {
        name: sorted(
            key for key in reference
            if reference[key] != summary[name]["cases"][key]
        )
        for name in names[1:]
    },
}
path = pathlib.Path(sys.argv[2])
path.write_text(json.dumps(output, sort_keys=True, indent=2) + "\n")
print(f"JSON comparison: {path}", flush=True)
for name in names:
    item = summary[name]
    if item["failed"] or item["skipped"] or item["passed"] != 147:
        raise SystemExit(f"{name}: strict h2spec conformance failed "
                         f"({item['passed']} passed, {item['skipped']} skipped, "
                         f"{item['failed']} failed)")
