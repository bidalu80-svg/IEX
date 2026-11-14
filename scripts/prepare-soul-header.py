#!/usr/bin/env python3
"""Extract actual chat header/chrome and Soul size controls for iOS 26 review."""
from pathlib import Path
import sys, subprocess, shutil, importlib.util, json, hashlib

sys.dont_write_bytecode = True
root = Path(__file__).resolve().parents[1]
work = Path(sys.argv[1]); work.mkdir(parents=True, exist_ok=True)
source = work / 'Header.swift'
catalog = work / 'Assets.xcassets'
subprocess.run([sys.executable, str(root/'scripts/extract-provider-chat-chrome.py'), str(source), str(catalog)], check=True)
old_harness = (root/'scripts/ProviderChatChromeHarness.swift').read_text(encoding='utf-8')
production = source.read_text(encoding='utf-8').removesuffix(old_harness)
assert len(production) < len(source.read_text(encoding='utf-8'))
fixtures = old_harness.split('private struct SettingsRowsGallery:', 1)[0]
chat = (root/'Views/Chat/AIChatView.swift').read_text(encoding='utf-8')
soul = (root/'Agent/Session/SoulStore.swift').read_text(encoding='utf-8')
settings = (root/'Views/Settings/SoulSettingsView.swift').read_text(encoding='utf-8')

def member(text, name):
    start = text.index(name)
    end = text.index('\n    }', start) + len('\n    }')
    return text[start:end]

metadata = soul[soul.index('enum SoulAppearancePreferences {'):soul.index('/// Result of parsing a SOUL.md')]
avatar = soul[soul.index('@MainActor\nstruct SoulAvatarView: View {'):]
header_members = '\n'.join(member(chat, '    private var '+name+':') for name in
                           ['chatHeaderSize','chatNavPrincipalContent','titleView','navigationStatusCapsule'])
leading = chat.split('ChatToolbarHost(key: chatToolbarKey, leading: {', 1)[1].split('            }, title:', 1)[0]
trailing = chat.split('            }, trailing: {', 1)[1].split('            })', 1)[0]
slider = settings.split('                VStack(alignment: .leading, spacing: 8) {', 1)[1].split('                LabeledContent(String(localized: "Style"))', 1)[0]
slider = 'VStack(alignment: .leading, spacing: 8) {' + slider
harness = (root/'scripts/SoulHeaderHarness.swift').read_text(encoding='utf-8')
harness = harness.replace('// PRODUCTION_HEADER', header_members)
harness = harness.replace('// PRODUCTION_LEADING', leading).replace('// PRODUCTION_TRAILING', trailing)
harness = harness.replace('// PRODUCTION_SLIDER', slider).replace('// PRODUCTION_PREVIEW', member(settings, '    private var previewCard:'))
source.write_text(production+'\n'+fixtures+'\n'+metadata+'\n'+avatar+'\n'+harness, encoding='utf-8')
shutil.copytree(root/'Assets.xcassets/ZeAssistantAvatar.imageset', catalog/'ZeAssistantAvatar.imageset', dirs_exist_ok=True)
files=['Views/Chat/AIChatView.swift','Agent/Session/SoulStore.swift','Views/Settings/SoulSettingsView.swift','scripts/SoulHeaderHarness.swift']
(work/'sources.json').write_text(json.dumps({'sha256':{p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in files},
    'scope':'Unchanged production center header, glass surfaces, progressive frost, provider artwork, Soul avatar and size controls. Fixture conversation/provider data and sheet destinations; phone/gear labels are fixtures. Not full AIChatView runtime.'}, indent=2))
spec=importlib.util.spec_from_file_location('driver',root/'scripts/share-xcui-driver.py')
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
module.DRIVER=(root/'scripts/SoulHeaderUITests.swift').read_text(encoding='utf-8'); module.write_project(work/'driver')
