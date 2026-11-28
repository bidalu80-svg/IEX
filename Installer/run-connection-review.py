#!/usr/bin/env python3
"""Connection fixtures: compile production code, kill four semantic mutations.
No output from this runner is evidence of real-device pairing or VPN routing.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

# Reuse the reviewed result classifier, including missing/crashed XML handling.
import importlib.util
spec = importlib.util.spec_from_file_location("ipa_review", Path(__file__).with_name("run-review.py"))
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)
PACKAGE = Path(__file__).resolve().parent
MUTATIONS = [
    ("bonjour-is-success", "self.pass(.publication)", "self.pass(.publication); self.state = .queryPassed", "testPublicationIsNotQuerySuccess"),
    ("tcp-is-verified", "guard self.tunnelIndex == 4 else", "guard self.tunnelIndex >= 1 else", "testTCPIsNotPairVerify"),
    ("query-local-fallback", "self.stop(error as? ProbeFailure ?? .disconnected)",
     "if self.currentStep == .query { self.pass(.query); self.cleanup(); self.state = .queryPassed } else { self.stop(error as? ProbeFailure ?? .disconnected) }", "testQueryFailureHasNoLocalFallback"),
    ("cancel-late-success", "guard generation == token, !Task.isCancelled else", "guard true else", "testCancelRejectsLateSuccess"),
]

def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")

def run(command, log):
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("w") as output:
        return subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, check=False).returncode

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", type=Path, default=Path("stage1-connection-evidence"))
    args = parser.parse_args(); evidence = args.evidence.resolve()
    if evidence.exists():
        parser.error("Use a fresh evidence directory")
    evidence.mkdir(parents=True)
    summary = {"fixtureStatus": "FAIL", "scope": "Swift connection core + fixtures and mutations; native/ABI/iOS results are separate; no live device", "mutations": [], "device": {
        "host": "NOT TESTED", "firstConnection": "NOT TESTED", "appReopen": "NOT TESTED", "deviceRestart": "NOT TESTED"}}
    write(evidence / "manual" / "screenshots-index.json", {"items": [], "status": "NOT TESTED"})
    write(evidence / "events" / "redacted-events.json", {"events": [], "origin": "No live experiment; fixtures are separate"})
    write(evidence / "environment.json", {"platform": platform.platform(), "python": sys.version,
        "sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=PACKAGE, text=True).strip(),
        "workingTree": subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=no"], cwd=PACKAGE, text=True),
        "swift": subprocess.check_output(["swift", "--version"], text=True).strip()})
    files = list((PACKAGE / "Sources").rglob("*")) + list((PACKAGE / "Tests").rglob("*"))
    files += [p for p in (PACKAGE / "Native").rglob("*") if "target" not in p.relative_to(PACKAGE / "Native").parts]
    files += list((PACKAGE.parent / "InstallerHost").glob("*.swift")) + [PACKAGE / "Package.swift", Path(__file__)]
    write(evidence / "source-sha256.json", {str(p.relative_to(PACKAGE.parent)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(files) if p.is_file()})
    try:
        with tempfile.TemporaryDirectory(prefix="ze-connection-") as temp:
            build = str(Path(temp) / "build")
            base = ["swift", "test", "--parallel", "--num-workers", "2", "--package-path", str(PACKAGE), "--scratch-path", build,
                    "--disable-swift-testing", "--filter", "ConnectionProbeTests"]
            xml = evidence / "fixtures" / "tests.xml"
            code = run(base + ["--xunit-output", str(xml)], evidence / "fixtures" / "tests.log")
            cases = review.read_test_results(xml, evidence / "fixtures" / "tests.log", code)
            write(evidence / "fixtures" / "cases.json", cases)
            summary.update(testCount=len(cases), testExitCode=code)
            if code != 0 or any(c["status"] != "PASS" for c in cases):
                raise RuntimeError("Connection production fixture assertions failed")
            for name, old, new, test in MUTATIONS:
                mutant = Path(temp) / name
                shutil.copytree(PACKAGE, mutant, ignore=shutil.ignore_patterns(".build", ".swiftpm", "__pycache__", "target", "upstream"))
                source = mutant / "Sources" / "ConnectionExperimentCore" / "ConnectionProbeCoordinator.swift"
                text = source.read_text()
                if text.count(old) != 1: raise RuntimeError("Mutation anchor changed: " + name)
                source.write_text(text.replace(old, new))
                build_code = run(["swift", "build", "--build-tests", "--package-path", str(mutant)], evidence / "mutations" / (name + "-build.log"))
                item = {"name": name, "buildExitCode": build_code}; summary["mutations"].append(item)
                if build_code: raise RuntimeError("Mutation did not compile: " + name)
                xml = evidence / "mutations" / (name + ".xml"); log = evidence / "mutations" / (name + ".log")
                code = run(["swift", "test", "--parallel", "--num-workers", "1", "--skip-build", "--disable-swift-testing", "--package-path", str(mutant),
                            "--filter", "ConnectionProbeTests." + test, "--xunit-output", str(xml)], log)
                cases = review.read_test_results(xml, log, code)
                killed = code == 1 and len(cases) == 1 and cases[0]["status"] == "FAIL" and cases[0]["assertionFailure"]
                item.update(testExitCode=code, controlledAssertionFailure=killed, status="PASS" if killed else "FAIL")
                if not killed: raise RuntimeError("Mutation escaped controlled assertion: " + name)
            summary["fixtureStatus"] = "PASS"
    except Exception as error:
        summary["failure"] = str(error)
        return 1
    finally:
        write(evidence / "summary.json", summary)
        print(json.dumps(summary, ensure_ascii=False))
    return 0

if __name__ == "__main__":
    sys.exit(main())
