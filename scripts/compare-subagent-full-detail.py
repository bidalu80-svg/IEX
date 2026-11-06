#!/usr/bin/env python3
"""Pair actual complete detail components; top/bottom panes remain explicit."""
import json
import pathlib
from PIL import Image, ImageDraw
source=pathlib.Path('subagent-full-detail-evidence')
manifest=json.loads((source/'upstream-sources.json').read_text())
reference=json.loads((source/'reference-detail-result.json').read_text())
ze=json.loads((source/'ze-detail-result.json').read_text())
assert reference['success'] and ze['success']
pairs=[]
for shot in reference['screenshots']:
    left=Image.open(source/shot['file']).convert('RGB')
    local_name=shot['file'].replace('reference-detail-','ze-detail-',1)
    right=Image.open(source/local_name).convert('RGB')
    assert left.size==right.size,(left.size,right.size)
    w,h=left.size
    pair=Image.new('RGB',(w*2+12,h+44),'#dedede')
    pair.paste(left,(0,44));pair.paste(right,(w+12,44))
    draw=ImageDraw.Draw(pair)
    draw.text((12,12),'REFERENCE '+manifest['commit'][:12],fill='black')
    draw.text((w+24,12),'ZE - COMPLETE DETAIL',fill='black')
    name=shot['file'].replace('reference-detail-','compare-detail-',1)
    pair.save(source/name)
    pairs.append({'file':name,'reference':shot['file'],'ze':local_name,'size':list(left.size)})
result={'success':True,'pairs':pairs,'scope':'Unmodified complete detail components. Each image shows the real top and bottom scroll positions; the two panes may overlap. No Markdown, image, or thinking badge in this fixture. Real empty-output result and live action controls included. Screenshot assembly is not visual acceptance or FPS evidence.'}
(source/'comparison-result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
print(json.dumps(result,indent=2))
