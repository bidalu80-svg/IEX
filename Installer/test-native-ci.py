#!/usr/bin/env python3
"""Portable regressions for native CI evidence and strict symbol validation."""
import importlib.util
import json
from pathlib import Path
import signal
import tempfile
import time
import unittest
from unittest.mock import patch


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runner = load("contract_runner", "run-native-contract.py")
symbols = load("native_symbols", "check-native-symbols.py")


class NativeCITests(unittest.TestCase):
    def test_sigbus_keeps_original_exit_progress_and_binary(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            executable = root / "native-contract"
            executable.write_text("#!/usr/bin/env python3\nimport os, signal, sys\n"
                                  "sys.stderr.write('ABI step: before runtime\\n'); sys.stderr.flush()\n"
                                  "os.kill(os.getpid(), signal.SIGBUS)\n")
            executable.chmod(0o755)
            evidence = root / "evidence"
            self.assertEqual(runner.run_contract(executable, evidence), 128 + signal.SIGBUS)
            result = json.loads((evidence / "contract-result.json").read_text())
            self.assertEqual(result["signal"], "SIGBUS")
            self.assertEqual(result["status"], "FAIL")
            self.assertEqual((evidence / "contract.json").read_bytes(), b"")
            self.assertIn("before runtime", (evidence / "contract-stderr.log").read_text())
            self.assertEqual((evidence / "native-contract").read_bytes(), executable.read_bytes())

    def test_collects_only_new_matching_darwin_reports(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); reports = root / "reports"; reports.mkdir()
            for name in ["native-contract-new.ips", "native-contract-old.crash", "other.ips"]:
                (reports / name).write_text("synthetic report")
            import os
            os.utime(reports / "native-contract-old.crash", (1, 1))
            copied = runner.collect_reports(reports, root / "out", time.time(), wait_seconds=0)
            self.assertEqual(copied, ["native-contract-new.ips"])

    def test_valid_contract_required_even_on_zero_exit(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); executable = root / "native-contract"
            executable.write_text("#!/bin/sh\nprintf '{}'\n"); executable.chmod(0o755)
            self.assertEqual(runner.run_contract(executable, root / "out"), 1)

    def test_all_five_external_definitions_required(self):
        valid = "\n".join("00000000 T _" + name for name in symbols.SYMBOLS)
        self.assertEqual(symbols.required_symbols(valid, True), [])
        for name in symbols.SYMBOLS:
            with self.subTest(name=name):
                text = (valid + "\n").replace(" T _" + name + "\n", " U _" + name + "\n")
                self.assertEqual(symbols.required_symbols(text, True), ["_" + name])
        self.assertTrue(symbols.required_symbols(valid.lower(), True))
        self.assertTrue(symbols.required_symbols(valid.replace("_ze_connection_run", "_ze_connection_runner"), True))

    def test_reader_error_is_never_ignored(self):
        import subprocess
        with tempfile.TemporaryDirectory() as temp, patch.object(symbols, "llvm_nm", return_value=(Path("/fake/llvm-nm"), "rustc test")):
            with patch.object(symbols.subprocess, "check_output", return_value="LLVM test"), patch.object(symbols.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "llvm-nm")):
                with self.assertRaises(subprocess.CalledProcessError):
                    symbols.check(Path(temp) / "target/release/lib.a", Path(temp) / "evidence")


if __name__ == "__main__":
    unittest.main()
