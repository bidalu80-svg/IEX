# Browser source parity audit

Reference: `OpenMinis/OpenMinis` commit
`1a71df0f381cefde80bf912b723de6f9831bc177`.
All ten `src/ios/Agent/BrowserUse/*.swift` files, the three browser native-offload
files, `Diagnostics/BrowserResourceMonitor.swift`, and all six browser standalone
tests were read against the local equivalents. The pinned Git blob identifiers
and pre-change local SHA-256 hashes are recorded in
`browser-parity-source-manifest.json`. Reference names/schemes are mapped to Ze;
existing Chinese labels are retained.

| Area | Source evidence (local path / declaration) | Result |
| --- | --- | --- |
| WebView configuration | `Agent/BrowserUse/BrowserUseManager.swift`: `makeWebView`, configuration initializer, `sharedProcessPool` | Same process pool, data store, viewport injection, scripts, delegates and popup configuration as reference. |
| History | `Agent/BrowserUse/BrowserHistory.swift` | Identical after brand normalization; retained. |
| UIKit wrapper | `Agent/BrowserUse/BrowserWebView.swift` | Identical after brand normalization; retained. |
| Cookie backup and audit | `CookieBackupStore.swift`, `CookieAuditLogger.swift` | Identical after brand normalization; retained, including throttled restoration and HttpOnly handling. |
| Caller identity | `NativeOffloads/BrowserUseOffload.m`: guest-thread `noff_current_fs_context`; bridge `execute` | Pass actual guest task context to `ISHExecutionCoordinator.callerSessionId`; concurrent sessions no longer select the last mounted chat. Kernel adapter separates workspace identity from calling agent identity. Unknown nonzero context does not fall back to a different chat. |
| CLI cancellation | `BrowserUseOffloadBridge`: `inFlight`, `cancelAndReclaim` | Each invocation has its own token. A 90-second timeout cancels that invocation only; task completion removes its registration. |
| Pool cancellation | `BrowserTabPool`: `withDeadOnTimeout`, `abortAndRebuildTab`, `executeInner` | Cancellation runs the existing dead-tab rebuild path, releases its serial slot, and preserves intercepted dialog diagnostics. Already cancelled calls do not start new actions. |
| Tab ownership | `BrowserTabPool`: `tabOwner`, `lastTabByOwner`, `mayUse`, `releaseTabs` | Reference owner filtering, per-agent quota 2 and shared ceiling 6 are present. Current Ze VMs retain separate pools; this change does not silently change child VM architecture to shared pools. |
| Pool lifecycle | `BrowserTabPoolRegistry`, `releaseAllTabs`, idle/memory-pressure reclaim, persistence | Existing reference lifecycle retained; temporary tab overrides reset to defaults on reconstruction. |
| User agent arguments | `BrowserUseActions`: `UserAgentProfile.parse`, `userAgentRaw` | Accept case/whitespace/hyphen normalization and desktop/mobile aliases; missing/unknown profiles explicitly fail without changing tabs. |
| User agent application | `BrowserTabPool`: `setUserAgent`, `syncGlobalDefaultsFromStore`, `applyViewportToAllTabs` | Agent changes affect one tab inside its serial slot; settings change future defaults only. New tabs, popups and replacement tabs re-read defaults. Session viewport preserves individual tab UA. |
| UA UI | `BrowserSheetView`: principal toolbar; `BrowserManagementView` | Icon describes selected tab; settings reload persisted defaults on appearance. |
| JS results | `BrowserUseManager`: `wrapExecuteJSReturn`, `stringifyJSReturn`, `sanitizeForJSON` | Normalize DOMRect/toJSON, arrays, iterables, cycles, DOM nodes and errors before WebKit serialization; bound JS traversal to 32 and native traversal to 64 levels. |
| JS errors | `BrowserUseJavaScript`: `BrowserJSErrorFormatter`; manager and `Debug/DebugJSONRPC.swift` | Preserve exception message, line, column and bounded source location at every reference call site. |
| Loading/non-HTML documents | `BrowserUseJS`: `guardedRead`, `guardedAsyncBody`, `getPageInfo` | Explicit loading/no-body errors; metadata remains readable for body-less documents. |
| Password input | `BrowserUseJS.unguardedGetBackbone` | Capture filled password fields as `[redacted]`; plaintext is never placed into the intermediate DOM tree. |
| JS/dialog deadlines | `BrowserUseManager`: bounded evaluation, `navigate` | Execute JS 45s, fixed read scripts 10s, navigation 30s wall-clock timer; navigation timeout reports partial/stale state. Pool lock wait 20s, CLI90s and dead-tab300s follow pinned source. |
| Dialogs | `BrowserUseManager`: `recordInterceptedDialog`, `drainInterceptedDialogReport`, WKUIDelegate methods | Alert dismissed, confirm=false, prompt=nil; last20 retained with dropped count, reported exactly once in subsequent tool result. |
| Fetch | `BrowserUseManager.fetch` | Proper top-level async return, so fetched bytes/metadata reach native code instead of undefined. |
| Local resource response | `ZeSchemeHandler.webView(_:start:)` | HTTPURLResponse status200, Content-Type/Length headers; JS fetch can observe success. |
| Navigation/download | WKNavigationDelegate and WKDownloadDelegate in `BrowserUseManager` | Retained source behavior: download destination, cancellation/partial-file removal, progress, session events and preview paths. |
| Download UI | `BrowserSheetView`: `BrowserDownloadFloatingButton`, `FloatingCircleButtonSurface` | Pinned `ComposerSurface.swift` modifier: iOS26 interactive glass circle with circular hit target; original pre26 disc/stroke/shadow. Badge/panel/clear/cancel retained. |
| File chooser | Browser WKUIDelegate | Neither pinned source nor local agent browser defines a custom `runOpenPanel`; system WebKit behavior remains. No invented file-picker implementation. |
| Human takeover | `BrowserSheetView`, existing `AIChatViewModel+BackgroundTask` / `+ConcurrentTools` | Browser controls and model pause/resume/screenshot integration retained. No takeover UI redesign in this patch. |
| CPU diagnostics | `Diagnostics/BrowserResourceMonitor`: `currentAppCPUPercent` | Reference nonisolated, lock-protected 2s cache restored, avoiding duplicate expensive thread walks for diagnostic callers. |

