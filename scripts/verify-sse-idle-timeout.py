#!/usr/bin/env python3
"""Structural regression checks for the response idle timeout.

Ported from OpenMinis v1.15 (`SSEIdleTimeoutTests`) and extended to every
provider family Ze ships, because Ze's provider list is wider than upstream's.
These are source-level invariants that are cheap to verify without an iOS
build host:

* the setting exists with the upstream default, range and presets;
* the agent loop reads it per stream instead of the old hardcoded 600 s;
* a stream that is alive but yields no UI event still resets the watchdog,
  otherwise lowering the default to 120 s would abort long reasoning turns;
* the transport timeout follows the setting, so URLSession does not end the
  stream before the watchdog does — for OpenAI, Anthropic, Gemini and
  Antigravity alike;
* the row is rendered directly below the custom User-Agent section;
* the id the setting is keyed by is set by the factory for every family.
"""
from pathlib import Path

ROOT = Path(".")
checks = 0


def check(condition, name):
    global checks
    assert condition, name
    checks += 1
    print("PASS:", name)


def src(path):
    return (ROOT / path).read_text(encoding="utf-8")


agent = src("Providers/AgentProvider.swift")
sse = src("Agent/Chat/AIChatViewModel+SSEStream.swift")
oa_agent = src("Providers/OpenAI/OpenAIAgentProvider.swift")
oa = src("Providers/OpenAI/OpenAIProvider.swift")
an_agent = src("Providers/Anthropic/AnthropicAgentProvider.swift")
an = src("Providers/Anthropic/AnthropicProvider.swift")
an_http = src("Providers/Anthropic/OAuthHTTPClient.swift")
gm_agent = src("Providers/Gemini/GeminiAgentProvider.swift")
gm = src("Providers/Gemini/GeminiProvider.swift")
ag_agent = src("Providers/Antigravity/AntigravityAgentProvider.swift")
ag = src("Providers/Antigravity/AntigravityProvider.swift")
factory = src("Providers/LLMProviderFactory.swift")
detail = src("Views/Providers/ProviderInstanceDetailView.swift")

# 1. Setting shape, identical to upstream v1.15.
check("enum ResponseIdleTimeoutSetting" in agent, "setting type exists")
check("static let defaultSeconds = 120" in agent, "default is 120 s")
check("static let minSeconds = 5" in agent, "minimum is 5 s, so a stall test is quick")
check("static let maxSeconds = 3600" in agent, "maximum is 3600 s")
check("static let presets = [120, 300, 600, 1800, 3600]" in agent, "presets match upstream")
check("provider.responseIdleTimeout." in agent, "key is scoped per instance")
check("defaults.removeObject(forKey: key(forInstanceId: id))" in agent,
      "storing the default clears the key so 'never set' stays distinguishable")

# 2. The agent loop reads the setting instead of the old constant.
check("let stallTimeoutSeconds: TimeInterval = provider.responseIdleTimeout" in sse,
      "stall watchdog reads the per-instance value")
check("let stallTimeoutSeconds: TimeInterval = 600" not in sse,
      "the hardcoded 600 s is gone")

# 3. Liveness signal: a silent-but-alive stream still resets the watchdog.
check("case streamActivity" in agent, "streamActivity event exists")
check("case .streamActivity:" in sse, "agent loop handles streamActivity")
check(oa_agent.count("continuation.yield(.streamActivity)") == 2,
      "OpenAI reports activity on both hidden-reasoning paths")
check("static func deltaCarriesReasoning" in oa_agent, "reasoning detector ported")
check("if !thinkingLevel.isEnabled,\n                           Self.deltaCarriesReasoning(delta" in oa_agent,
      "activity is reported only while thinking is off")
check('"reasoning.text"' in oa_agent and '"reasoning.summary"' in oa_agent
      and '"reasoning.encrypted"' in oa_agent, "reasoning_details shapes recognised")

# 4. Transport must outlive the watchdog.
check("ResponseIdleTimeoutSetting.transportTimeout(forInstanceId:" in oa,
      "OpenAI extends the request timeout")
check("TimeInterval(clamp(seconds(forInstanceId: id))) + 30" in agent,
      "transport follows the setting downward too, so TTFB is bounded by it")
check("idle > sessionDefault" not in agent,
      "transport is no longer extension-only (that left 120 s settings on a 600 s socket)")
check("ResponseIdleTimeoutSetting.transportTimeout(forInstanceId: providerInstanceId)" in gm,
      "Gemini extends the request timeout")
