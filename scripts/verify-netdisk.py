#!/usr/bin/env python3
"""Static integration/EOL checks plus bidirectional scripts literal inventory.
This does not compile Swift or verify live protocol interoperability.
"""
from pathlib import Path
import argparse
import ast
import difflib
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--base', default='42339dfa9a68dff11dd856ab6c6867657b851841')
p.add_argument('--scan-json', type=Path, help='write literal changes for human review')
args = p.parse_args()

def git(*arguments):
    return subprocess.check_output(['git', *arguments], cwd=ROOT)

def text(path):
    return (ROOT/path).read_text(encoding='utf-8-sig')

checks = 0
def check(condition, message):
    global checks
    if not condition:
        raise AssertionError(message)
    checks += 1
    print('PASS:', message)

service = text('Shared/RemoteServers/RemoteDiskService.swift')
store = text('Shared/RemoteServers/RemoteDiskStore.swift')
wire = text('Shared/RemoteServers/RemoteStorageWireSupport.swift')
clients = text('Shared/RemoteServers/RemoteStorageClients.swift')
browser = text('Views/Servers/RemoteDiskBrowserView.swift')
settings = text('Views/Servers/RemoteDiskSettingsView.swift')
tools = text('Agent/Chat/AIChatViewModel+RemoteDisks.swift')
filetools = text('Agent/Chat/AIChatViewModel+FileTools.swift')
project = text('Ze.xcodeproj/project.pbxproj')
interface = service.split('protocol RemoteDiskReading {', 1)[1].split('\n}', 1)[0]
check(set(re.findall(r'func (\w+)\(', interface)) == {'testConnection', 'list', 'download'}, 'disk interface exposes only three read operations')
check(not re.search(r'\.(?:upload|uploadFile|executeCommand|rename|deleteFile|createDirectoryAtPath)\(', service), 'disk service does not call remote mutation/command APIs')
for start, end in [('func executeFileWrite(', 'func executeFileEdit('), ('func executeFileEdit(', None)]:
    block = filetools.split(start, 1)[1]
    if end:
        block = block.split(end, 1)[0]
    check('Self.isRemoteDiskPath(path)' in block and 'RemoteDiskError.readOnly' in block, start + ' rejects remote writes')
check('remoteDiskToolDefinitions()' in text('Agent/Chat/AIChatViewModel+ToolDefinitions.swift') and 'case "remote_disk_list":' in text('Agent/Chat/AIChatViewModel+ConcurrentTools.swift'), 'list tool is registered and dispatched')
parameters = tools.split('parameters: [', 1)[1].split('], required:', 1)[0]
check(set(re.findall(r'"(\w+)": \.init', parameters)) == {'path', 'offset', 'limit'}, 'list tool accepts no credential/endpoint fields')
check('prepareRemoteDiskFile(path)' in filetools and 'encoding: .utf8' in filetools and 'let kMaxFileReadChars = 80_000' in filetools, 'remote file reads use the existing text/line/output path')
check('64 * 1024 * 1024' in service and 'maximumBytes: limit' in service and 'session.bytes(for: request)' in wire, 'remote byte limit is independent of text output; HTTP streams')
check('receiveAll(from: dataConnection, maximumBytes: maximumBytes)' in clients and 'downloadFile(at: confined, on: id, maximumBytes: limit)' in service, 'FTP and SFTP receive byte limits')
check('disk.configurationRevision = UUID()' in store, 'credential-only saves invalidate outstanding requests')
check('sshRevision' in service and 'result.sshUpdatedAt == sshRevision(for: disk)' in store, 'SSH revision guards data and verification publication')
check('RemoteServerSecretStore.save' in store and 'disks.json' in store and 'try persist()' in store, 'configuration persists separately from Keychain secrets')
check('hostKeyUntrusted' in settings and 'setKnownHost' in settings and '信任并重试' in settings, 'SFTP host trust uses explicit existing trust flow')
check('RemoteDiskSettingsView()' in text('Views/ContentView.swift') and 'RemoteStorageConfigurationFields(profile: configurationBinding' in text('Views/Backup/ICloudBackupView.swift'), 'settings entry and shared backup form are connected')
check('RemoteDiskPickerView()' in text('Views/Rootfs/FileBrowserView.swift') and '目录读取失败' in browser and 'self.error = error.localizedDescription' in browser, 'file source picker and visible directory failure exist')
check(not any(x in browser for x in ['.upload(', '.uploadFile(', '.rename(', '.deleteFile(', '.executeCommand(', '.swipeActions']), 'remote browser has no remote mutation controls')
chat = text('Views/Chat/AIChatView.swift')
check('showRemoteDiskPicker' in chat.split('private var hasOverlayPresented:', 1)[1].split('\n    }', 1)[0] and 'try vm.addRemoteDiskAttachment(from: url)' in chat, 'chat picker participates in overlay gating and adds attachments')
attachments = text('Agent/Chat/AIChatViewModel+Attachments.swift')
check('addFileAttachment(from: url)' in tools and '.imageData(data:' in attachments and '.imageData(data:' in text('Agent/Chat/AIChatViewModel.swift') and 'uploadsDir.appendingPathComponent' in attachments, 'remote images/documents enter existing queue and immediate-send chains')
check('QLPreviewController' in browser and 'QuickLook' in text('Views/Chat/ChatInputBar.swift'), 'remote files and draft attachments reach actual preview controllers')
for index, name in enumerate(['RemoteStorageWireSupport.swift', 'RemoteDiskStore.swift', 'RemoteDiskService.swift', 'RemoteDiskSettingsView.swift', 'AIChatViewModel+RemoteDisks.swift', 'RemoteDiskBrowserView.swift'], 1):
    build_id = 'D8D150' + f'{index:018d}'
    file_id = 'D8D160' + f'{index:018d}'
    check(project.count(f'{build_id} /* {name} in Sources */') == 2 and project.count(f'{file_id} /* {name} */') == 3, 'unique Xcode reference/group/source membership: ' + name)

