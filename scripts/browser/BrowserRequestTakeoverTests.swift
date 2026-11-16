#!/usr/bin/env swift
// [P3.1-request-takeover] Static pins for the agent-initiated
// `browser_request_takeover` waiting action.
//
// The real interaction (sheet auto-presents, user logs in, 完成 resumes the
// tool) needs a device/WebKit run. These source-level checks stop the
// architecture from regressing: registration, requested-state marker,
// continuation-based waiting with cancellation, completion URL/title, and
// structured user_cancelled.
//
// Run: swift BrowserRequestTakeoverTests.swift
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
func section(_ src: String, from: String, to: String) -> String {
    guard let start = src.range(of: from),
          let end = src.range(of: to, range: start.upperBound..<src.endIndex) else {
        return "/* MISSING SECTION: \(from) */"
    }
    return String(src[start.lowerBound..<end.lowerBound])
}

let actions = source("Agent/BrowserUse/BrowserUseActions.swift")
let manager = source("Agent/BrowserUse/BrowserUseManager.swift")
let pool = source("Agent/BrowserUse/BrowserTabPool.swift")
let sheet = source("Agent/BrowserUse/BrowserSheetView.swift")
let toolDefs = source("Agent/Chat/AIChatViewModel+ToolDefinitions.swift")
let concurrent = source("Agent/Chat/AIChatViewModel+ConcurrentTools.swift")
let chatView = source("Views/Chat/AIChatView.swift")
let toolSheet = source("Views/Chat/ToolLiveSheet.swift")
let vm = source("Agent/Chat/AIChatViewModel.swift")

print("\n1. Tool registration through the BrowserUse action channel")
check("BrowserAction has request_takeover",
      actions.contains("case requestTakeover = \"request_takeover\""))
check("BrowserActionInput parses the reason argument",
      actions.contains("var reason: String? = nil") && actions.contains("reason: dict[\"reason\"] as? String"))
let requestTool = section(toolDefs,
                          from: "name: \"browser_request_takeover\"",
                          to: "required: [\"reason\"]")
check("browser_request_takeover is registered with only a reason parameter",
      !requestTool.isEmpty && requestTool.contains("\"reason\": AgentToolParam") &&
      !requestTool.contains("\"tool_title\":") && !requestTool.contains("\"action\":"))
check("reason is the only required parameter",
      toolDefs.contains("name: \"browser_request_takeover\"") &&
      toolDefs.contains("required: [\"reason\"]"))
check("generic browser_use action list does not advertise the waiting action",
      toolDefs.contains("BrowserAction.allCases.filter { $0 != .requestTakeover }"))
check("tool handler runs through browserTabPool.execute",
      section(concurrent,
              from: "        case \"browser_request_takeover\":",
              to: "        case \"read_image\":").contains("browserTabPool.execute(action: input)"))
check("manager refuses direct execution of the pool-level action",
      manager.contains("case .requestTakeover:") &&
      manager.contains("request_takeover must be routed through BrowserTabPool"))

print("\n2. Control state switches to user with a requested marker")
check("pool keeps a single pending request marker",
      pool.contains("@Published private(set) var pendingTakeoverRequest: BrowserTakeoverRequestInfo?"))
let requestBlock = block(pool, "    func requestTakeover(reason: String) async -> BrowserActionResult {")
check("request flips controlState to user",
      requestBlock.contains("controlState = .user"))
check("request records the reason",
      requestBlock.contains("pendingTakeoverRequest = request"))
check("request event is distinguishable from a manual takeover",
      requestBlock.contains("kind: .requestedTakeover") &&
      requestBlock.contains("requested: true"))
check("event model carries requested + reason",
      actions.contains("case requestedTakeover") &&
      actions.contains("var requested: Bool = false") &&
      actions.contains("var reason: String? = nil"))
check("prompt fragment tells the model a request is pending",
      pool.contains("agent requested takeover: \\(request.reason)"))

print("\n3. Waiting is continuation-based, cancellable, and has no timeout")
check("request waits on a checked continuation",
      requestBlock.contains("withCheckedContinuation") &&
      requestBlock.contains("takeoverRequestContinuation = continuation"))
