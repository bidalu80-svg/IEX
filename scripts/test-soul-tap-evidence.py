#!/usr/bin/env python3
"""Check that the evidence gate rejects fixture actions and incomplete real taps."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('evidence', Path(__file__).with_name('check-soul-tap-evidence.py'))
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)


def trace(events):
    return [dict(event=event, sequence=index, touchID='actual-touch', point=[201, 84.33],
                 insideAvatarLabelCircle=True, deliveredIntoBadge=True, isPresented=True)
            for index, event in enumerate(events)]


CHAIN = ['touch.window.0', 'touch.began', 'avatar.action', 'settings.requested',
         'settings.appeared', 'settings.doneAppeared']


class EvidenceTests(unittest.TestCase):
    def test_full_chain_and_either_appearance_order(self):
        for events in (CHAIN, CHAIN[:-2] + list(reversed(CHAIN[-2:]))):
            self.assertTrue(evidence.verify(trace(events))['success'])

    def test_each_missing_link_fails(self):
        for event in CHAIN:
            with self.subTest(event=event), self.assertRaises(AssertionError):
                evidence.verify(trace([value for value in CHAIN if value != event]))

    def test_wrong_target_or_geometry_fails(self):
        for field in ('insideAvatarLabelCircle', 'deliveredIntoBadge'):
            rows = trace(CHAIN)
            rows[0][field] = False
            with self.subTest(field=field), self.assertRaises(AssertionError):
                evidence.verify(rows)

    def test_action_before_touch_does_not_prove_tap(self):
        with self.assertRaises(AssertionError):
            evidence.verify(trace(['avatar.action'] + [event for event in CHAIN if event != 'avatar.action']))


if __name__ == '__main__':
    unittest.main()
