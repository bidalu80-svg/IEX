#!/usr/bin/env python3
"""Rewrite ZE_AOT_OBJECTS in Ze.xcodeproj/project.pbxproj from aot/*.o.

The images are linked by listing every object in OTHER_LDFLAGS, and that list
was hand-maintained: when a recording produced a new image (libwebp, pybinascii)
the file sat in aot/ while the app kept linking the old set, so the toggle
worked and the new library stayed slow. Run this after dropping a new
recording into aot/.
"""
import glob
import os
import re
import sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
objects = sorted(os.path.basename(p) for p in glob.glob(os.path.join(root, 'aot', '*.o')))
if not objects:
    sys.exit('no aot/*.o found')

value = ' '.join('$(SRCROOT)/aot/' + name for name in objects)
path = os.path.join(root, 'Ze.xcodeproj', 'project.pbxproj')
with open(path, encoding='utf-8', newline='') as handle:
    text = handle.read()

updated, count = re.subn(
    r'(ZE_AOT_OBJECTS = ")[^"]*(";)',
    lambda match: match.group(1) + value + match.group(2),
    text,
)
if count == 0:
    sys.exit('ZE_AOT_OBJECTS not found in project.pbxproj')

with open(path, 'w', encoding='utf-8', newline='') as handle:
    handle.write(updated)

print(f'{count} ZE_AOT_OBJECTS line(s) updated with {len(objects)} images')
for name in objects:
    print('  ' + name)
