#!/usr/bin/env python3
"""Static gate for all SSH credential writers; not a Swift/runtime test."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
checks = 0

def text(path):
    return (ROOT/path).read_text(encoding='utf-8-sig')

def check(condition, message):
    global checks
    if not condition:
        raise AssertionError(message)
    checks += 1
    print('PASS:', message)

def masked(source):
    # Keep offsets while ignoring braces inside strings and comments.
    pattern = r'//[^\n]*|/\*[\s\S]*?\*/|"(?:[^"\\]|\\.)*"'
    return re.sub(pattern, lambda m: ' ' * len(m.group()), source)

def body(source, marker):
    start = source.index(marker)
    code = masked(source)
    opening = code.index('{', start)
    depth = 1
    for i in range(opening + 1, len(code)):
        depth += (code[i] == '{') - (code[i] == '}')
        if depth == 0:
            return source[opening+1:i], opening, i
    raise AssertionError('Unclosed block: ' + marker)

# Discover all literal SSH secret saves project-wide; each must be inside a
# transaction. This catches a future fifth entry even outside the current files.
transactions = {}
write_count = 0
for path in sorted(ROOT.rglob('*.swift')):
    if any(part in {'.git', 'Vendor', 'scripts'} for part in path.relative_to(ROOT).parts):
        continue
    src = path.read_text(encoding='utf-8-sig')
    spans = []
    marker = 'try RemoteServerCredentialChange.perform('
    for match in re.finditer(re.escape(marker), src):
        _, a, b = body(src[match.start():], marker)
        spans.append((match.start()+a, match.start()+b))
    writes = list(re.finditer(r'RemoteServerSecretStore\.save\([^\n]*kind:\s*\.(password|privateKey|privateKeyPassphrase)\b', src))
    if writes:
        for match in writes:
            check(any(a < match.start() < b for a, b in spans), f'SSH {match[1]} writer is invalidated: {path.relative_to(ROOT)}:{src.count(chr(10), 0, match.start())+1}')
        write_count += len(writes)
        transactions[str(path.relative_to(ROOT))] = len(spans)
check(transactions == {
    'Shared/RemoteServers/RemoteDiskAIToolGateway.swift': 1,
    'Shared/RemoteServers/RemoteServerAIToolGateway.swift': 2,
    'Views/Servers/RemoteServersView.swift': 2,
    'Views/Backup/ICloudBackupView.swift': 1,
}, 'five UI/tool entry points use six transactions (server AI password/key branches)')
check(write_count == 11, 'all eleven password/key/passphrase save statements are covered')
helper = text('Shared/RemoteServers/RemoteServerCredentialChange.swift')
ordered = ['invalidateCredentialConnection(serverID:', 'clear(for:', 'markCredentialsChanged(', 'clearSSHVerification(', 'try write()']
ssh_change, _, _ = body(helper, 'static func perform(for serverID: UUID')
positions = [ssh_change.index(part) for part in ordered]
check(positions == sorted(positions) and 'async' not in helper and '@MainActor' in helper, 'synchronous invalidation precedes writes, including partial write failure')
store = text('Shared/RemoteServers/RemoteServerStore.swift')
change, _, _ = body(store, 'func markCredentialsChanged(')
check('updatedAt = max(.now, servers[index].updatedAt.addingTimeInterval(1))' in change and 'lastConnectedAt = nil' in change and 'try persist()' in change, 'credential version advances across whole-second persistence and clears reconnect marker')
normalized, _, _ = body(store, 'private func normalized(')
trust, _, _ = body(store, 'func setKnownHost(')
check('existing.updatedAt.addingTimeInterval(1)' in normalized and 'servers[index].updatedAt.addingTimeInterval(1)' in trust, 'editor save and host trust cannot roll back or reuse a credential revision')
ssh = text('Shared/RemoteServers/RemoteSSHConnectionService.swift')
detach, _, _ = body(ssh, 'func invalidateCredentialConnection(')
check('clients.removeValue' in detach and 'connectedProfiles.removeValue' in detach and 'client.close()' in detach and detach.index('clients.removeValue') < detach.index('Task {'), 'old connection becomes unreachable before asynchronous close')
connect, _, _ = body(ssh, 'func connect(to server:')
check(connect.count('server(id: server.id)?.updatedAt == server.updatedAt') == 2 and connect.rindex('server(id: server.id)?.updatedAt == server.updatedAt') < connect.index('clients[server.id] = client'), 'old in-flight handshake cannot publish after invalidation or prior-client close')
disks = text('Shared/RemoteServers/RemoteDiskStore.swift')
clear, _, _ = body(disks, 'func clearSSHVerification(')
check('guard loadError == nil' in clear and clear.index('guard loadError == nil') < clear.index('try persist()'), 'credential changes cannot overwrite unreadable disk configuration')
check('disk.profile.proto == .sftp && disk.sshServerID == serverID' in clear and 'verification.removeValue(forKey: disk.id)' in clear and 'try persist()' in clear, 'all associated SFTP verification records are cleared and persisted')
check('result.sshUpdatedAt == sshRevision(for: disk)' in disks and 'result.sshUpdatedAt == server.updatedAt' in disks, 'late verification results and old persisted successes remain version gated')
views = text('Views/Servers/RemoteServersView.swift')
check('if let updated = store.server(id: server.id) { beginConnection(for: updated) }' in views, 'password prompt reconnects using updated metadata')
project = text('Ze.xcodeproj/project.pbxproj')
check(project.count('D8D170000000000000000001 /* RemoteServerCredentialChange.swift in Sources */') == 2 and project.count('D8D180000000000000000001 /* RemoteServerCredentialChange.swift */') == 3, 'credential helper has unique project/group/source references')
report = text('netdisk-implementation-report.md')
check('编辑期间旧数据/旧验证拒绝' not in report and '密码/配置版本修复经独立复核' not in report and '尚未运行验证' in report, 'SFTP report wording is scoped to source checks and pending runtime validation')
print(f'SSH credential static checks passed: {checks}. No Swift compilation, Keychain, SSH handshake or iOS runtime verification.')