check("ResponseIdleTimeoutSetting.transportTimeout(forInstanceId: providerInstanceId)" in ag,
      "Antigravity extends the request timeout")
check("requestTimeout: Self.transportTimeout(for: instanceId)" in an,
      "Anthropic passes the budget into its HTTP client")
check(an_http.count("config.timeoutIntervalForRequest = requestTimeout") == 3,
      "all three Anthropic clients honour the budget")
check("config.timeoutIntervalForRequest = 600" not in an_http,
      "no Anthropic client is left on the fixed 600 s")

# 5. Every provider family exposes the instance id the setting is keyed by.
check("var providerInstanceId: String? { get }" in agent, "protocol requires the id")
check("var providerInstanceId: String? { nil }" in agent, "default is nil")
check("TimeInterval(ResponseIdleTimeoutSetting.seconds(forInstanceId: providerInstanceId))" in agent,
      "shared default reads the setting")
for name, text in [("OpenAI", oa_agent), ("Anthropic", an_agent),
                   ("Gemini", gm_agent), ("Antigravity", ag_agent)]:
    check("var providerInstanceId: String? { provider.providerInstanceId }" in text,
          f"{name} agent provider exposes the id")
for name, text in [("OpenAI", oa), ("Anthropic", an), ("Gemini", gm), ("Antigravity", ag)]:
    check("var providerInstanceId: String?" in text, f"{name} provider stores the id")
check("provider.providerInstanceId = instance.id" in factory,
      "factory sets the id for OpenAI-compatible instances")
check("provider.providerInstanceId = iid" in factory,
      "factory sets the id for Antigravity and Codex sign-in")

# 6. UI placement: directly below the custom User-Agent section.
ua_at = detail.index("customUserAgentSection(instance)")
row_at = detail.index("responseIdleTimeoutSection(instance)")
check(0 < ua_at < row_at, "row sits below the custom User-Agent section")
check(detail.index("apiFormatSection" if "apiFormatSection" in detail else "MARK: API Format") > row_at,
      "row sits above the API format section")
check("private func responseIdleTimeoutSection(_ instance: ProviderInstance)" in detail,
      "row is implemented")
check("guard responseIdleLoadedFor != instance.id else { return }" in detail,
      "row state loads once per instance, so a Form rebuild cannot reset an edit")
check("ResponseIdleTimeoutSetting.set(picked, forInstanceId: instance.id)" in detail,
      "preset selection is persisted")
check("typed >= ResponseIdleTimeoutSetting.minSeconds" in detail
      and "typed <= ResponseIdleTimeoutSetting.maxSeconds" in detail,
      "custom value is clamped before storing")
check("if instance.supportsCustomUserAgent {" in detail and
      "responseIdleTimeoutSection(instance)\n" in detail,
      "row is not gated to a single provider type")

# 8. A stall must be surfaced without waiting for one more event.
#    `group.cancelAll()` after `group.next()` never ran on the throwing path,
#    and a throwing task group awaits its children before leaving the scope, so
#    the still-suspended iterator kept the timeout trapped until the stream
#    produced something else. Every value of the setting was unenforceable
#    against a server that went silent, which is the only case it exists for.
check("defer { group.cancelAll() }" in sse,
      "the watchdog cancels the iterator on the throwing path, not after it")
check(sse.index("defer { group.cancelAll() }") < sse.index("return try await group.next()!"),
      "cancellation is armed before awaiting the race")
check("let result = try await group.next()!\n                group.cancelAll()" not in sse,
      "the unreachable cancelAll() on the throw path is gone")

# 9. An out-of-range entry must not be dropped without a word.
check("static let minSeconds = 5" in agent,
      "the floor allows a quick stall test instead of half a minute")
check("responseIdleError = String(localized: \"Enter a number of seconds.\")" in detail,
      "a non-numeric entry reports itself")
check("responseIdleError = String(\n                format: String(localized: \"Use %d–%d seconds.\")" in detail,
      "an out-of-range entry reports the range instead of being dropped")
check("private func commitCustomResponseIdle" in detail
      and "responseIdleCustomText = String(value)" in detail,
      "leaving the field clamps and writes the effective value back")
check(".onDisappear { commitCustomResponseIdle(instance) }" in detail,
      "leaving the screen commits the edit")
check("Seconds (30–3600)" not in detail,
      "the range label is derived from the setting, not hardcoded")

print(f"\nSSE idle timeout structure checks passed: {checks}")