# Check the terminators on unchanged lines, including files with mixed CRLF/LF.
# This detects whole-file normalization without requiring one newline convention.
changed = set(git('diff', '--name-only', args.base).decode().splitlines())
changed.update(git('ls-files', '--others', '--exclude-standard').decode().splitlines())
production = sorted(n for n in changed if n.endswith(('.swift', '.pbxproj')) and not n.startswith('scripts/'))
eol_changes = []
for name in production:
    exists = subprocess.run(['git', 'cat-file', '-e', f'{args.base}:{name}'], cwd=ROOT, capture_output=True).returncode == 0
    if not exists:
        continue
    old = git('show', f'{args.base}:{name}').splitlines(keepends=True)
    new = (ROOT/name).read_bytes().splitlines(keepends=True)
    a = [line.rstrip(b'\r\n') for line in old]
    b = [line.rstrip(b'\r\n') for line in new]
    for block in difflib.SequenceMatcher(a=a, b=b, autojunk=False).get_matching_blocks():
        for i in range(block.size):
            left, right = old[block.a+i], new[block.b+i]
            if left[len(a[block.a+i]):] != right[len(b[block.b+i]):]:
                eol_changes.append({'file': name, 'old_line': block.a+i+1, 'new_line': block.b+i+1})
check(not eol_changes, 'unchanged source lines preserve their original CRLF/LF terminators: ' + str(eol_changes[:5]))

# Inventory script literals in BOTH directions, including scripts' negative
# assertions and block(...) boundaries. Changes are evidence to review, not an
# automatic correctness decision; Swift/shell extraction is intentionally lexical.
literals = {}
for path in sorted((ROOT/'scripts').rglob('*')):
    if path.suffix not in {'.py', '.swift', '.sh'}:
        continue
    content = path.read_text(encoding='utf-8', errors='replace')
    if path.suffix == '.py':
        try:
            values = [n.value for n in ast.walk(ast.parse(content)) if isinstance(n, ast.Constant) and isinstance(n.value, str)]
        except SyntaxError:
            continue
    else:
        values = []
        for match in re.finditer(r'"(?:[^"\\]|\\.)*"', content):
            try:
                values.append(json.loads(match.group()))
            except json.JSONDecodeError:
                pass
    for value in values:
        if len(value) >= 12 and '\n' not in value:
            literals.setdefault(value, set()).add(str(path.relative_to(ROOT)))
inventory = {'base': args.base, 'scope': production, 'literal_count': len(literals), 'changes': []}
for name in production:
    exists = subprocess.run(['git', 'cat-file', '-e', f'{args.base}:{name}'], cwd=ROOT, capture_output=True).returncode == 0
    old = git('show', f'{args.base}:{name}').decode('utf-8-sig') if exists else ''
    current = text(name)
    for literal, scripts in literals.items():
        before, after = old.count(literal), current.count(literal)
        if before != after:
            inventory['changes'].append({'file': name, 'literal': literal, 'before': before, 'after': after, 'direction': 'added' if after > before else 'removed', 'scripts': sorted(scripts)})
if args.scan_json:
    args.scan_json.write_text(json.dumps(inventory, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(f'BIDIRECTIONAL INVENTORY: {len(literals)} literals; {len(production)} files; {len(inventory["changes"])} count changes; review block anchors and negative assertions.')
print(f'Static integration checks passed: {checks}. Swift compilation, fixture execution and live protocols NOT verified.')
