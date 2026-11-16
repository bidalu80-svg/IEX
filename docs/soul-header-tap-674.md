# Run #674: real avatar touch trace and voice runner startup

## Status and evidence boundary

This change adds the missing real-touch instrumentation and bounds the voice UI
harness. It does **not** establish a fixed avatar or a fully green iOS run.
This workspace is Linux and has no `xcrun`, Swift compiler, Xcode, or simulator.
No remote execution tool is available, and pushing is explicitly prohibited.
The new instrumentation has therefore **not executed on iOS**. No image file was
opened, viewed, or attached during this investigation; only text artifacts and
source were examined. A mechanism without direct evidence is a suspect, not a
fix. In particular, removing the avatar context menu, moving its gesture, or
changing sheet ownership would currently be an unproven production change.

## A: enumerate the candidate links before choosing a mechanism

The complete candidate chain is:

1. XCTest resolves the intended avatar element and its current frame.
2. XCTest injects the raw coordinate touch at that frame's center, in the
   foreground app's window rather than a stale/background window.
3. Window routing selects a descendant of the badge hosting view; native bar
   controls, a presentation, another window, or stale routing could intercept it.
4. That selected view receives the actual `UITouch`, and the badge's event bridge
   participates. A `hitTest(point, nil)` probe alone cannot establish delivery.
5. The visual avatar center lies in the SwiftUI Button label's intended circular
   hit region. Portal rendering, coordinate transforms, padding, and modifier
   boundaries could separate the visual and gesture locations.
6. The SwiftUI gesture recognizes and invokes the production Button action.
   A context-menu/portal recognizer, another gesture, or an event-bridge issue
   could prevent recognition even after badge-level delivery.
7. The action requests presentation by setting the actual chat state, and that
   state survives updates/remounts; focus/celebration updates could interact.
8. SwiftUI presents the actual Soul sheet from its existing modifier. Existing
   presentations, controller/window choice, or a detached presenter could block it.
9. The Soul settings content and its toolbar appear and remain present.
10. XCTest's `app.buttons["完成"].firstMatch` query finds the displayed Done
    button. Wrong type, localization, scope, duplicate elements, or timing could
    make this query fail even after successful presentation.

### Existing text evidence, distinguished from new instrumentation

Artifact root: `/home/hatch/workspace/goals/iex-run/hidden_files/43752361634/`.
The iOS 18 files under `legacy/chat-layout-evidence/` establish:

- `chat-verification/header-hit-testing.json` records successful badge descent
  and exact root containment at every tested size/keyboard phase. Its **final**
  `before-external-coordinate-tap` avatar point is `(201, 84.3333)`, hitting
  `PortalGroupMarkerView[8]`. The earlier 40pt-size probe is `(201, 76.3333)`.
  The provider capsule hits `CGDrawingView[5]` at `(201, 120.3333)` in the final
  phase. Neither is an actual dispatched-touch trace.
- The before/after hierarchy attachments `6A19A384-B3AF-46F0-AE89-C8A9AA5A253A.txt`
  and `75F78D8C-2100-4D35-BD9B-EB9B7663156B.txt` both expose the avatar Button
  at `{{173.0, 56.3}, {56.0, 56.0}}`, center `(201, 84.3)`. Both still expose
  chat content. The after attachment does not show the Soul settings sheet or
  its Done button. Duplicate `Other` entries share the avatar identifier, but
  the driver explicitly selects `.buttons`, and that Button has the same frame.
- `test.log` records event synthesis at 3.94s, the unchanged Done wait starting
  at 4.46s, and assertion failure at line 53 after hierarchy capture at 10.15s.
- The 243/236 successful in-app checks prove their existing invariants. They
  do not invoke the real avatar tap action or prove that a sheet opened.

| Required suspect | Direct evidence and current disposition |
| --- | --- |
| SwiftUI portal separates visual/gesture locations | PortalGroupMarkerView is the measured hit and the final probe agrees with the Button center. Portal involvement is observed; a gesture-coordinate mismatch is **not proven or ruled out**. |
| Gesture hit area misses avatar center | AX and animation center agree at the final phase. There is no recorded SwiftUI gesture-target trace. This remains a suspect; geometry alone cannot prove recognition. |
| Action fires but presentation is suppressed | Source has a direct `showSoulSettings = true` assignment and a normal `.sheet` modifier, without a custom presented-controller guard in that path. #674 contains no action invocation trace. Suppression is **not proven or ruled out**. The separate hit-routing guard disables routing when a controller already presents UI. |
| Done query does not match the displayed sheet | The production toolbar literally declares `Button("完成")`; the after hierarchy still shows chat and no Soul sheet. A label mismatch alone has no supporting evidence. Actual presentation versus query failure still requires the new appearance hooks plus XCTest result. |

