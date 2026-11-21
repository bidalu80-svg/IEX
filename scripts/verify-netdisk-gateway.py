#!/usr/bin/env python3
"""Source safety gates and a SQLite marker check; no Swift/iOS runtime claim."""
from contextlib import closing
from pathlib import Path
import re
import sqlite3
from tempfile import TemporaryDirectory

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
summary = block(gateway, 'func summary(of arguments:')
take = block(gateway, 'static func take(_ arguments:')
check('let token = UUID().uuidString' in stage and 'var safe = kind.summary(of: arguments)' in stage
      and 'safe["_credential_request"] = token' in stage and '600_000_000_000' in stage
      and 'pending.removeValue(forKey: token)' in stage and 'pending.removeValue(forKey: token)' in take
      and 'payload.kind == kind' in take and 'kind.targetID(in: arguments) == payload.targetID' in take,
      'credential inbox uses a one-shot expiring handle bound to the original tool and target')
check('self == .disk ? "disk_id" : "server_id"' in gateway
      and re.search(r'var summary: \[String: Any\] = \["tool_title": toolTitle\]\s*'
                    r'if let id = targetID\(in: arguments\) \{ summary\[targetKey\] = id.uuidString \}\s*return summary', summary),
      'credential history summary permits only a fixed title and validated UUID')
check('if CredentialToolDiagnostics.isCredentialTool(name) { continue }' in stream
      and stream.index('if CredentialToolDiagnostics.isCredentialTool(name) { continue }') < stream.index('ring.append(accumulated)'),
      'credential deltas skip previews and diagnostics')
complete = stream.split('case .toolCallComplete(let rawId, let name, let rawArgs, let metadata):', 1)[1]
check(re.search(r'let args: \[String: Any\]\s*if let kind = RemoteAICredentialKind\(rawValue: name\)\s*\{\s*'
                r'await self\.useCredentialSessionTitle\(kind\)\s*args = await MainActor\.run \{\s*'
                r'RemoteAICredentialInbox\.stage\(rawArgs, kind: kind\)\s*\}\s*\} else \{\s*args = rawArgs\s*\}', complete)
      and complete.count('rawArgs') == 2 and 'name: name, args: args, blockIdx: blockIdx' in complete,
      'both SSH and disk tool inputs are staged before the completed event enters the tool pipeline')
server_credentials = block(text('Shared/RemoteServers/RemoteServerAIToolGateway.swift'), 'private static func configureCredentials(')
check('RemoteAICredentialInbox.take(arguments, kind: .server)' in server_credentials
      and all(f'payload.{field}' in server_credentials for field in ('password', 'privateKey', 'passphrase'))
      and not any(f'arguments["{field}"]' in server_credentials for field in ('password', 'private_key', 'passphrase'))
      and 'RemoteAICredentialInbox.take(args, kind: .disk)' in block(gateway, 'private static func configureCredentials('),
      'credential gateways read from the inbox with no raw-argument fallback')
persistence = block(text('Agent/Chat/AIChatViewModel+Persistence.swift'), 'func buildRawMessage(')
check('Self(rawValue: name)?.summary(of: arguments) ?? arguments' in block(gateway, 'static func historyInput(')
      and 'let historyInput = RemoteAICredentialKind.historyInput(name: name, arguments: args)' in complete
      and 'JSONSerialization.data(withJSONObject: historyInput)' in complete
      and re.search(r'let input = RemoteAICredentialKind\.historyInput\(name: tu.name, arguments: tu.args\)\s*'
                    r'assistantParts\.append\(\.toolUse\(id: tu.id, name: tu.name, input: input\)\)', vm)
      and 'let historyInput = RemoteAICredentialKind.historyInput(name: name, arguments: input)' in persistence
      and 'JSONSerialization.data(withJSONObject: historyInput)' in persistence
      and 'description: historyInput["tool_title"] as? String' in persistence,
      'credential handles and raw arguments stay out of introspection, agent history and database serialization')
