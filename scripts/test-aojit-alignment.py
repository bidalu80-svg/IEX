#!/usr/bin/env python3
"""Recording failures, real object provenance and actual native switch regression checks.

Swift/device tests are separate: this script never claims to compile the app.
"""
import copy
import importlib.util
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / file)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


rec = module('rec', 'record-aot.py')
artifact = module('artifact', 'check-aot-artifact.py')


def elf(build_id):
    note = struct.pack('<III', 4, len(build_id), 3) + b'GNU\0' + build_id
    data = bytearray(120 + len(note))
    data[:6] = b'\x7fELF\x02\x01'
    struct.pack_into('<Q', data, 32, 64)
    struct.pack_into('<HH', data, 54, 56, 1)
    struct.pack_into('<I', data, 64, 4)
    struct.pack_into('<Q', data, 72, 120)
    struct.pack_into('<Q', data, 96, len(note))
    data[120:] = note
    return data


class RecordingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def stage(self):
        for t in rec.TARGETS['images']:
            file = self.root / t['path'].lstrip('/')
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(elf(bytes.fromhex(t['build_id'])))
            file = self.root / t['workload'].lstrip('/')
            file.parent.mkdir(parents=True, exist_ok=True)
            file.touch()

    @staticmethod
    def guest(ish, root, command, **kwargs):
        if command == ':':
            Path(kwargs['env']['ISH_JIT_RECORD']).write_text(json.dumps({'header': {'abi': int(rec.TARGETS['abi'], 16)}}) + '\n')
        if command.startswith('apk info -e -v '):
            package = command.split("'")[1]
            t = next(t for t in rec.TARGETS['images'] if t['package'] == package)
            return subprocess.CompletedProcess([], 0, f"{package}-{t['version']}\n")
        return subprocess.CompletedProcess([], 0, f"images: 0 (abi {rec.TARGETS['abi']})\n")

    def test_reference_table_and_effective_manifest(self):
        entries = rec.manifest()
        self.assertEqual(len(entries), 24)
        self.assertEqual(entries['sqlite'][0], 'libsqlite3.so')
        self.assertNotIn('nodejs', entries)
        self.assertEqual(entries['musl'][2], 600)
        for t in rec.TARGETS['images']:
            workload = entries[t['id']][1].read_text()
            if t['id'] == 'musl':
                self.assertNotIn('/tmp/aojit', workload)
                self.assertIn('W=/tmp/aotw-musl', workload)
            elif t['id'] in ('ssh', 'scp'):
                self.assertIn('. /tmp/aojit/ssh/sshd_setup.sh', workload)
                self.assertIn('/bin/sh ' + t['workload'], workload)
            else:
                self.assertIn('exec /bin/sh ' + t['workload'], workload)
        source = ROOT / 'openminis-ref/src/ios/Views/Rootfs/AOJITSettingsView.swift'
        if source.exists():
            text = source.read_text()
            for t in rec.TARGETS['images']:
                self.assertIn('buildId: "' + t['build_id'] + '"', text)
                self.assertIn('package: "' + t['package'] + ' ' + t['version'] + '"', text)

    def test_all_24_identities_pass_preflight(self):
        self.stage()
        with patch.object(rec, 'run_guest', self.guest):
            self.assertGreater(len(rec.preflight(Path('/fake-ish'), self.root)), 10)

    def test_equal_package_version_cannot_hide_wrong_build_id(self):
        self.stage()
        t = rec.TARGETS['images'][0]
        (self.root / t['path'].lstrip('/')).write_bytes(elf(bytes(20)))
        with patch.object(rec, 'run_guest', self.guest), self.assertRaisesRegex(ValueError, 'expected ELF'):
            rec.preflight(Path('/fake-ish'), self.root)

    def test_exact_package_unavailable_fails(self):
        self.stage()
        result = subprocess.CompletedProcess([], 0, 'musl-1.2.5-r12\n')
        with patch.object(rec, 'run_guest', return_value=result), self.assertRaisesRegex(ValueError, 'exact package'):
            rec.preflight(Path('/fake-ish'), self.root)

    def test_wrong_emitting_abi_fails_before_training(self):
        self.stage()
        def wrong_abi(ish, root, command, **kwargs):
            result = self.guest(ish, root, command, **kwargs)
            if command == ':':
                Path(kwargs['env']['ISH_JIT_RECORD']).write_text(json.dumps({'header': {'abi': 1}}) + '\n')
            return result
        with patch.object(rec, 'run_guest', wrong_abi), self.assertRaisesRegex(ValueError, 'recorder ABI'):
            rec.preflight(Path('/fake-ish'), self.root)

    def test_missing_reference_workload_fails(self):
        self.stage()
        (self.root / rec.TARGETS['images'][0]['workload'].lstrip('/')).unlink()
        with patch.object(rec, 'run_guest', self.guest), self.assertRaisesRegex(ValueError, 'missing reference workload'):
            rec.preflight(Path('/fake-ish'), self.root)

    def test_tls_success_markers_and_failure_exit(self):
        target = next(t for t in rec.TARGETS['images'] if t['id'] == 'libssl')
        for code, output in [(0, 'tls-train-ok'), (0, 'FAIL agent-cold-ok tls-train-ok'), (1, 'agent-cold-ok tls-train-ok')]:
            with self.assertRaises(ValueError):
                rec.check_output(subprocess.CompletedProcess([], code, output), target, 'dry')
        rec.check_output(subprocess.CompletedProcess([], 0, 'agent-cold-ok tls-train-ok'), target, 'dry')

    def test_elf_parser_truncation_and_symlink(self):
        file = self.root / 'input'
        expected = '1234567890abcdef' * 2 + '12345678'
        file.write_bytes(elf(bytes.fromhex(expected)))
        self.assertEqual(rec.build_id(file), expected)
        (self.root / 'link').symlink_to('/input')
        self.assertEqual(rec.guest_file(self.root, '/link'), file)
        file.write_bytes(file.read_bytes()[:-1])
        with self.assertRaisesRegex(ValueError, 'truncated'):
            rec.build_id(file)

    def test_incomplete_artifact_cannot_be_published(self):
        with self.assertRaisesRegex(ValueError, 'missing'):
            artifact.check(self.root)

    def test_mixed_recording_ledger_is_rejected(self):
        # Synthetic artifact markers only, never AOT binaries or generated code.
        for t in rec.TARGETS['images']:
            for suffix in ('S', 'o'):
                (self.root / f"aot_{t['id']}.{suffix}").write_text('test marker')
            (self.root / f"RECORDED-{t['id']}.json").write_text(json.dumps(t))
        (self.root / 'TARGETS.json').write_text(json.dumps(rec.TARGETS))
        versions = {f"{t['package']}-{t['version']}" for t in rec.TARGETS['images']}
        (self.root / 'VERSIONS.txt').write_text('\n'.join(versions))
        artifact.check(self.root)
        wrong = dict(rec.TARGETS['images'][0], build_id='wrong')
        (self.root / 'RECORDED-musl.json').write_text(json.dumps(wrong))
        with self.assertRaisesRegex(ValueError, 'mixed recording'):
            artifact.check(self.root)


