#!/usr/bin/env python3
"""Require the real external avatar touch and the complete production action chain."""
import json
from pathlib import Path
import sys


def verify(rows):
    # A window sendEvent trace proves this was a dispatched UITouch, whereas
    # hitTest(point, nil) and direct fixture callbacks cannot satisfy this gate.
    starts = [row for row in rows if row['event'] == 'touch.window.0'
              and row.get('insideAvatarLabelCircle') is True]
    assert len(starts) == 1, f'Expected one real avatar-center touch, found {len(starts)}'
    start = starts[0]
    assert start['deliveredIntoBadge'], 'Real avatar touch did not enter badge'
    suffix = [row for row in rows if row['sequence'] >= start['sequence']]
    received = [row for row in suffix if row['event'] == 'touch.began'
                and row.get('touchID') == start['touchID']]
    assert received, 'Badge observer did not receive the actual avatar touch'
    assert received[0]['deliveredIntoBadge'], 'Badge observer reports another target'
    position = received[0]['sequence']
    for event in ['avatar.action', 'settings.requested', 'settings.appeared', 'settings.doneAppeared']:
        # SwiftUI may call the toolbar and sheet onAppear in either order.
        if event == 'settings.doneAppeared':
            lower_bound = request_position
        else:
            lower_bound = position
        matches = [row for row in suffix if row['event'] == event and row['sequence'] > lower_bound]
        assert matches, f'Missing production event after actual avatar touch: {event}'
        position = matches[0]['sequence']
        if event == 'settings.requested':
            assert matches[0]['isPresented'] is True, 'Settings request flag is false'
            request_position = position
    return {'success': True, 'touchID': start['touchID'], 'point': start['point'],
            'chain': ['window', 'badge', 'avatar.action', 'settings.requested',
                      'settings.appeared', 'settings.doneAppeared']}


if __name__ == '__main__':
    try:
        report = verify(json.loads(Path(sys.argv[1]).read_text()))
    except (AssertionError, OSError, ValueError, KeyError) as error:
        print(json.dumps({'success': False, 'error': str(error)}, ensure_ascii=False))
        sys.exit(1)
    print(json.dumps(report, ensure_ascii=False))