provider = text('Providers/AgentProvider.swift')
credential_diagnostics = block(provider, 'enum CredentialToolDiagnostics')
check(set(re.findall(r'"(remote_\w+_configure_credentials)"', block(provider, 'enum RemoteAICredentialKind')))
      == {credential_tool, 'remote_server_configure_credentials'}
      and 'RemoteAICredentialKind(rawValue: name) != nil' in credential_diagnostics
      and 'RemoteAICredentialKind.allCases.contains { text.contains($0.rawValue) }' in credential_diagnostics,
      'credential log policy covers both SSH and disk by exact tool name, including serialized payloads')
anthropic_agent = text('Providers/Anthropic/AnthropicAgentProvider.swift')
anthropic_probe = 'if args.isEmpty && !CredentialToolDiagnostics.isCredentialTool(toolName)'
check(anthropic_probe in anthropic_agent and 'hex80=' in block(anthropic_agent, anthropic_probe)
      and r'raw=<<<\(finalJson)>>>' in block(anthropic_agent, anthropic_probe)
      and anthropic_agent.count('AppLogger(category: "ToolArgsProbe")') == 1,
      'Anthropic excludes SSH and disk before logging raw/hex malformed arguments')
openai_agent = text('Providers/OpenAI/OpenAIAgentProvider.swift')
openai_probe = block(openai_agent, 'fileprivate static func diagEmptyToolArgs(')
check(re.match(r'\s*guard !CredentialToolDiagnostics\.isCredentialTool\(toolName\) else \{ return \}', openai_probe)
      and 'hex80=' in openai_probe and r'raw=<<<\(rawJson)>>>' in openai_probe
      and openai_agent.count('AppLogger(category: "ToolArgsProbe")') == 1,
      'OpenAI excludes SSH and disk before logging raw/hex malformed arguments')
check('!tools.contains(where: { CredentialToolDiagnostics.isCredentialTool($0.name) })' in openai_agent,
      'credential-capable malformed streams cannot retain raw first-line diagnostics')
capture = text('Providers/Anthropic/OAuthHTTPClient.swift')
check('let suppressBodyCapture = suppressCredentialBodies || CredentialToolDiagnostics.containsToolName(in: body)' in capture
      and 'guard !suppressBodyCapture else { return }' in capture
      and capture.count('suppressCredentialBodies = CredentialToolDiagnostics.containsToolName(in: String(decoding: mutable.httpBody') == 3
      and 'set(formatted, suppressCredentialBodies: suppressCredentialBodies)' in capture,
      'credential-capable captures suppress whole request/response bodies before fragmentation/truncation')
anthropic_provider = text('Providers/Anthropic/AnthropicProvider.swift')
check('CredentialToolDiagnostics.containsToolName(in:' in block(anthropic_provider, 'func logRequestParameter(')
      and 'CredentialToolDiagnostics.isCredentialTool(toolUse.name) ? "<redacted>"' in block(anthropic_provider, 'func logResponse(')
      and 'if CredentialToolDiagnostics.isCredentialTool(entry.name) { return entry.name }' in titles,
      'request previews, tool response diagnostics and title summaries omit credential input')
title_generation = block(titles, 'func generateSessionTitleIfNeeded(')
fixed_title = block(titles, 'func useCredentialSessionTitle(')
fallback = block(titles, 'private func applyFallbackTitle(')
manual_title = block(titles, 'static func regenerateSessionTitle(')
chat_store = text('Agent/Chat/ChatStore.swift')
record_title = block(chat_store, 'func recordCredentialSessionTitle(')
pending_title = block(chat_store, 'func pendingCredentialSessionTitle(')
release_title = block(chat_store, 'func releaseCredentialSessionTitles(')
restore_title = block(chat_store, 'func restoreCredentialSessionTitle(')
generated_title = block(chat_store, 'func updateGeneratedSessionTitle(')
pending_lookup = 'await ChatStore.shared.pendingCredentialSessionTitle(for: sessionId)'
fallback_call = 'guard let fallback = Self.fallbackTitle(fromFirstUserMessage: firstUserRaw) else {'
check(fallback_call in fallback, 'instance fallback explicitly calls the static Self.fallbackTitle')
tool_start = stream.split('case .toolUse(let rawTuId, let name):', 1)[1]
check('self == .disk ? "网络磁盘配置" : "SSH 服务器配置"' in gateway
      and tool_start.strip().startswith('if let kind = RemoteAICredentialKind(rawValue: name) { await self.useCredentialSessionTitle(kind) }')
      and re.search(r'if let kind = toolEntries\.lazy\.compactMap\(\{ RemoteAICredentialKind\(rawValue: \$0.name\) \}\)\.first\s*\{\s*'
                    r'await useCredentialSessionTitle\(kind\)\s*return\s*\}', title_generation)
      and 'await ChatStore.shared.recordCredentialSessionTitle(kind, sessionId: sessionId, ownerID: ownerID)' in fixed_title
      and 'sqlite3_bind_text(stmt, 3, kind.rawValue' in record_title
      and 'updateSessionTitle(sessionId, title: title, category: nil)' in record_title,
      'SSH and disk recognition awaits SQL registration of the tool name before execution or normal naming')
