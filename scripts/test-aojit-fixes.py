#!/usr/bin/env python3
"""Regress only the three astra review gaps; UI/Swift checks are structural."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]


class ReviewFixTests(unittest.TestCase):
    def aot_step(self):
        workflow = yaml.safe_load((ROOT / '.github/workflows/build.yml').read_text())
        steps = [s for job in workflow['jobs'].values() for s in job.get('steps', []) if s.get('id') == 'aot']
        self.assertEqual(len(steps), 1)
        step = steps[0]
        self.assertFalse(step.get('continue-on-error', False))
        return step

    def test_main_build_without_objects_fails_even_with_full_recording_requested(self):
        step = self.aot_step()
        for full in ('0', '1'):
            with self.subTest(AOT_FULL=full), tempfile.TemporaryDirectory() as tmp:
                env_file = Path(tmp) / 'env'
                result = subprocess.run(['bash', '-c', step['run']], cwd=tmp, text=True, capture_output=True,
                                        env=dict(os.environ, AOT_FULL=full, GITHUB_ENV=str(env_file)))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('Inline recording is disabled', result.stdout)
                self.assertFalse(env_file.exists())
                self.assertFalse(list(Path(tmp).rglob('*.S')))
                self.assertFalse(list(Path(tmp).rglob('*.o')))
        self.assertNotIn('scripts/aot-manifest.txt', step['run'])
        self.assertNotIn('tools/jit_aot/record.sh', step['run'])

    def test_main_build_with_committed_objects_only_links(self):
        step = self.aot_step()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'aot').mkdir()
            # Text marker only; not a generated AOT image.
            obj = root / 'aot/aot_fixture.o'
            obj.write_text('fixture')
            env_file = root / 'env'
            result = subprocess.run(['bash', '-c', step['run']], cwd=tmp, text=True, capture_output=True,
                                    env=dict(os.environ, AOT_FULL='1', GITHUB_ENV=str(env_file)))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(env_file.read_text().strip(), f'AOT_OBJECTS={obj}')
            self.assertEqual(obj.read_text(), 'fixture')
            self.assertFalse(list(root.rglob('*.S')))

    def test_disabled_legacy_entry_cannot_start_an_unchecked_recorder(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            executable = root / 'unchecked-ish'
            executable.write_text('#!/bin/sh\ntouch "' + str(root / 'invoked') + '"\nexit 0\n')
            executable.chmod(0o755)
            output = root / 'image.S'
            result = subprocess.run(['sh', str(ROOT / 'Vendor/ZeNative/ish/tools/jit_aot/record.sh'),
                                     str(executable), str(root), '/workload.sh', str(output), 'ld-musl'],
                                    text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Legacy AOJIT recording is disabled', result.stderr)
            self.assertFalse((root / 'invoked').exists())
            self.assertFalse(output.exists())

    def test_confirmation_uses_real_linked_image_evidence_not_installed_status(self):
        source = (ROOT / 'Agent/ISH/AOJITAcceleration.swift').read_text()
        evidence = source.split('var hasRecordedImage: Bool {', 1)[1].split('\n    }', 1)[0]
        self.assertIn('AOJITModuleProbe.images.contains', evidence)
        self.assertIn('library.imageMatch.contains', evidence)
        self.assertNotIn('status', evidence)
        self.assertNotIn('installedVersion', evidence)
        view = (ROOT / 'Views/Rootfs/AOJITSection.swift').read_text()
        confirmation = view.split('let message = state.hasRecordedImage', 1)[1].split('\n            }', 1)[0]
        self.assertIn('? String(localized: "This installs the recorded version', confirmation)
        self.assertIn(': String(localized: "This installs the recording target', confirmation)
        self.assertIn('No AOJIT image has been recorded for this target.', confirmation)

    def test_current_fallbacks_reference_actual_provenance_and_pending_versions_have_no_literals(self):
        source = (ROOT / 'Agent/ISH/AOJITAcceleration.swift').read_text()
        image_table = source.split('static let imageVersions', 1)[1].split('= [', 1)[1].split(']', 1)[0]
        actual = dict(re.findall(r'"([^"]+)": "([^"]+)"', image_table))
        catalog = source.split('static let catalog:', 1)[1].split('// MARK: Published', 1)[0]
        entries = catalog.split('        AOJITLibrary(')[1:]
        self.assertEqual(len(entries), 25)
        for row in entries:
            image_id = re.search(r'id: "([^"]+)"', row)[1]
            if image_id == 'nodejs':
                self.assertIn('repairVersion: AOJITRecordingTargets.version(for: "nodejs")', row)
            elif image_id == 'sqlite':
                self.assertIn('repairVersion: AOJITModuleProbe.hasLegacySQLiteImage', row)
                self.assertIn('(AOJITAcceleration.imageVersions["python3"] ?? "")', row)
                self.assertIn(': AOJITRecordingTargets.version(for: "sqlite")', row)
            else:
                package = re.search(r'package: "([^"]+)"', row)[1]
                self.assertIn(package, actual)
                self.assertIn(f'repairVersion: AOJITAcceleration.imageVersions["{package}"] ?? ""', row)
            self.assertNotRegex(row, r'repairVersion: "\d')
        targets = json.loads((ROOT / 'scripts/aot-targets.json').read_text())['images']
        future_only = {t['version'] for t in targets} - set(actual.values())
        for path in (ROOT / 'Agent/ISH').glob('AOJIT*.swift'):
            for version in future_only:
                self.assertNotIn(version, path.read_text(), f'{path.name}: future-only literal {version}')

    def test_pending_configuration_resource_is_in_app_and_unknown_version_disables_install(self):
        project = (ROOT / 'Ze.xcodeproj/project.pbxproj').read_text()
        resources = project.split('E51000042 /* Resources */ = {', 1)[1].split('\n\t\t};', 1)[0]
        self.assertIn('aot-targets.json in Resources', resources)
        self.assertIn('path = "scripts/aot-targets.json"; sourceTree = SOURCE_ROOT;', project)
        self.assertIn('AOJITRecordingTargets.swift in Sources', project)
        helper = (ROOT / 'Agent/ISH/AOJITRecordingTargets.swift').read_text()
        self.assertIn('forResource: "aot-targets", withExtension: "json"', helper)
        self.assertIn('versions[id] ?? ""', helper)
        source = (ROOT / 'Agent/ISH/AOJITAcceleration.swift').read_text()
        self.assertIn('!targetVersion.isEmpty', source)
        repair = source.split('func repair(', 1)[1]
        self.assertIn('guard busyLibraryId == nil, state.library.offersOnlineFix else { return }', repair)


if __name__ == '__main__':
    unittest.main(verbosity=2)
