#!/usr/bin/env python3
"""Keep the original ABI process result and collect failure evidence on Darwin."""
import argparse
import json
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time


def collect_reports(directory, destination, started, wait_seconds=20):
    """CrashReporter is asynchronous. Only copy this process's new reports."""
    destination.mkdir(parents=True, exist_ok=True)
    deadline = time.monotonic() + wait_seconds
    copied = []
    while True:
        for path in directory.glob("native-contract*"):
            if (path.is_file() and path.suffix in (".ips", ".crash")
                    and path.stat().st_mtime >= started - 2):
                shutil.copy2(path, destination / path.name)
                copied.append(path.name)
        if copied or time.monotonic() >= deadline:
            return copied
        time.sleep(1)


def debugger_trace(executable, evidence):
    debugger = shutil.which("lldb")
    if not debugger:
        return "lldb not available"
    # A diagnostic second invocation; it never changes the first invocation's result.
    with (evidence / "lldb-backtrace.log").open("wb") as log:
        try:
            result = subprocess.run([debugger, "--batch", "-o", "run", "-o",
                                     "thread backtrace all", "--", str(executable)],
                                    stdout=log, stderr=subprocess.STDOUT, timeout=45,
                                    check=False)
            return {"exitCode": result.returncode, "diagnosticRerun": True}
        except subprocess.TimeoutExpired:
            return {"timeoutSeconds": 45, "diagnosticRerun": True}


def run_contract(executable, evidence, report_directory=None, report_wait=20):
    evidence.mkdir(parents=True, exist_ok=True)
    started = time.time()
    result = {"status": "FAIL", "exitCode": 1, "reports": []}
    try:
        with (evidence / "contract.json").open("wb") as output, (evidence / "contract-stderr.log").open("wb") as errors:
            process = subprocess.Popen([str(executable)], stdout=output, stderr=subprocess.PIPE)
            # Binary I/O avoids locale/Python-version decoding assumptions.
            with process.stderr:
                for line in process.stderr:
                    errors.write(line); errors.flush()
                    sys.stderr.buffer.write(line); sys.stderr.buffer.flush()
            raw_code = process.wait()
        code = 128 - raw_code if raw_code < 0 else raw_code
        result.update(rawExitCode=raw_code, exitCode=code)
        if raw_code < 0:
            result["signal"] = signal.Signals(-raw_code).name
        if code == 0:
            contract = json.loads((evidence / "contract.json").read_bytes())
            if contract.get("nativeABI") != "PASS":
                raise ValueError("ABI process did not export a PASS contract")
            result["status"] = "PASS"
    except Exception as error:
        result.update(error=str(error), exitCode=result["exitCode"] or 1)
    if result["status"] != "PASS":
        # Preserve an executable for symbolication even when the shell removes work/.
        try:
            shutil.copy2(executable, evidence / "native-contract")
            if report_directory is not None:
                result["reports"] = collect_reports(report_directory, evidence / "DiagnosticReports", started, report_wait)
                result["debugger"] = debugger_trace(executable, evidence)
        except Exception as error:
            result["collectionError"] = str(error)
    (evidence / "contract-result.json").write_text(json.dumps(result, indent=2) + "\n")
    return result["exitCode"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("executable", type=Path)
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args()
    reports = Path.home() / "Library/Logs/DiagnosticReports" if sys.platform == "darwin" else None
    return run_contract(args.executable.resolve(), args.evidence.resolve(), reports)


if __name__ == "__main__":
    sys.exit(main())