check(pending_lookup in title_generation.partition('let userMessages')[0]
      and title_generation.count(pending_lookup) == 5
      and pending_lookup in fallback.partition(fallback_call)[0]
      and 'await ChatStore.shared.updateGeneratedSessionTitle(sessionId, title: trimmed, category: category)' in title_generation
      and 'await ChatStore.shared.updateGeneratedSessionTitle(sessionId, title: fallback, category: nil)' in fallback,
      'automatic naming and fallback consult the stored marker and use the guarded write')
check(manual_title.strip().startswith('if await restoreCredentialSessionTitle(for: sessionId) { return }')
      and 'if await restoreCredentialSessionTitle(for: sessionId, messages: rawMessages) { return }' in manual_title.partition('let userMessages')[0]
      and 'await ChatStore.shared.restoreCredentialSessionTitle(sessionId, messages: messages)' in block(titles, 'private static func restoreCredentialSessionTitle(')
      and 'pendingCredentialSessionTitle(for: id) ?? Self.credentialSessionTitle(in: messages)' in restore_title
      and 'updateSessionTitle(id, title: title, category: nil)' in restore_title,
      'manual regeneration consults the stored marker before loading or summarizing history')
check(manual_title.strip().endswith(
          'await ChatStore.shared.updateGeneratedSessionTitle(sessionId, title: trimmed, category: category, checkingHistory: true)')
      and 'SELECT tool_name FROM credential_title_owners WHERE session_id = ?' in pending_title
      and 'RemoteAICredentialKind(rawValue: String(cString: name))?.sessionTitle' in pending_title
      and re.search(r'if let fixedTitle = pendingCredentialSessionTitle\(for: id\)\s*'
                    r'\?\? \(checkingHistory \? Self\.credentialSessionTitle\(in: loadMessages\(sessionId: id\)\) : nil\)\s*\{\s*'
                    r'if checkingHistory \{ updateSessionTitle\(id, title: fixedTitle, category: nil\) \}\s*return false', generated_title)
      and 'updateSessionTitle(id, title: title, category: category)' in generated_title.partition('guard !title.isEmpty')[2]
      and 'await ' not in generated_title and 'ViewModelCache' not in titles
      and 'RemoteAICredentialKind(rawValue: tool.name)?.sessionTitle' in block(chat_store, 'static func credentialSessionTitle(in'),
      'final title write checks the durable SQL marker and history in the same actor turn, not the VM cache')
check('let ownerID = credentialTitleOwnerID ?? UUID().uuidString' in fixed_title
      and 'await ChatStore.shared.releaseCredentialSessionTitles(ownedBy: ownerID)' in block(vm, 'deinit {')
      and 'setupCredentialTitleOwners(clearExisting: clearCredentialTitleOwners)' in chat_store
      and 'if clearExisting { exec("DELETE FROM credential_title_owners") }' in chat_store
      and 'func createTables(clearCredentialTitleOwners: Bool = true)' in chat_store,
      'pending markers follow VM ownership rather than cache residency and do not outlive a launch')
