#!/usr/bin/env python3
"""Source safety gates for network disk configuration; no Swift/runtime claim."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
checks = 0


def text(path):
    return (ROOT / path).read_text(encoding='utf-8-sig')


def check(value, label):
    global checks
    assert value, label
    checks += 1
    print('PASS:', label)


def block(source, marker):
    start = source.index(marker)
    masked = re.sub(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:[^"\\]|\\.)*"',
                    lambda m: ' ' * len(m.group()), source)
    opening = masked.index('{', start)
    depth = 1
    for i in range(opening + 1, len(masked)):
        depth += (masked[i] == '{') - (masked[i] == '}')
        if depth == 0:
            return source[opening + 1:i]
    raise AssertionError('Unclosed block: ' + marker)


gateway = text('Shared/RemoteServers/RemoteDiskAIToolGateway.swift')
registration = text('Agent/Chat/AIChatViewModel+ToolDefinitions.swift')
dispatch = text('Agent/Chat/AIChatViewModel+ConcurrentTools.swift')
chat = text('Views/Chat/AIChatView.swift')
vm = text('Agent/Chat/AIChatViewModel.swift')
stream = text('Agent/Chat/AIChatViewModel+SSEStream.swift')
titles = text('Agent/Chat/AIChatViewModel+TitleGeneration.swift')
project = text('Ze.xcodeproj/project.pbxproj')
credential_tool = 'remote_disk_configure_credentials'
for name in ['remote_disk_draft', credential_tool, 'remote_disk_delete']:
    check(f'name: "{name}"' in gateway and f'case "{name}"' in gateway
          and f'"{name}"' in dispatch and f'case "{name}"' in text('Agent/Session/SoulStore.swift'),
          'definition, gateway dispatch, chat dispatch and visible label: ' + name)
check('RemoteDiskAIToolGateway.definitions()' in registration
      and 'remoteDiskToolDefinitions()' in registration,
      'configuration tools share the disk list registration point')
check('RemoteDiskAIToolGateway.statusFragment' in vm and vm.count('userSystemPrompt += remoteServerStatusFragment') == 2,
      'disk metadata/guidance reach both system prompt construction paths')
check('remote_disk_list' in gateway and 'file_read' in gateway and 'read_only' in gateway,
      'guidance includes the read-only list/file route')
check('RemoteServerSecretStore.value' not in gateway and 'JSONEncoder' not in gateway,
      'gateway never reads Keychain or serializes a profile/payload')
for marker in ['private static func configureCredentials(', 'private static func deleteDisk(']:
    body = block(gateway, marker)
    check('await RemoteServerAIConfirmationGate.shared.request' in body
          and 'guard approved, !Task.isCancelled' in body
          and '(try? store.disk(id: disk.id)) == disk' in body
          and '.fullAccess' not in body, marker + ' requires confirmation and a current snapshot without access bypass')
    check('error.localizedDescription' not in body, marker + ' never echoes arbitrary credential/configuration errors')
check('try RemoteServerCredentialChange.perform(for: disk)' in gateway and 'try store.remove(disk)' in gateway,
      'credentials and deletion use existing shared entry points')
helper = text('Shared/RemoteServers/RemoteServerCredentialChange.swift')
disk_change = block(helper, 'static func perform(for disk: RemoteDisk')
check('try perform(for: id, write)' in disk_change and 'invalidateCredentialVerification(diskID:' in disk_change,
      'SFTP uses SSH invalidation; other protocols invalidate the disk revision before writing')
invalidation = block(text('Shared/RemoteServers/RemoteDiskStore.swift'), 'func invalidateCredentialVerification(')
check(invalidation.index('configurationRevision = UUID()') < invalidation.index('try persist()')
      and 'verification.removeValue' in invalidation, 'disk-only credential changes invalidate old readers and verification')
check('store.save(' not in block(gateway, 'private static func stageDraft(')
      and 'RemoteDiskAIDraftStore.shared.stage' in gateway and 'Set(args.keys).isSubset(of: allowed)' in gateway,
      'drafts accept metadata only and never persist')
check('RemoteDiskAIDraftPresentationModifier()' in chat and 'remoteDiskAIDraftStore.pending != nil' in block(chat, 'private var hasOverlayPresented:'),
      'native draft sheet participates in chat overlay gating')
check('RemoteDiskEditorView(disk: draft.disk)' in text('Views/Servers/RemoteDiskAIDraftPresentationModifier.swift'),
      'drafts reuse the native disk editor')
stage = block(gateway, 'static func stage(_ arguments:')
check('arguments["tool_title"]' not in stage and 'safe["disk_id"] = id.uuidString' in stage
      and 'return safe' in stage and 'pending.removeValue(forKey: token)' in stage,
      'one-shot credential inbox emits only a fixed title, validated ID and expiring handle')
check(f'if name == "{credential_tool}" {{ continue }}' in stream
      and 'RemoteDiskAICredentialInbox.stage(rawArgs)' in stream,
      'credential deltas skip previews/diagnostics; completed input is scrubbed before ordinary tool processing')
check(f'args.isEmpty && toolName != "{credential_tool}"' in text('Providers/Anthropic/AnthropicAgentProvider.swift')
      and f'guard toolName != "{credential_tool}"' in text('Providers/OpenAI/OpenAIAgentProvider.swift'),
      'malformed credential arguments cannot enter raw/hex provider diagnostics')
check('!tools.contains(where: { $0.name == "remote_disk_configure_credentials" })' in text('Providers/OpenAI/OpenAIAgentProvider.swift'),
      'credential-capable malformed streams cannot retain raw first-line diagnostics')
capture = text('Providers/Anthropic/OAuthHTTPClient.swift')
check('let suppressBodyCapture = body.contains("remote_disk_configure_credentials")' in capture
      and 'guard !suppressBodyCapture else { return }' in capture
      and capture.count('suppressCredentialBodies = String(decoding: mutable.httpBody') == 3,
      'credential-capable captures suppress whole request/response bodies before fragmentation/truncation')
check('latestMessages.contains' in titles and 'remoteDiskCredentialSessions.insert(sessionId)' in titles and 'tool.name == "remote_disk_configure_credentials"' in titles
      and titles.count('self?.remoteDiskCredentialSessions.contains(sessionId) != true') == 2,
      'credential-call titles are generic, including regeneration and already-running title tasks')
settings = text('Views/ContentView.swift')
icon = settings.split('RemoteDiskSettingsView()', 1)[1].split('RemoteServersView()', 1)[0]
check(all(part in icon for part in ['externaldrive.fill', '.foregroundStyle(.white)', '.frame(width: 21, height: 21)', '.background(.teal, in: Circle())']),
      'settings disk icon uses a white glyph in the matching 21pt circle')
for name in ['RemoteDiskAIToolGateway.swift', 'RemoteDiskAIDraftPresentationModifier.swift']:
    check(project.count(f'/* {name} in Sources */') == 2 and project.count(f'/* {name} */') == 3,
          'unique Xcode source membership: ' + name)
check('scripts/verify-netdisk-gateway.py' in text('.github/workflows/build.yml'), 'CI runs the new configuration source gate')
gemini_provider = text('Providers/Gemini/GeminiProvider.swift')
antigravity_provider = text('Providers/Antigravity/AntigravityProvider.swift')
for tool in ('remote_disk_configure_credentials', 'remote_server_configure_credentials'):
    check(f'"{tool}"' in gemini_provider and f'"{tool}"' in antigravity_provider,
          'credential log filters include both write-only tools: ' + tool)
gemini_stream = block(gemini_provider, 'private func logStreamChunk(')
check('let redactCredentialPayload = hasCredentialCall || rawJSONContainsCredentialTool' in gemini_stream
      and 'if !redactCredentialPayload' in gemini_stream
      and '<redacted: credential tool payload>' in gemini_stream,
      'Gemini SSE raw JSON preview is withheld when a credential tool payload or call is present')
check('if Self.credentialToolNames.contains(name)' in gemini_stream
      and r'functionCall(\(name)): <redacted>' in gemini_stream
      and gemini_stream.index('if Self.credentialToolNames.contains(name)') < gemini_stream.index('let argsStr'),
      'Gemini SSE function-call arguments are redacted before formatting')
antigravity_log = block(antigravity_provider, 'private func logFullRequest(')
check('if Self.containsCredentialToolName(in: body)' in antigravity_log
      and '<redacted: credential tool payload>' in antigravity_log
      and antigravity_log.index('if Self.containsCredentialToolName(in: body)') < antigravity_log.index('String(str.prefix(3000))'),
      'Antigravity request body is withheld when a credential tool is referenced')
print(f'Network disk gateway source checks passed: {checks}. Swift, Keychain, UI and live protocols NOT verified.')
