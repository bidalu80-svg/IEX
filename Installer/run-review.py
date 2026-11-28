#!/usr/bin/env python3
"""Compile the production Swift package, run offline tests and retain honest evidence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "Installer"


def write(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def run(command, log, env=None):
    with log.open("w") as stream:
        result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, env=env)
    print(f"{log.name}: exit {result.returncode}", flush=True)
    return result.returncode


def fixtures(evidence):
    # An independent ZIP writer with raw DEFLATE, a binary plist, and a synthetic Mach-O.
    directory = evidence / "package" / "fixtures"
    directory.mkdir()
    info = {"CFBundleIdentifier": "org.ze.test", "CFBundleExecutable": "Main", "CFBundleVersion": "42",
            "CFBundleShortVersionString": "1.2", "MinimumOSVersion": "16.0"}
    macho = struct.pack("<8I", 0xfeedfacf, 0x100000c, 0, 2, 1, 24, 0, 0)
    macho += struct.pack("<6I", 0x32, 24, 2, 0x100000, 0x100000, 0)
    path = directory / "independent-deflate.zip"
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("Payload/Test.app/Info.plist", plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
        archive.writestr("Payload/Test.app/Main", macho)
    with zipfile.ZipFile(directory / "deflate-directories.zip", "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("Payload/", b"")
        archive.writestr("Payload/Test.app/", b"")
        archive.writestr("Payload/Test.app/Info.plist", plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
        archive.writestr("Payload/Test.app/Main", macho)
    # Lie consistently in both headers: actual inflate must still obey the smaller bound.
    malformed = bytearray(path.read_bytes())
    central = malformed.index(b"PK\x01\x02")
    size = struct.unpack_from("<I", malformed, 22)[0]
    struct.pack_into("<I", malformed, 22, size - 1)
    struct.pack_into("<I", malformed, central + 24, size - 1)
    (directory / "deflate-size-lie.zip").write_bytes(malformed)
    return path


class ReviewFailure(Exception):
    def __init__(self, category, message, *, exit_code=1, context=None):
        super().__init__(message)
        self.category = category
        self.exit_code = exit_code if exit_code > 0 else 1
        self.context = context or {}


def execute_stage(command, log, env, stages, name, kind):
    record = {"name": name, "kind": kind, "log": log.name}
    stages.append(record)
    try:
        record["rawExitCode"] = run(command, log, env)
    except OSError as error:
        record["launchError"] = str(error)
        raise ReviewFailure("build" if kind == "build" else "resultExport",
                            "Could not start stage " + name, context=record) from error
    return record


def require_build(record):
    if record["rawExitCode"]:
        raise ReviewFailure("build", "Stage failed to compile: " + record["name"],
                            exit_code=record["rawExitCode"], context=record)


def read_test_results(path, log, raw_exit_code):
    # The process status/log are already recorded. A second failure while reading XML
    # must identify that original result, never replace it with an unclassified parse error.
    context = {"results": path.name, "rawExitCode": raw_exit_code, "log": log.name}
    try:
        output = log.read_text(errors="replace")
    except OSError as error:
        raise ReviewFailure("resultExport", "Cannot read original test log", context=context) from error
    if raw_exit_code < 0 or any(marker in output for marker in (
            "Fatal error:", "*** Signal", "Exited with unexpected signal", "exited with unexpected signal")):
        raise ReviewFailure("resultExport", "Test process crashed; retain original exit code and log",
                            context={**context, "processCrashed": True})
    if not path.is_file():
        raise ReviewFailure("resultExport", "Missing test XML; original process result retained", context=context)
    try:
        tree = ET.parse(path)
    except (OSError, ET.ParseError) as error:
        raise ReviewFailure("resultExport", "Unreadable test XML; original process result retained",
                            context={**context, "exportError": str(error)}) from error
    cases = []
    for item in tree.iter("testcase"):
        if not item.get("name") or not item.get("classname"):
            raise ReviewFailure("resultExport", "Test XML lacks case identity", context=context)
        assertion = item.find("failure") is not None
        error = item.find("error") is not None
        cases.append({"name": item.get("name"), "class": item.get("classname"),
                      "status": "FAIL" if assertion or error else "SKIP" if item.find("skipped") is not None else "PASS",
                      "assertionFailure": assertion})
    if not cases:
        raise ReviewFailure("resultExport", "Test XML contains no cases", context=context)
    if raw_exit_code != 0 and not any(case["status"] == "FAIL" for case in cases):
        raise ReviewFailure("resultExport", "Nonzero process exit without a recorded test failure", context=context)
    return cases


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", type=Path, default=ROOT / "ipa-install-evidence")
    parser.add_argument("--skip-mutations", action="store_true", help="local diagnostic only; CI runs mutations")
    args = parser.parse_args()
    evidence = args.evidence.resolve()
    # Do not delete an old evidence directory or any caller-supplied path.
    evidence.mkdir(parents=True, exist_ok=False)
    for name in ("package", "signing", "protocol", "transaction", "ui"):
        (evidence / name).mkdir()
    auto = {"status": "FAIL", "failureCategory": "build", "stages": [], "mutations": []}
    summary = {"自动化实现验证": auto,
               "真机兼容记录": {"status": "NOT TESTED", "reason": "No physical device or Apple signing identity"}}
    write(evidence / "summary.json", summary)
    exit_code = 1
    try:
        for name, reason in (("signing", "Real signing/profile backend deferred until device validation"),
                             ("protocol", "Only MockTransport; no invented device protocol vectors"),
                             ("ui", "No UI, pbxproj integration, simulator screenshots or xcresult in offline core scope")):
            write(evidence / name / "result.json", {"status": "NOT TESTED", "reason": reason})
        swift = shutil.which("swift")
        environment = {"platform": platform.platform(), "python": sys.version, "swift": swift,
                       "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                       "dateUTC": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                       "dependencies": "System zlib; no fetched Swift dependencies"}
        for tool, command in (("swiftVersion", [swift or "swift", "--version"]), ("xcode", ["xcodebuild", "-version"]),
                              ("clang", ["clang", "--version"])):
            try:
                environment[tool] = subprocess.check_output(command, stderr=subprocess.STDOUT, text=True).strip()
            except (OSError, subprocess.CalledProcessError) as error:
                environment[tool] = f"unavailable: {type(error).__name__}"
        write(evidence / "environment.json", environment)
        sources = [PACKAGE / "Package.swift", PACKAGE / "run-review.py", PACKAGE / "test-review.py"]
        sources += sorted((PACKAGE / "Sources").rglob("*")) + sorted((PACKAGE / "Tests").rglob("*"))
        write(evidence / "source-manifest.json", {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                                for p in sources if p.is_file()})
        fixture = fixtures(evidence)
        env = dict(os.environ, IPA_DEFLATE_FIXTURE=str(fixture), IPA_EVIDENCE=str(evidence), PYTHONDONTWRITEBYTECODE="1")
        runner_tests = execute_stage([sys.executable, str(PACKAGE / "test-review.py")], evidence / "runner-tests.log",
                                     env, auto["stages"], "review-runner-tests", "test")
        auto["runnerTestExitCode"] = runner_tests["rawExitCode"]
        if runner_tests["rawExitCode"]:
            raise ReviewFailure("businessAssertion", "Review runner regression tests failed", context=runner_tests)
        if not swift:
            raise ReviewFailure("build", "Swift compiler unavailable")
        with tempfile.TemporaryDirectory(prefix="ze-ipa-review-") as scratch:
            build = str(Path(scratch) / "build")
            base = [swift, "test", "--parallel", "--num-workers", "2", "--disable-swift-testing",
                    "--package-path", str(PACKAGE), "--scratch-path", build]
            compiled = execute_stage([swift, "build", "--build-tests", "--package-path", str(PACKAGE), "--scratch-path", build],
                                     evidence / "compile.log", env, auto["stages"], "core-build", "build")
            auto["buildExitCode"] = compiled["rawExitCode"]
            require_build(compiled)
            tested = execute_stage(base + ["--skip-build", "--xunit-output", str(evidence / "tests.xml")],
                                   evidence / "tests.log", env, auto["stages"], "core-tests", "test")
            auto["testExitCode"] = tested["rawExitCode"]
            cases = read_test_results(evidence / "tests.xml", evidence / "tests.log", tested["rawExitCode"])
            tested["caseCount"] = len(cases)
            write(evidence / "package" / "cases.json", [c for c in cases if "Inspector" in c["class"]])
            write(evidence / "transaction" / "cases.json", [c for c in cases if "Coordinator" in c["class"]])
            auto["cases"] = cases
            if tested["rawExitCode"] or any(case["status"] != "PASS" for case in cases):
                raise ReviewFailure("businessAssertion", "Core tests failed or skipped", exit_code=tested["rawExitCode"], context=tested)
            if not args.skip_mutations:
                for name, filename, before, after, test in [
                    ("path-traversal", "IPAPackageInspector.swift", '$0 != ".."', 'true', "IPAPackageInspectorTests.testTraversalAndAbsolutePaths"),
                    ("upload-is-success", "DeviceInstallCoordinator.swift", "case (.upload, .uploaded): move(.uploaded)",
                     "case (.upload, .uploaded): move(.launched)", "DeviceInstallCoordinatorTests.testCompleteFlow")]:
                    mutation = {"name": name, "status": "FAIL"}
                    auto["mutations"].append(mutation)
                    mutant = Path(scratch) / name
                    shutil.copytree(PACKAGE, mutant, ignore=shutil.ignore_patterns(".build", ".swiftpm", "__pycache__", "target"))
                    source = mutant / "Sources" / "InstallerCore" / filename
                    original = source.read_text()
                    if original.count(before) != 1:
                        raise ReviewFailure("build", "Mutation anchor must match exactly once: " + name)
                    source.write_text(original.replace(before, after))
                    mutant_build = str(Path(scratch) / (name + "-build"))
                    compiled = execute_stage([swift, "build", "--build-tests", "--package-path", str(mutant), "--scratch-path", mutant_build],
                                             evidence / (name + "-compile.log"), env, auto["stages"], name + "-build", "build")
                    mutation["buildExitCode"] = compiled["rawExitCode"]
                    require_build(compiled)
                    mutant_env = dict(env)
                    mutant_env.pop("IPA_EVIDENCE", None)
                    tested = execute_stage([swift, "test", "--parallel", "--num-workers", "1", "--disable-swift-testing", "--skip-build",
                                            "--package-path", str(mutant), "--scratch-path", mutant_build,
                                            "--filter", test, "--xunit-output", str(evidence / (name + ".xml"))],
                                           evidence / (name + ".log"), mutant_env, auto["stages"], name + "-tests", "test")
                    mutation["rawExitCode"] = tested["rawExitCode"]
                    cases = read_test_results(evidence / (name + ".xml"), evidence / (name + ".log"), tested["rawExitCode"])
                    killed = tested["rawExitCode"] != 0 and any(case["assertionFailure"] for case in cases)
                    mutation.update(status="PASS" if killed else "FAIL", controlledAssertionFailure=killed,
                                    meaning="PASS means business assertions detected the mutation without a process crash")
                    if not killed:
                        raise ReviewFailure("businessAssertion", "Mutation escaped controlled assertions: " + name, context=tested)
            auto.update(status="PASS", failureCategory=None, scope="Offline package and mock transaction only",
                        mutationsSkipped=args.skip_mutations)
            exit_code = 0
    except ReviewFailure as error:
        auto.update(status="FAIL", failureCategory=error.category, error=str(error), failureContext=error.context)
        exit_code = error.exit_code
    except Exception as error:
        auto.update(status="FAIL", failureCategory="resultExport", error=f"Evidence processing failed: {error}")
        exit_code = 1
    finally:
        try:
            write(evidence / "package" / "fixture-manifest.json", {
                str(p.relative_to(evidence)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted((evidence / "package" / "fixtures").glob("*")) if p.is_file()})
        except OSError as error:
            auto.setdefault("secondaryErrors", []).append("Fixture manifest export failed: " + str(error))
            if exit_code == 0:
                auto.update(status="FAIL", failureCategory="resultExport")
                exit_code = 1
        try:
            write(evidence / "summary.json", summary)
        except OSError as error:
            print("Summary export failed; original stage logs remain: " + str(error), file=sys.stderr)
            if exit_code == 0:
                auto.update(status="FAIL", failureCategory="resultExport")
            exit_code = exit_code or 1
        print(json.dumps({"status": auto["status"], "failureCategory": auto["failureCategory"],
                          "testCount": len(auto.get("cases", [])), "mutations": auto["mutations"],
                          "error": auto.get("error")}, ensure_ascii=False), flush=True)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
