#!/usr/bin/env swift
// [P3-takeover] Static pins for the pool-level control state machine.
//
// Everything here is a source-level contract: the real behaviour (in-flight
// cancel, WebKit page left intact, model event) needs a device/WebKit run, but
// these checks stop the architectural red lines from silently regressing.
//
// Run: swift BrowserTakeoverTests.swift
import Foundation

var failures = 0
func check(_ label: String, _ ok: Bool) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { failures += 1 }
}

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func source(_ rel: String) -> String {
    (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
}
func block(_ src: String, _ marker: String) -> String {
    guard let start = src.range(of: marker) else { return "/* MISSING: \(marker) */" }
    var depth = 0
    var i = start.lowerBound
    var seenOpen = false
    while i < src.endIndex {
        let c = src[i]
        if c == "{" { depth += 1; seenOpen = true }
        if c == "}" {
            depth -= 1
            if seenOpen && depth == 0 { return String(src[start.lowerBound...i]) }
        }
        i = src.index(after: i)
    }
    return "/* UNTERMINATED: \(marker) */"
}

let actions = source("Agent/BrowserUse/BrowserUseActions.swift")
let pool = source("Agent/BrowserUse/BrowserTabPool.swift")
let sheet = source("Agent/BrowserUse/BrowserSheetView.swift")
let vm = source("Agent/Chat/AIChatViewModel.swift")
let concurrent = source("Agent/Chat/AIChatViewModel+ConcurrentTools.swift")

print("\n1. Pool-level single source of truth")
check("BrowserControlState has agent / user / idle",
      actions.contains("enum BrowserControlState: String") &&
      actions.contains("case agent") && actions.contains("case user") && actions.contains("case idle"))
check("pool publishes exactly one controlState",
      pool.contains("@Published private(set) var controlState: BrowserControlState"))
check("pool exposes userTakeover and handControlBack",
      pool.contains("func userTakeover()") && pool.contains("func handControlBack()"))
check("takeover clears every tab's inUse/grace claim",
      block(pool, "    func userTakeover() -> BrowserActionResult {").contains("tabs[i].inUse = false")
      && block(pool, "    func userTakeover() -> BrowserActionResult {").contains("graceExpiryTask?.cancel()"))

print("\n2. In-flight cancellation is a takeover path, not a tab rebuild")
let abortBlock = block(pool, "    func userTakeover() -> BrowserActionResult {")
check("takeover fires the per-tab takeover abort channel",
      abortBlock.contains("inFlightTakeoverAborts[tab.id]") && abortBlock.contains("stopLoading()"))
check("takeover abort uses ActionDeadTimeout(isTakeover:)",
      pool.contains("ActionDeadTimeout(abortedByCaller: true, isTakeover: true)"))
check("the dead-tab catch returns user_takeover without rebuilding on takeover",
      block(pool, "            if dead.isTakeover {").contains("BrowserActionResult.userTakeover")
      && !block(pool, "            if dead.isTakeover {").contains("rebuildDeadTab("))

print("\n3. Write/read gate and result field")
let inner = block(pool, "    private func executeInner(")
check("write gate runs before tab management",
      inner.contains("if controlState == .user, !Self.readOnlyActions.contains(input.action)") &&
      inner.contains("return takeoverRefusal()"))
check("read-only set includes get_page_info and list_tabs",
      block(pool, "    private static let readOnlyActions: Set<BrowserAction> = [").contains(".getPageInfo")
      && block(pool, "    private static let readOnlyActions: Set<BrowserAction> = [").contains(".listTabs"))
check("gate is re-checked after the per-tab serial slot",
      inner.components(separatedBy: "if controlState == .user").count - 1 >= 2)
check("BrowserActionResult carries control",
      actions.contains("var control: BrowserControlState") &&
      actions.contains("errorCode: String?"))
check("user_takeover is structured and names the current page",
      block(actions, "    static func userTakeover(").contains("errorCode: \"user_takeover\"")
      && block(actions, "    static func userTakeover(").contains("Current page:"))
check("every tool result appends control",
      concurrent.contains("control: \\(browserResult.control.rawValue)"))

print("\n4. Session event + prompt status (never a fake user message)")
check("control transition uses the session system-info channel",
      vm.contains("browserTabPool.onControlStateChange") &&
      block(vm, "        browserTabPool.onControlStateChange = { [weak self] event in").contains("appendSystemInfo"))
check("the control handler does not append an AgentMessage user turn",
      !block(vm, "        browserTabPool.onControlStateChange = { [weak self] event in").contains("AgentMessage(role: .user"))
check("prompt fragment warns about user_takeover",
      pool.contains("var controlPromptFragment") && pool.contains("user_takeover"))
check("hand-back event carries URL and title",
      block(pool, "    func handControlBack() -> BrowserActionResult {").contains("BrowserControlEvent(kind: .handBack")
      && block(pool, "    func handControlBack() -> BrowserActionResult {").contains("snap.url")
      && block(pool, "    func handControlBack() -> BrowserActionResult {").contains("snap.title"))

print("\n5. UI: glow + Ze card + takeover button, gated only by control state")
check("agent overlay is driven by pool.controlState",
      sheet.contains("if pool.controlState == .agent") && sheet.contains("AgentBrowsingOverlay"))
check("card text is the fixed product name Ze",
      sheet.contains("Text(\"Ze 正在浏览\")"))
check("takeover capsule exists",
      sheet.contains("Label(\"接管\", systemImage: \"hand.raised.fill\")"))
check("glow is a static AngularGradient with a slow breath",
      sheet.contains("AgentGlowBorder") && sheet.contains("AngularGradient")
      && sheet.contains("duration: 3.2"))
check("breath is value-driven so parent re-renders do not reset it",
      sheet.contains(".animation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true),")
      && sheet.contains("value: breathing)"))
check("breath no longer rides a one-shot onAppear transaction",
      !sheet.contains("withAnimation(.easeInOut(duration: 3.2)"))
let glowAnchor = "AgentGlowBorder(breathing: breathing)"
let glowTail = sheet.range(of: glowAnchor).map { String(sheet[$0.lowerBound...].prefix(500)) } ?? ""
check("glow layer cannot intercept touches",
      glowTail.contains(".animation(") && glowTail.contains(".allowsHitTesting(false)"))
check("user state exposes the weak 交还 entry",
      sheet.contains("pool.handControlBack()") && sheet.contains("Label(\"交还\""))
check("sheet has no remaining isAgentBusy gate",
      !sheet.contains("allowsHitTesting(!isAgentBusy)") && !sheet.contains("disabled(isAgentBusy"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