class IntegrationTests(unittest.TestCase):
    def test_boot_applies_both_saved_values_before_pid1(self):
        text = (ROOT / 'iSH/ISHKernel.m').read_text()
        boot = text[text.index('- (int)bootWithRootPath:'):]
        self.assertLess(boot.index('ish_jit_set_enabled(aojitEnabled)'), boot.index('become_first_process()'))
        self.assertIn('objectForKey:@"aojit.enabled"] == nil', boot)
        self.assertIn('boolForKey:@"aojit.enabled"', boot)
        self.assertNotIn('if (aojitEnabled)', boot[:boot.index('become_first_process()')])

    def test_project_resource_belongs_to_app(self):
        text = (ROOT / 'Ze.xcodeproj/project.pbxproj').read_text()
        app = text.split('E51000042 /* Resources */ = {', 1)[1].split('\n\t\t};', 1)[0]
        self.assertIn('AOJITRestore in Resources', app)
        for name in ('AOJITModuleProbe', 'AOJITRuntimeStatus', 'AOJITShellStats', 'AOJITRestore', 'AOJITRestoreButton'):
            self.assertIn(name + '.swift in Sources', text)

    def test_equal_versions_no_longer_create_available(self):
        text = (ROOT / 'Agent/ISH/AOJITAcceleration.swift').read_text()
        block = text.split('private func rebuildStates()', 1)[1].split('private static func rank', 1)[0]
        self.assertNotIn('recorded == installed', block)
        self.assertNotIn('runtime.match == 1', block)
        self.assertIn('AOJITModuleProbe.state', block)
        self.assertIn('case .matched: status = hasImage ? .available : .noImage', block)
        self.assertIn('status = .rejected', block)
        self.assertNotIn('recordMissingImages()', text)
        self.assertIn('private static func parseProbe(', text)
        self.assertIn('private static var recordingsURL:', text)
        view = (ROOT / 'Views/Rootfs/AOJITSection.swift').read_text()
        self.assertNotIn('aotHitCount + aojit.translatedBlockCount', view)
        self.assertIn('\\(aojit.aotHitCount) / \\(aojit.translatedBlockCount)', view)

    def test_native_switch_actual_production_functions(self):
        compiler = shutil.which('cc')
        if not compiler:
            self.skipTest('C compiler unavailable')
        source = (ROOT / 'Vendor/ZeNative/ish/asbestos/guest-arm64/jit.c').read_text()
        def function(signature):
            start = source.index(signature)
            brace = source.index('{', start)
            depth = 1
            end = brace + 1
            while depth:
                depth += (source[end] == '{') - (source[end] == '}')
                end += 1
            return source[start:end]
        header = '''#include <assert.h>
#include <stdbool.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
static bool aot_off, jit_on;
static void *region;
static unsigned aot_nregistered = 1;
static unsigned init_count;
static pthread_once_t init_once = PTHREAD_ONCE_INIT;
static void jit_init(void) { ++init_count; jit_on = true; }
'''
        functions = '\n'.join(function(sig) for sig in ('int jit_control(', 'void ish_jit_set_enabled(', 'bool ish_jit_is_enabled('))
        main = '''
int main(void) {
 ish_jit_set_enabled(false); /* cold boot with saved OFF must override init */
 assert(init_count == 1 && !jit_on && aot_off && !ish_jit_is_enabled());
 ish_jit_set_enabled(true);
 assert(init_count == 1 && jit_on && !aot_off && ish_jit_is_enabled());
 ish_jit_set_enabled(false);
 assert(!jit_on && aot_off);
 aot_nregistered = 0; ish_jit_set_enabled(true);
 assert(!jit_on && !ish_jit_is_enabled());
 return 0;
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'switch.c'
            path.write_text(header + functions + main)
            subprocess.run([compiler, '-std=c11', '-Wall', '-Werror', '-pthread', str(path), '-o', tmp + '/switch'], check=True)
            subprocess.run([tmp + '/switch'], check=True, timeout=10)

    def test_recording_import_updates_actual_versions_and_preserves_project_endings(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for directory in ('scripts', 'aot', 'Agent/ISH', 'Ze.xcodeproj'):
                (root / directory).mkdir(parents=True)
            for file in ('scripts/sync-aot-objects.py', 'aot/VERSIONS.txt',
                         'Agent/ISH/AOJITAcceleration.swift', 'Ze.xcodeproj/project.pbxproj'):
                shutil.copyfile(ROOT / file, root / file)
            # Import test uses text markers; no AOT binary is generated.
            (root / 'aot/aot_nodejs.o').write_text('marker')
            versions = (root / 'aot/VERSIONS.txt').read_text() + 'nodejs-22.23.2-r0\n'
            (root / 'aot/VERSIONS.txt').write_text(versions)
            subprocess.run([shutil.which('python3'), str(root / 'scripts/sync-aot-objects.py')], check=True, stdout=subprocess.PIPE)
            accel = (root / 'Agent/ISH/AOJITAcceleration.swift').read_text()
            self.assertIn('"nodejs": "22.23.2-r0"', accel)
            project = (root / 'Ze.xcodeproj/project.pbxproj').read_bytes()
            self.assertIn(b'$(SRCROOT)/aot/aot_nodejs.o', project)
            original = (ROOT / 'Ze.xcodeproj/project.pbxproj').read_bytes()
            self.assertEqual(project.count(b'\r\n'), original.count(b'\r\n'))
            self.assertEqual(project.count(b'\n'), original.count(b'\n'))

    def test_all_current_aot_objects_unchanged(self):
        objects = sorted((ROOT / 'aot').glob('*.o'))
        self.assertEqual(len(objects), 24)
        self.assertFalse((ROOT / 'aot/aot_nodejs.o').exists())
        for obj in objects:
            original = subprocess.check_output(['git', '-C', str(ROOT), 'show', '2e0fdee4:' + str(obj.relative_to(ROOT))])
            self.assertEqual(original, obj.read_bytes(), obj.name)
        self.assertIn(b'/usr/lib/python3.12/lib-dynload/_sqlite3.cpython-312-aarch64-linux-musl.so', (ROOT / 'aot/aot_sqlite.o').read_bytes())


if __name__ == '__main__':
    unittest.main(verbosity=2)