check("task cancellation resumes the waiter instead of leaking",
      requestBlock.contains("withTaskCancellationHandler") &&
      requestBlock.contains("sessionStopped: true"))
check("session stop also cancels an active request",
      vm.contains("browserTabPool.pendingTakeoverRequest != nil") &&
      vm.contains("browserTabPool.cancelTakeoverRequest()"))
check("no timeout task or busy polling inside the wait",
      !requestBlock.contains("Task.sleep") &&
      !requestBlock.contains("Timer") &&
      !requestBlock.contains("while "))
check("finishing a request can never double-resume",
      block(pool, "    private func finishTakeoverRequest(").contains("pendingTakeoverRequest, request.id == id"))

print("\n4. Complete returns the user's current page + control: agent")
let completeBlock = block(pool, "    func completeTakeoverRequest() -> BrowserActionResult {")
check("完成 routes through the single finish path",
      completeBlock.contains("outcome: .completed"))
let finishBlock = block(pool, "    private func finishTakeoverRequest(")
check("completion hands control back to agent",
      finishBlock.contains("controlState = .agent"))
check("completion event is the §2.5 hand-back event, marked requested",
      finishBlock.contains("BrowserControlEvent(kind: .handBack, state: .agent") &&
      finishBlock.contains("requested: true"))
check("completion result carries the live URL and title",
      finishBlock.contains("pageURL: snap.url") &&
      finishBlock.contains("snap.title"))
check("completion result reports control: agent",
      finishBlock.contains("control: .agent"))
check("execute wrapper keeps the completed handoff at agent",
      pool.contains("!(input.action == .requestTakeover && result.success)"))

print("\n5. Cancel returns structured user_cancelled and resets idle")
check("cancel routes through the single finish path",
      block(pool, "    func cancelTakeoverRequest() -> BrowserActionResult {").contains("outcome: .cancelled(sessionStopped: false)"))
check("cancel resets control to idle",
      finishBlock.contains("case .cancelled") &&
      finishBlock.contains("controlState = .idle"))
check("cancel uses the structured user_cancelled result",
      finishBlock.contains(".userCancelled(") &&
      actions.contains("errorCode: \"user_cancelled\"") &&
      actions.contains("static func userCancelled("))

print("\n6. Sheet presentation, banner, and dismissal cancel")
check("sheet auto-present path reuses showBrowserSheet",
      chatView.contains("onReceive(vm.browserTabPool.$pendingTakeoverRequest)") &&
      chatView.contains("showBrowserSheet = true"))
check("ToolLiveSheet also opens the browser when it is the top sheet",
      toolSheet.contains("pendingTakeoverPublisher") &&
      toolSheet.contains("activeSheet = .takeoverBrowser"))
check("sheet renders a top banner with the reason",
      sheet.contains("takeoverRequestBanner") &&
      sheet.contains("Text(request.reason)"))
check("banner has 完成 and 取消",
      sheet.contains("Button(\"完成\")") && sheet.contains("Button(\"取消\")"))
check("sheet's existing 完成 button hands back while requested",
      sheet.contains("isTakeoverRequested ? \"完成\" : \"Done\"") &&
      sheet.contains("pool.completeTakeoverRequest()"))
check("closing the sheet cancels the pending request",
      block(sheet, "            .onDisappear {").contains("pool.cancelTakeoverRequest()"))
check("request banner is gone once the request resolves",
      sheet.contains("if let request = pool.pendingTakeoverRequest"))

print("\n7. Session event uses the existing system-info channel")
check("requested takeover is rendered as a system info row",
      vm.contains("case .requestedTakeover:") && vm.contains("appendSystemInfo("))
check("requested hand-back has its own completion copy",
      vm.contains("用户已完成浏览器接管请求"))
check("does not fabricate a user message",
      !block(vm, "        browserTabPool.onControlStateChange = { [weak self] event in").contains("AgentMessage(role: .user"))

print(failures == 0 ? "\n✅ ALL PASSED" : "\n❌ \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