## Explicit integration differences

- Pinned bridge checks `AgentToolSwitch.browser`. Ze has no equivalent global
  tool-master-switch setting or type; the existing browser registration policy
  is retained. This audit does not claim that setting is implemented.
- Ze uses its existing localization API (`String(localized:)`), schemes, paths
  and separate child-VM pools. Reference source provenance is not a claim that
  every app architecture/detail is identical.
- No new file upload UX or browser permissions UI was invented where the pinned
  source has none.

## Regression commands and acceptance limits

Run on macOS with Xcode selected:

```sh
python3 scripts/test-browser-parity.py --output browser-parity-evidence
```

The runner executes five adapted pinned standalone suites with a 180-second
deadline per suite and writes each full log plus `result.json` with exit codes.

| Suite | What actually runs |
| --- | --- |
| `BrowserUserAgentPerTabTests.swift` | Extracted shipping pool/action functions with recording WebView/defaults substitutes; 40+ behavior assertions plus wiring checks. |
| `BrowserJSErrorDetailTests.swift` | Shipping JS file compiled with a driver; JavaScriptCore executes no-body/loading/exception/success cases; NSError formatter assertions. |
| `BrowserUseDOMRectCloneTests.swift` | Real host WKWebView loads deterministic HTML and executes the production JS wrapper through WebKit serialization; DOMRect, arrays/nesting, await, cycles, depth and thrown errors. |
| `BrowserCLITimeoutReclaimTests.swift` | Async race/cancellation mechanism plus production wiring assertions. |
| `BrowserCLIReclaimScopeTests.swift` | Two overlapping invocations, exact-token cancellation, source wiring. Updated stale upstream assumption about global mounted-sid to the actual caller-context fix. |

Local Windows validation is limited to Python syntax, source/adaptor inspection,
and `git diff --check`. macOS suites, application compilation and live simulator/
device browser interactions are separate acceptance gates. The host WKWebView
suite proves returned-value handling, not complete app navigation/download/
takeover UI acceptance. CI must report the exact tested commit and suite exits;
no successful execution is claimed in this source audit before those results.

Rollback: restore the browser files listed in the manifest from the parent
commit, remove the added standalone runner/tests and audit artifacts, and revert
only the browser formatter/config-comment hunks in shared files. Preserve other
agents' kernel/GitHub/share/search edits.
