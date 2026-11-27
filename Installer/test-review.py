#!/usr/bin/env python3
"""Failure injection for the production evidence runner; no Swift build or device access."""
from contextlib import contextmanager
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("review_runner", Path(__file__).with_name("run-review.py"))
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)

PASS = '<testsuite><testcase classname="InstallerCoreTests.IPAPackageInspectorTests" name="fixture"/></testsuite>'
FAIL = '<testsuite><testcase classname="InstallerCoreTests.DeviceInstallCoordinatorTests" name="fixture"><failure message="expected uploaded"/></testcase></testsuite>'


class ReviewRunnerTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="ze-review-runner-test-")
        self.root = Path(self.scratch.name)
        self.log = self.root / "raw.log"
        self.log.write_text("original test output\n")
        self.xml = self.root / "tests.xml"

    def tearDown(self):
        self.scratch.cleanup()

    def expect_export_failure(self, code):
        with self.assertRaises(review.ReviewFailure) as caught:
            review.read_test_results(self.xml, self.log, code)
        self.assertEqual(caught.exception.category, "resultExport")
        self.assertEqual(caught.exception.context["rawExitCode"], code)
        self.assertEqual(caught.exception.context["log"], self.log.name)
        self.assertTrue(self.log.exists())
        return caught.exception

    def test_missing_xml_preserves_first_exit_and_log(self):
        error = self.expect_export_failure(17)
        self.assertIn("Missing test XML", str(error))
        self.assertEqual(self.log.read_text(), "original test output\n")

    def test_malformed_xml_is_export_failure(self):
        self.xml.write_text("<truncated")
        self.assertIn("Unreadable test XML", str(self.expect_export_failure(7)))

    def test_empty_results_are_export_failure(self):
        self.xml.write_text("<testsuite/>")
        self.expect_export_failure(0)

    def test_incomplete_case_identity_is_export_failure(self):
        self.xml.write_text('<testsuite><testcase name="fixture"/></testsuite>')
        self.expect_export_failure(0)

    def test_nonzero_exit_with_passing_xml_is_export_failure(self):
        self.xml.write_text(PASS)
        self.expect_export_failure(9)

    def test_crash_with_xml_is_never_controlled_mutation(self):
        self.xml.write_text(FAIL)
        self.log.write_text("Assertion failed\nFatal error: Index out of range\n")
        error = self.expect_export_failure(1)
        self.assertTrue(error.context["processCrashed"])

    def test_signal_without_xml_retains_original_process_status(self):
        error = self.expect_export_failure(-11)
        self.assertTrue(error.context["processCrashed"])

    def test_controlled_assertion_failure_is_readable(self):
        self.xml.write_text(FAIL)
        cases = review.read_test_results(self.xml, self.log, 1)
        self.assertEqual(cases[0]["status"], "FAIL")
        self.assertTrue(cases[0]["assertionFailure"])

    def test_successful_case_is_readable(self):
        self.xml.write_text(PASS)
        cases = review.read_test_results(self.xml, self.log, 0)
        self.assertEqual(cases[0]["status"], "PASS")
        self.assertFalse(cases[0]["assertionFailure"])

    def test_mutation_build_error_records_build_category_and_exit(self):
        stages = []
        with patch.object(review, "run", return_value=23):
            record = review.execute_stage(["fixture"], self.log, {}, stages, "mutant-build", "build")
        with self.assertRaises(review.ReviewFailure) as caught:
            review.require_build(record)
        self.assertEqual(caught.exception.category, "build")
        self.assertEqual(caught.exception.exit_code, 23)
        self.assertEqual(stages[0]["rawExitCode"], 23)

    def test_build_launch_error_is_build_category(self):
        stages = []
        with patch.object(review, "run", side_effect=FileNotFoundError("missing compiler")):
            with self.assertRaises(review.ReviewFailure) as caught:
                review.execute_stage(["fixture"], self.log, {}, stages, "mutant-build", "build")
        self.assertEqual(caught.exception.category, "build")
        self.assertIn("launchError", stages[0])

    def run_injected_review(self, mode):
        evidence = self.root / "evidence"

        def fake_run(command, log, env=None):
            log.write_text("original fixture stage output\n")
            if log.name == "tests.log":
                if mode == "missing-core-xml":
                    return 19
                (evidence / "tests.xml").write_text(FAIL if mode == "business" else PASS)
                return 1 if mode == "business" else 0
            if log.name == "path-traversal-compile.log" and mode == "mutation-build":
                return 21
            if log.name == "path-traversal.log":
                if mode == "missing-mutation-xml":
                    return 17
                (evidence / "path-traversal.xml").write_text("<invalid" if mode == "malformed-mutation-xml" else FAIL)
                return 1
            if log.name == "upload-is-success.log":
                (evidence / "upload-is-success.xml").write_text(FAIL)
                return 1
            return 0

        def fake_check_output(command, *args, **kwargs):
            # subprocess is shared with platform.py. Darwin's platform.platform()
            # probes `file -b` in binary mode and decodes the returned bytes, whereas
            # this runner's git/toolchain probes explicitly request text=True.
            output = "Mach-O 64-bit arm64" if command[:2] == ["file", "-b"] else "fixture"
            text_mode = (kwargs.get("text") or kwargs.get("universal_newlines")
                         or kwargs.get("encoding") or kwargs.get("errors"))
            return output if text_mode else output.encode("utf-8")

        real_temporary_directory = review.tempfile.TemporaryDirectory

        @contextmanager
        def scratch_directory(*args, **kwargs):
            with real_temporary_directory(*args, **kwargs) as scratch:
                yield scratch
            if mode == "cleanup-error":
                raise OSError("scratch cleanup failed")

        with patch.object(review.sys, "argv", ["run-review.py", "--evidence", str(evidence)]), \
                patch.object(review.shutil, "which", return_value="/fixture/swift"), \
                patch.object(review.subprocess, "check_output", side_effect=fake_check_output), \
                patch.object(review, "run", side_effect=fake_run), \
                patch.object(review.tempfile, "TemporaryDirectory", scratch_directory), patch("builtins.print"):
            code = review.main()
        return code, json.loads((evidence / "summary.json").read_text())["自动化实现验证"], evidence

    def test_full_review_darwin_binary_platform_probe_on_any_host(self):
        # Exercise the real stdlib architecture/_syscmd_file decode path without
        # requiring macOS. A fresh cache prevents earlier tests hiding the probe.
        # Only OS identity is synthetic; check_output still uses our shared stub.
        real_probe = review.platform._syscmd_file
        with patch.object(review.platform, "_platform_cache", {}), \
                patch.object(review.platform, "uname", return_value=("Darwin", "fixture", "24.6.0", "fixture", "arm64", "arm")), \
                patch.object(review.platform, "mac_ver", return_value=("15.8.2", ("", "", ""), "arm64")), \
                patch.object(review.platform, "_syscmd_file", wraps=real_probe) as probe:
            code, auto, evidence = self.run_injected_review("success")
        self.assertEqual(code, 0, auto.get("error"))
        self.assertEqual(auto["status"], "PASS")
        self.assertTrue(all(item["controlledAssertionFailure"] for item in auto["mutations"]))
        probe.assert_called_once()
        environment = json.loads((evidence / "environment.json").read_text())
        self.assertIn("macOS-15.8.2", environment["platform"])
        # Python versions differ in whether architecture() names Mach-O linkage.
        # The regression requires the byte-decoding probe, not a cosmetic suffix.
        self.assertIn("64bit", environment["platform"])
        self.assertEqual(environment["commit"], "fixture")
        self.assertEqual(environment["swiftVersion"], "fixture")

    def test_full_review_classifies_mutation_compile_failure(self):
        code, auto, _ = self.run_injected_review("mutation-build")
        self.assertEqual(code, 21)
        self.assertEqual(auto["failureCategory"], "build")
        self.assertEqual(auto["mutations"][0]["buildExitCode"], 21)
        self.assertEqual(auto["failureContext"]["rawExitCode"], 21)

    def test_full_review_missing_mutation_xml_retains_original_failure(self):
        code, auto, evidence = self.run_injected_review("missing-mutation-xml")
        self.assertEqual(code, 1)
        self.assertEqual(auto["failureCategory"], "resultExport")
        self.assertEqual(auto["mutations"][0]["rawExitCode"], 17)
        self.assertEqual(auto["failureContext"]["rawExitCode"], 17)
        self.assertEqual((evidence / "path-traversal.log").read_text(), "original fixture stage output\n")
        self.assertIn("Missing test XML", auto["error"])

    def test_full_review_malformed_mutation_xml_is_export_failure(self):
        _, auto, _ = self.run_injected_review("malformed-mutation-xml")
        self.assertEqual(auto["failureCategory"], "resultExport")
        self.assertEqual(auto["failureContext"]["rawExitCode"], 1)
        self.assertIn("Unreadable test XML", auto["error"])

    def test_full_review_missing_core_xml_is_export_failure(self):
        _, auto, _ = self.run_injected_review("missing-core-xml")
        self.assertEqual(auto["failureCategory"], "resultExport")
        self.assertEqual(auto["testExitCode"], 19)

    def test_full_review_business_assertion_category(self):
        _, auto, _ = self.run_injected_review("business")
        self.assertEqual(auto["failureCategory"], "businessAssertion")
        self.assertEqual(auto["testExitCode"], 1)

    def test_export_error_after_passing_tests_cannot_leave_pass_or_zero_exit(self):
        code, auto, _ = self.run_injected_review("cleanup-error")
        self.assertEqual(code, 1)
        self.assertEqual(auto["status"], "FAIL")
        self.assertEqual(auto["failureCategory"], "resultExport")
        self.assertIn("scratch cleanup failed", auto["error"])

    def test_full_review_controlled_mutations_pass(self):
        code, auto, _ = self.run_injected_review("success")
        self.assertEqual(code, 0)
        self.assertEqual(auto["status"], "PASS")
        self.assertIsNone(auto["failureCategory"])
        self.assertEqual(len(auto["mutations"]), 2)
        self.assertTrue(all(item["controlledAssertionFailure"] for item in auto["mutations"]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