backup_manager = text('Agent/Sync/ICloudBackupManager.swift')
restore_files = block(backup_manager, 'private func restoreSessionFiles(')
db_restore = block(restore_files, 'if fm.fileExists(atPath: dbSrc.path)')
reload_db = block(chat_store, 'func reloadDatabase(')
success_reload = 'await ChatStore.shared.reloadDatabase(replacingDatabase: true)'
check('func reloadDatabase(replacingDatabase: Bool = false)' in chat_store
      and 'db == nil' not in reload_db
      and 'createTables(clearCredentialTitleOwners: replacingDatabase)' in reload_db
      and re.search(r'do\s*\{\s*try replaceRestoredItem\(at: zeDBURL, with: dbSrc\)\s*\}\s*'
                    r'catch\s*\{\s*await ChatStore\.shared\.reloadDatabase\(\)\s*throw error\s*\}\s*'
                    + re.escape(success_reload) + r'\s*$', db_restore)
      and backup_manager.count('ChatStore.shared.reloadDatabase(replacingDatabase:') == 1,
      'restore clears credential title markers only after database replacement succeeds; failure reopens without clearing')

schema = re.search(r'CREATE TABLE IF NOT EXISTS credential_title_owners \([\s\S]*?\n\s*\)', chat_store).group()
statements = [re.search(r'let sql = "([^"]+)"', body).group(1) for body in (record_title, pending_title, release_title)]
insert_marker, select_marker, delete_marker = statements
with sqlite3.connect(':memory:') as connection:
    connection.execute('PRAGMA foreign_keys = ON')
    connection.execute('CREATE TABLE sessions (id TEXT PRIMARY KEY)')
    connection.execute(schema)
    connection.executemany('INSERT INTO sessions VALUES (?)', [('scheduled',), ('ordinary',)])
    server_tool = 'remote_server_configure_credentials'
    connection.execute(insert_marker, ('scheduled', 'detached-vm', server_tool))
    connection.execute(insert_marker, ('scheduled', 'detached-vm', credential_tool))
    connection.execute(insert_marker, ('scheduled', 'second-vm', credential_tool))
    check(connection.execute(select_marker, ('scheduled',)).fetchone() == (server_tool,)
          and connection.execute(select_marker, ('ordinary',)).fetchone() is None,
          'SQLite lookup uses the first owner registration without a cached VM or a tool-message row')
    connection.execute(delete_marker, ('detached-vm',))
    check(connection.execute(select_marker, ('scheduled',)).fetchone() == (credential_tool,),
          'SQLite owner release leaves another VM registration intact')
    connection.execute(delete_marker, ('second-vm',))
    check(connection.execute(select_marker, ('scheduled',)).fetchone() is None,
          'SQLite last-owner release allows normal regeneration when no credential message exists')
    connection.execute(insert_marker, ('scheduled', 'final-vm', server_tool))
    connection.execute('DELETE FROM sessions WHERE id = ?', ('scheduled',))
    check(connection.execute(select_marker, ('scheduled',)).fetchone() is None,
          'SQLite deleting a session cascades to its credential markers')
clear_markers = re.search(r'if clearExisting \{ exec\("([^"]+)"\) \}', chat_store).group(1)
with TemporaryDirectory() as directory:
    database_path = Path(directory) / 'ze.db'
    replacement_path = Path(directory) / 'replacement.db'
    for path, tool_name in ((database_path, server_tool), (replacement_path, credential_tool)):
        with closing(sqlite3.connect(path)) as connection, connection:
            connection.execute('CREATE TABLE sessions (id TEXT PRIMARY KEY)')
            connection.execute(schema)
            connection.execute('INSERT INTO sessions VALUES (?)', ('scheduled',))
            connection.execute(insert_marker, ('scheduled', 'owner', tool_name))
    with closing(sqlite3.connect(database_path)) as connection:
        connection.execute(schema)
        check(connection.execute(select_marker, ('scheduled',)).fetchone() == (server_tool,),
              'SQLite reopening the original database preserves its live marker')
    replacement_path.replace(database_path)
    with closing(sqlite3.connect(database_path)) as connection, connection:
        connection.execute(schema)
        copied_marker = connection.execute(select_marker, ('scheduled',)).fetchone()
        connection.execute(clear_markers)
        check(copied_marker == (credential_tool,)
              and connection.execute(select_marker, ('scheduled',)).fetchone() is None
              and connection.execute('SELECT id FROM sessions').fetchone() == ('scheduled',),
              'SQLite reopening a replaced database clears copied markers without deleting sessions')