The exact broken link for A is **not yet identified**. The known gap is between
badge-level synthetic hit testing and the missing settings presentation.
No production avatar fix is claimed in this commit.

### Complete app-source state and lifecycle inventory

`showSoulSettings` has one declaration/initializer (`false`), one explicit
production opening writer (the avatar Button sets `true`), and the binding passed
to `ChatSoulSettingsPresentation`. Its Done button writes `false`; SwiftUI's
`.sheet(isPresented:)` binding may also clear it on dismissal. Recreating the
owning AIChatView state identity would initialize it again. There are no other
app-source assignments. `avatarCelebration` and `inputFocused` are changed in
the same action before the opening assignment. The new hooks change none of
those assignments, their order, the binding, or the sheet presenter.

Badge creation, reuse, parenting, removal, and restoration remain as inventoried
in `soul-header-containment-673.md`. `ChatHeaderHitRouting` and the entire
production containment/layout block are byte-identical to HEAD except the
DEBUG-only observer installation beside the existing badge verification ID.

### New trace and how to discriminate the candidates

`Documents/chat-verification/avatar-tap-events.json` is atomically rewritten
at each recorded event. It is copied with the existing chat evidence, including
on XCTest failure, **before** recorder cleanup. It contains:

- `observer.installed`: establishes that tracing was enabled on the actual host.
- `touch.window.0`, `.3`, `.4`: actual UIWindow `sendEvent` delivery for began,
  ended, cancelled phases, with the original UITouch identity, timestamp,
  coordinate, `deliveredIntoBadge`, full delivered target ancestry, ancestor
  recognizer types/states, badge frame, avatar label frame, and whether the point
  lies in that label's circular geometry. `viewsAtTouchInBadge` includes each
  containing view's type/frame/interaction state, including portal views.
- `touch.began` / `touch.ended` / `touch.cancelled`: observation by a recognizer
  installed on the actual badge, separately from the window observation.
- `avatar.action`: the first statement in the **production SwiftUI Button action**.
- `settings.requested`: immediately after the existing `true` assignment.
- `settings.bindingChanged`: the sheet modifier observes the actual binding.
- `settings.appeared`, `settings.doneAppeared`, `settings.disappeared`: lifecycle
  events on the existing sheet and existing Done control. Controller/presentation
  snapshots retain the observed window when the badge detaches for presentation.
- `touch.afterDispatch`: a later controller snapshot, without triggering any action.

XCTest attaches `avatar-coordinate-tap.json` and `avatar-settings-query.json`.
The original coordinate tap, five-second Done query, assertion, and Done tap are
unchanged. The new label geometry marker is noninteractive. The badge observer
never recognizes, delays, cancels, prevents, or is prevented by another gesture;
it fails when the touch ends. The window hook forwards the original event once.
All hooks are DEBUG-only and gated by `--verify-soul-avatar`; no observer or event
hook is installed when that flag is absent. The source extraction for provider
chrome includes the types but never enables them in that fixture.

`check-soul-tap-evidence.py` adds a success gate after successful XCTest: exactly
one actual dispatched touch in the avatar label circle, badge delivery with the
same touch identity, then the production action, true presentation request, and
both appearance hooks. Toolbar/sheet appearance may occur in either order.
Synthetic hit probes and direct fixture actions cannot satisfy this gate.
The EXIT trap also writes a diagnostic `avatar-tap-summary.json` on failure;
its best-effort summary does not replace or override XCTest's failure.

An observed touch outside the badge identifies routing/delivery; an inside
label touch received by the badge without `avatar.action` identifies the
host-to-action link, with portal/gesture details still needed to choose a
mechanism. An action without request identifies the action/state link; a request
without appearance identifies presentation; appearance and Done appearance
without a matching XCTest query identify the query/AX link. Do not label a
particular portal implementation a root cause just because its name occurs.

## B: the voice step did not reach its UI tests

The Build job log is `job-132928907602.log`, not `job-132928907314.log` (the latter
contains the full-app/header job). Build lines 570–600 show lifecycle checks
171 and projection checks 198 completing **before** the UI step starts at
19:26:50. The old script has no background log streamer, recorder, shutdown, or
wait after UI tests. It synchronously waits for `xcodebuild test-without-building`,
then exports attachments and exits with its status. Therefore "passed UI tests
followed by a cleanup hang" is contradicted by these text artifacts.

