#!/usr/bin/env python3
"""Exercise harness process control without Apple tools or simulator fixtures."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BOUNDED = ROOT / 'scripts/run-bounded-command.py'


class BoundedCommandTests(unittest.TestCase):
    def invoke(self, source, timeout=2):
        return subprocess.run([sys.executable, str(BOUNDED), '--timeout', str(timeout),
                               '--', sys.executable, '-c', source], capture_output=True, text=True, timeout=10)

    def test_success_and_failure_status(self):
        for expected in (0, 65):
            result = self.invoke(f'print("test output", flush=True); raise SystemExit({expected})')
            self.assertEqual(result.returncode, expected, result.stderr)
            self.assertIn('test output', result.stdout)

    def test_timeout_kills_stubborn_process_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory) / 'child.pid'
            child = 'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)'
            source = ('import subprocess,sys,time; from pathlib import Path; '
                      f'p=subprocess.Popen([sys.executable,"-c",{child!r}]); '
                      f'Path({str(pid_file)!r}).write_text(str(p.pid)); time.sleep(30)')
            result = self.invoke(source, timeout=0.5)
            self.assertEqual(result.returncode, 124, result.stderr)
            self.assertIn('exceeded', result.stderr)
            pid = int(pid_file.read_text())
            # An orphan may briefly be a zombie until init reaps it; it cannot run.
            try:
                state = Path(f'/proc/{pid}/stat').read_text().split()[2]
            except FileNotFoundError:
                state = 'gone'
            self.assertIn(state, ('gone', 'Z'))

    def test_log_capture_and_failure_output(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'failure.log'
            result = subprocess.run([sys.executable, str(BOUNDED), '--timeout', '2', '--log', str(log),
                                     '--', sys.executable, '-c', 'print("assertion failed"); raise SystemExit(65)'],
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 65)
            self.assertEqual(log.read_text(), 'assertion failed\n')
            self.assertIn('assertion failed', result.stdout)


# Only external Apple operations and asset preparation are simulated. The actual
# shell script, selection script, bounded runner and plist rewriting all execute.
STUB = r'''import json,os,pathlib,plistlib,sys
args=sys.argv[1:]; name=pathlib.Path(sys.argv[0]).name
with open(os.environ['HARNESS_COMMAND_LOG'],'a') as f: f.write(json.dumps([name,*args])+'\n')
if name=='python3':
    if args and args[0]=='scripts/prepare-voice-call-ui.py':
        work=pathlib.Path(args[1]);work.mkdir(parents=True,exist_ok=True)
        (work/'sources.json').write_text('{}')
        sys.exit(0)
    os.execv(os.environ['HARNESS_REAL_PYTHON'],[os.environ['HARNESS_REAL_PYTHON'],*args])
if name=='xcrun':
    if args[:4]==['simctl','list','devices','available']:
        entries={'com.apple.CoreSimulator.SimRuntime.iOS-26-4':[{'name':'iPhone New','udid':'new26','state':'Booted'}]}
        if os.environ.get('HARNESS_HAVE_18','1')=='1':
            entries['com.apple.CoreSimulator.SimRuntime.iOS-18-5']=[{'name':'iPhone Baseline','udid':'baseline18','state':os.environ.get('HARNESS_DEVICE_STATE','Booted')}]
        print(json.dumps({'devices':entries}))
    elif '--show-sdk-path' in args:
        if os.environ.get('HARNESS_SDK_WARNING')=='1':
            print('xcrun: warning: SDK diagnostic\nadditional diagnostic line',file=sys.stderr)
            print('  /mock/sdk  \n')
        else: print('/mock/sdk')
    elif args[:2]==['xcresulttool','export']: sys.exit(7) # export must not mask XCTest's status
elif name=='xcodebuild':
    if args[0]=='build-for-testing':
        products=pathlib.Path(args[args.index('-derivedDataPath')+1])/'Build/Products'
        products.mkdir(parents=True,exist_ok=True)
        (products/'Driver.xctestrun').write_bytes(plistlib.dumps({'TestConfigurations':[{'TestTargets':[{}]}]}))
    else:
        print('UI test result output')
        sys.exit(int(os.environ.get('HARNESS_TEST_RESULT','0')))
'''


class VoiceShellTests(unittest.TestCase):
    def run_harness(self, **overrides):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            (base / 'scripts').symlink_to(ROOT / 'scripts', target_is_directory=True)
            binaries = base / 'bin'
            binaries.mkdir()
            for name in ('python3', 'xcrun', 'xcodebuild', 'codesign'):
                path = binaries / name
                path.write_text(f'#!{sys.executable}\n' + STUB)
                path.chmod(0o755)
            env = {**os.environ, 'PATH': str(binaries) + os.pathsep + os.environ['PATH'],
                   'RUNNER_TEMP': str(base / 'work'), 'HARNESS_REAL_PYTHON': sys.executable,
                   'HARNESS_COMMAND_LOG': str(base / 'commands.jsonl'), **overrides}
            if 'ZE_SIMULATOR_IOS_MAJOR' not in overrides:
                env.pop('ZE_SIMULATOR_IOS_MAJOR', None)
            result = subprocess.run(['bash', str(ROOT / 'scripts/test-voice-call-ui.sh')],
                                    cwd=base, env=env, capture_output=True, text=True, timeout=15)
            commands = [json.loads(line) for line in (base / 'commands.jsonl').read_text().splitlines()]
            return result, commands

    def test_success_exits_despite_attachment_export_failure(self):
        result, commands = self.run_harness()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        build = next(c for c in commands if c[:2] == ['xcodebuild', 'build-for-testing'])
        self.assertEqual(build[build.index('-destination') + 1], 'generic/platform=iOS Simulator')
        test = next(c for c in commands if c[:2] == ['xcodebuild', 'test-without-building'])
        self.assertIn('platform=iOS Simulator,id=baseline18', test)
        self.assertFalse(any(c[:3] == ['xcrun', 'simctl', 'boot'] for c in commands))

    def test_real_ui_failure_propagates(self):
        result, _ = self.run_harness(HARNESS_TEST_RESULT='65')
        self.assertEqual(result.returncode, 65, result.stderr + result.stdout)
        self.assertIn('UI test result output', result.stdout)

    def test_sdk_stderr_warning_cannot_corrupt_trimmed_stdout(self):
        result, commands = self.run_harness(HARNESS_SDK_WARNING='1')
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn('xcrun: warning: SDK diagnostic\nadditional diagnostic line', result.stdout)
        compile_command = next(c for c in commands if c[:4] == ['xcrun', '--sdk', 'iphonesimulator', 'swiftc'])
        self.assertEqual(compile_command[compile_command.index('-sdk') + 1], '/mock/sdk')
        sdk_runner = next(c for c in commands if c[:2] == ['python3', 'scripts/run-bounded-command.py']
                          and 'voice-call-ui-evidence/sdk-path.log' in c)
        self.assertGreater(float(sdk_runner[sdk_runner.index('--timeout') + 1]), 0)
        self.assertLessEqual(float(sdk_runner[sdk_runner.index('--timeout') + 1]), 504)

    def test_shutdown_device_is_booted(self):
        result, commands = self.run_harness(HARNESS_DEVICE_STATE='Shutdown')
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn(['xcrun', 'simctl', 'boot', 'baseline18'], commands)

    def test_missing_runtime_fails_instead_of_skipping_ui_tests(self):
        result, commands = self.run_harness(HARNESS_HAVE_18='0', ZE_SIMULATOR_IOS_MAJOR='18')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no available iPhone simulator for iOS 18', result.stdout)
        self.assertFalse(any(c[:2] == ['xcodebuild', 'test-without-building'] for c in commands))

    def test_auto_runs_on_hosts_with_only_ios_26(self):
        result, commands = self.run_harness(HARNESS_HAVE_18='0')
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        test = next(c for c in commands if c[:2] == ['xcodebuild', 'test-without-building'])
        self.assertIn('platform=iOS Simulator,id=new26', test)


if __name__ == '__main__':
    unittest.main()