settings = text('Views/ContentView.swift')
icon = settings.split('RemoteDiskSettingsView()', 1)[1].split('RemoteServersView()', 1)[0]
check(all(part in icon for part in ['externaldrive.fill', '.foregroundStyle(.white)', '.frame(width: 21, height: 21)', '.background(.teal, in: Circle())']),
      'settings disk icon uses a white glyph in the matching 21pt circle')
for name in ['RemoteDiskAIToolGateway.swift', 'RemoteDiskAIDraftPresentationModifier.swift']:
    check(project.count(f'/* {name} in Sources */') == 2 and project.count(f'/* {name} */') == 3,
          'unique Xcode source membership: ' + name)
check('scripts/verify-netdisk-gateway.py' in text('.github/workflows/build.yml'), 'CI runs the new configuration source gate')
gemini_provider = text('Providers/Gemini/GeminiProvider.swift')
openai_request_log = block(text('Providers/OpenAI/OpenAIProvider.swift'), 'private func logOutgoingRequest(')
gemini_request_log = block(gemini_provider, 'private func logFullRequest(')
openai_log_filter, openai_preview, _ = openai_request_log.partition('let bodyJSON')
check(openai_preview and 'containsToolName' not in openai_request_log
      and 'String(str.prefix(3000))' in openai_request_log
      and 'logger.' not in openai_log_filter
      and openai_log_filter.strip().endswith('guard !hasChatCredentialCall, !hasResponsesCredentialCall else { return }'),
      'OpenAI standalone request log uses only call checks before emitting any preview')
check('let messages = body["messages"] as? [[String: Any]] ?? []' in openai_log_filter
      and 'let hasChatCredentialCall = messages.contains' in openai_log_filter
      and 'let calls = message["tool_calls"] as? [[String: Any]] ?? []' in openai_log_filter
      and 'return calls.contains' in openai_log_filter
      and 'guard let function = call["function"] as? [String: Any], let name = function["name"] as? String' in openai_log_filter
      and 'return CredentialToolDiagnostics.isCredentialTool(name)' in block(openai_log_filter, 'return calls.contains'),
      'OpenAI Chat Completions matches exact tool_calls function names, not user text or arguments')
check('let input = body["input"] as? [[String: Any]] ?? []' in openai_log_filter
      and 'guard item["type"] as? String == "function_call", let name = item["name"] as? String' in openai_log_filter
      and 'return CredentialToolDiagnostics.isCredentialTool(name)' in block(openai_log_filter, 'let hasResponsesCredentialCall = input.contains'),
      'OpenAI Responses matches exact names only on function_call input items')
gemini_log_filter, gemini_preview, _ = gemini_request_log.partition('var parts: [String]')
check(gemini_preview and 'containsToolName' not in gemini_request_log
      and 'String(str.prefix(3000))' in gemini_request_log
      and 'logger.' not in gemini_log_filter and 'LastAPIRequestBody.shared.set' not in gemini_log_filter
      and gemini_log_filter.strip().endswith('guard !hasCredentialCall else { return }'),
      'Gemini standalone request log uses only the call check before logging or caching any preview')
check('let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) }' in gemini_log_filter
      and 'let root = json as? [String: Any]' in gemini_log_filter
      and 'let payload = (root?["request"] as? [String: Any]) ?? root' in gemini_log_filter
      and 'let contents = payload?["contents"] as? [[String: Any]] ?? []' in gemini_log_filter
      and 'let hasCredentialCall = contents.contains' in gemini_log_filter
      and 'let parts = content["parts"] as? [[String: Any]] ?? []' in gemini_log_filter
      and 'guard let call = part["functionCall"] as? [String: Any], let name = call["name"] as? String' in gemini_log_filter
      and 'return CredentialToolDiagnostics.isCredentialTool(name)' in block(gemini_log_filter, 'return parts.contains'),
      'Gemini direct and Cloud Code payloads match exact contents.parts.functionCall names, not text')
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
check('Self.containsCredentialToolName(in: data) ? "<redacted: credential tool payload>"'
      in block(antigravity_provider, 'private func logResponse('),
      'Antigravity complete response diagnostics also withhold credential tool payloads')
print(f'Network disk gateway source and SQLite checks passed: {checks}. Swift, Keychain, UI and live protocols NOT verified.')
