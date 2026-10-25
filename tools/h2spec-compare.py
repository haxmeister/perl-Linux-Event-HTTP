#!/usr/bin/env python3
"""Compare exact h2spec JUnit case outcomes across protocol/adapter fixtures.

Protocol failures are reported but do not cause a nonzero exit here.
Missing/partial data and inconsistent case inventories DO cause a failure.
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
    root = ET.parse(path).getroot()
    cases = {}
    for suite in root.findall(".//testsuite"):
        section = suite.get("package", suite.get("name", ""))
        for test in suite.findall("testcase"):
            title = test.get("classname") or test.get("name") or "(unnamed)"
            key = f"{section} :: {title}"
            if key in cases:
                raise SystemExit(f"{name}: duplicate test case: {key}")
            result = (
                "failed" if test.find("failure") is not None or test.find("error") is not None
                else "skipped" if test.find("skipped") is not None
                else "passed"
            )
            cases[key] = result
    if len(cases) != 146:
        raise SystemExit(f"{name}: expected 146 cases, got {len(cases)}")
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