The UI step signs its app at 19:27:21; bootstatus returns at 19:29:29. The UI
`test.log` begins at 19:33:43 and contains no test-case start or success.
`VoiceCall.xcresult/Staging/1_Test/Diagnostics/.../Session-*.log` records:

| Time (UTC) | Observed operation |
| --- | --- |
| 19:33:51.657 | test session begins |
| 19:34:12.592 | launch session starts |
| 19:34:18.168 | starts installing ShareDriver-Runner.app |
| 19:37:00.733 | runner installation completes: **162.565 seconds** |
| 19:37:01.145 | starts launching runner with `wait_for_debugger = 1` |
| 19:37:05.123 | external ten-minute cancellation |

The standard-output file is empty and scheduling records a worker with PID 0.
The script's unbounded simulator/Xcode startup uses up the job budget before
XCTest begins; the 180-second per-test allowance cannot bound this startup.
The log does **not** prove a deadlock in debugger attach, a SwiftUI animation idle
wait, or a successful UI-test run. Those mechanisms remain suspects, not fixes.
The old selection silently chooses the first/newest available iPhone when none
is booted, selecting iOS 26.4.1 here.

### Harness change and its limits

The harness now builds for a generic simulator destination independently of a
live simulator, selects the oldest installed iOS major deterministically (or requires the explicit
`ZE_SIMULATOR_IOS_MAJOR`), and boots only a shutdown device. Auto selection also
runs on macOS 26 hosts with only an iOS 26 runtime.
Missing requested runtimes fail loudly. Neither test code nor production voice
code changes, and no test is filtered, disabled, retried as success, or skipped.
Whether oldest-runtime selection/generic destination removes the observed startup latency still
requires a macOS run; this is a mitigation, not a proven simulator root-cause fix.

`run-bounded-command.py` runs each simulator/build/test command in its own process
group with an explicit timeout. Expiry prints the command, terminates the group,
escalates to KILL, and returns **124**, never success. Normal nonzero statuses
are preserved; negative signal statuses become the conventional shell status.
Interruptions also clean up the group. All stdout/stderr is retained in stage
logs and printed when the stage ends. Preparation, assets, compilation, signing,
selection, boot, installation, build, and UI execution share a 510-second budget.
Attachment export has a separate 30-second bound and cannot overwrite the UI
result. This bounds failure before the job-level cancellation while allowing
normal success to return as soon as XCTest/export complete. The original
180-second per-test allowance remains; the UI subprocess bound is 240 seconds,
subject to the shared remaining budget.

No `.github/workflows/` file changed. The existing separate 171 lifecycle checks
and 198 projection checks are unchanged. This change does not claim that the
voice UI tests have passed on a simulator.

## Assertion inventory and preservation

All 67 `try require` sites in `ConversationChatVerification.swift`, every
provider chrome assertion, all 25 voice XCTest assertion sites, and all 11
full-app XCTest assertion sites retain their original text and conditions.
The following are the relevant individual guards (some run in multiple phases).

### Header hit testing and containment

| Existing guard | Why this change preserves its condition |
| --- | --- |
| Actual badge, avatar, and navbar exist | No production element or controller removed. |
| Avatar receives a window-level badge hit | Production hit routing is byte-identical; observers do not choose targets. |
| Provider capsule receives a window-level badge hit | Capsule and hit routing unchanged. |
| Leading navigation receives a window-level bar hit | No navigation view or hit override changed. |
| Trailing navigation receives a window-level bar hit | Same. |
| Leading target is exactly the bar's native target, nonnil and not bar itself | No target substitution or intercepting marker. |
| Trailing target is exactly the bar's native target, nonnil and not bar itself | Same. |
| Badge superview is root.view AND its actual controller parent is root | Mounting/containment block unchanged apart from gated observer. |
| Scoped routing is active for this badge/bar | Installation and lifecycle unchanged. |
| Avatar width becomes size minus 4 for both 40 and 80 | Avatar dimensions and padding unchanged. |
| Keyboard receives focus with avatar present | No focus behavior changed. |
| Avatar midY moves less than 1pt before/during/after keyboard | No header constraints or layout changed. |

These still execute at size 40/80, their keyboard phases, and immediately before
the external tap. The new trace gate strengthens actual-touch coverage instead
of substituting for these badge-level hit checks.

### Provider chrome navigation ownership and routing

All guards in `ProviderChatChromeHarness.swift` remain byte-identical:

| Individual guarded behavior | Preservation reason |
| --- | --- |
| Light/dark/light keeps the same frost and top owner | No appearance or navigation mutation. |
| Unrelated bar appearance unchanged | No global appearance change. |
| Mounted provider view leaves top owner unchanged | Root-only mounting unchanged. |
| Visible badge is window-hittable above noninteractive frost | No target routing change. |
| Collapse removes host with same owner | updateBadge(nil) unchanged. |
| Expand restores host with same owner | Installation unchanged. |
| Provider switch reuses host with same owner | Root-view reuse unchanged. |
| Leaving restores prior item appearance | restore unchanged. |
| Leaving removes frost | restore unchanged. |
| Leaving removes badge with same owner | Removal/containment unchanged. |
| Interception fixture begins with a native bar target | Fixture unchanged. |
| Header host parent/root superview/top owner identities all match | No mounting hierarchy edit. |
| Scoped passthrough is active | Route install unchanged. |
| Intercepted hit forwards to badge descendant | target(at:) unchanged. |
| Leading native target identity preserved | Same. |
| Trailing native target identity preserved | Same. |
| Outside-header content target unchanged | Routing scope unchanged. |
| Unrelated window still hits unrelated button | New event hook is inactive without verification flag; existing hit hook unchanged. |
| Presented sheet wins and routing is inactive | Presentation guard unchanged. |
| Pushed model picker owns navigation and disables header routing | No push/parent/navigation code changed. |
| Pop back restores routing | Route lifecycle unchanged. |
| Removing badge immediately disables routing | Removal unchanged. |
| Restore disables routing, restores native hit, and preserves top owner | restore unchanged. |

### Full-app avatar XCTest and following interactions

| Existing assertion (all 11 sites) | Preservation reason |
| --- | --- |
| Full application checks finish with ready marker | Existing wait, timeout, and condition unchanged. |
| Actual avatar Button exists | Same `.buttons` query and five-second wait. |
| **Avatar tap opens actual Soul settings** | Same raw center tap and `完成` Button existence assertion; not replaced by hook success. This is still a known failing assertion pending actual iOS diagnosis. |
| Celebration becomes idle within 8 seconds | Deadline/action code unchanged. |
| Avatar exists after foreground | Activation/query unchanged. |
| Expired celebration stays idle on return | Same value equality; no replay fix or relaxation. |
| Tool preview exists | Same query/wait. |
| Preview is hittable | Same condition. |
| Preview upper tap opens actual close control | Same coordinate and real-sheet assertion. |
| Actual attachment tray exists | Same query/wait. |
| Attachment tap opens actual attachment navigation bar | Same coordinate and real-preview assertion. |

The new attachments add observations only. No assertion is reworded, weakened,
removed, or given a longer wait. The failing avatar assertion is **not claimed
green** on the strength of source preservation.

### Voice assertions

The unchanged 25 XCTest assertion sites cover, in order: initial expand existence;
compact expand label; expanded label; caption-control existence; mute label;
muted status; unmuted label; captions hidden; captions restored; collapsed label;
caption control absent when collapsed; fixture reply hittability; speaking status;
interrupt existence; listening status; paused status; resume existence; resume
height at least 44; resume absent after resumption; ended state after hangup;
mute absent after hangup; accessibility-size expand existence; compact hangup
hittability; compact mute hittability; expanded hangup hittability. The first
21 run in both light and dark, and the last four cover accessibility size.
All use the same production panel, actual taps, limits, and screenshots.
The voice fixture, these tests, lifecycle tests, and projection code are unchanged.
Only scheduling/startup and process lifetime are changed.

## Local validation

- Eight harness tests pass: subprocess success/failure status; timeout kills a
  stubborn process tree; failure logs retained/printed; full shell success despite
  attachment export failure; full shell propagates XCTest exit 65; shutdown device
  booted; missing requested runtime fails instead of silently skipping tests;
  auto selection executes on hosts with only iOS 26 installed.
  Apple operations/asset preparation are stubbed; these are process-control tests,
  not simulator test results.
- Four evidence-gate tests pass: complete chain with either appearance order;
  every missing link fails; wrong geometry/target fails; action before real touch
  cannot satisfy the gate. These synthetic traces validate the parser only.
- Changed shell/Python syntax and `git diff --check` pass.
- Production provider chrome **source-only** extraction passes. Asset-copy/hash
  portions were not executed, to honor the no-image-file rule.
- Byte comparisons confirm the full in-app verifier, provider chrome harness,
  voice UI tests/fixture/lifecycle tests, and production window hit-routing block
  are unchanged. Every original full-app XCTest line remains verbatim and in order.
- Swift parsing/type checking and real iOS 18/26 tests cannot run here. Dispatcher
  must collect the new trace on iOS; identify and fix A from that actual evidence;
  verify the voice startup mitigation; then obtain the requested fully green run.
  This commit is an instrumented investigation plus harness hardening, not a
  completed claim of that goal.
