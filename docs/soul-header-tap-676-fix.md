# Run #676: avatar label hit testing and voice harness budgets

## Evidence read and scope

Primary text artifacts, read directly:

- `43798940783/legacy/chat-layout-evidence/chat-verification/avatar-tap-events.json`
- `43798940783/review26/chat-layout-evidence/chat-verification/avatar-tap-events.json`
- `43798940783/legacy/chat-layout-evidence/avatar-tap-summary.json`
- `43798940783/legacy/chat-layout-evidence/test.log`
- `43798940783/legacy/chat-layout-evidence/chat-verification/result.json`
- `43798940783/build-job.log`
- `43752361634/job-132928907602.log`

Both artifact directories are under
`/home/hatch/workspace/goals/iex-run/hidden_files/`. Also read the previous
investigation, `docs/soul-header-tap-674.md`, and the pre-instrumentation voice
script with `git show 3017d07:scripts/test-voice-call-ui.sh`.

The trace has seven rows. Rows 3/4/5/6 are respectively `touch.window.0`,
`touch.began`, `touch.window.3`, and `touch.ended`, all with touch ID
`ObjectIdentifier(0x0000000110d3d380)`, point `(201, 84.33332824707031)`,
`deliveredIntoBadge=true`, and `insideAvatarLabelCircle=true`. The avatar label
frame is `(173, 56.3333, 56, 56)`; the animation frame is
`(175, 58.3333, 52, 52)`. The **actual delivered target** is the badge's
`_UIHostingView<AnyView>`. The containing-view list is not the delivered ancestry:
in particular it does not establish that a portal or glass view received the
touch. Row 7 is `touch.afterDispatch`; no action/request/appearance event exists.
The summary says exactly
`Missing production event after actual avatar touch: avatar.action`.

XCTest synthesizes the center tap at 4.32s, starts the unchanged five-second Done
wait at 4.84s, and fails `Avatar tap opens actual Soul settings`. The separate
in-app result is `success=true`, iOS `18.5`, with **243 checks**. These facts
agree with the brief: the first broken link is badge-to-Button-action. There is
no evidence of an action followed by failed routing or presentation. The trace
does not independently test presentation after a successful action.

No image file was opened, viewed, or attached. Visual review and the asset
copy/hash portion of the provider extraction were skipped because they would
open image files. This Linux workspace has neither Swift nor `xcrun`; real
iOS 18/26 execution remains for CI. No simulator success is claimed here.

## Interaction writers: complete avatar dependency closure

Searched the whole project (Swift, Objective-C, Objective-C++) for
`isUserInteractionEnabled` assignments, Objective-C `userInteractionEnabled` /
`setUserInteractionEnabled`, `addTarget`, `addGestureRecognizer`, `addInteraction`,
`touchesBegan/Ended/Cancelled/Moved`, `makeUIView/Controller`, and SwiftUI
`gesture`, `highPriorityGesture`, `simultaneousGesture`, `onTapGesture`,
`onLongPressGesture`, and `contextMenu`. The initial combined Swift/Objective-C handler scan matches 59 files; the
Objective-C property/target follow-up adds only unrelated native terminal/about
views and media controls.
Follow-up type/reference searches identify the closure below; no other project
extension or writer changes these avatar descendants' interaction flags.
Framework-generated hosts are distinguished from the UIViews returned by
representables. #676 records different UIKit interaction flags on hosts and
their returned UIViews. `viewsAtTouchInBadge` records geometric overlap and
UIKit interaction flags, not SwiftUI gesture arbitration. In particular, the
legacy glass host reports `interactive=true` despite the existing SwiftUI
hit exclusion at `AIChatView.swift:4848`. The flag alone cannot establish
interference or tell us whether a host participates in SwiftUI hit testing.

| Descendant / layer | Creator and interaction writers | Own gestures or touch handling |
| --- | --- | --- |
| Avatar Button and label | `AIChatView.titleView`; production Button action clears focus, sets a five-second celebration deadline, then sets `showSoulSettings=true`. The new label `ZStack` supplies `.contentShape(Circle())`. Button remains enabled. | SwiftUI Button press is the intended tap handler; action and DEBUG event ordering are unchanged. |
| `SoulHeaderAvatar` | `titleView` creates it; `SoulStore.swift` resolves motion and observes the current message/block. Now excluded from SwiftUI hit testing at this call site, including its generated hosts. | No gesture, touch override, or UIKit interaction writer. Its two `onReceive` callbacks only invalidate content. |
| `SoulHeaderAvatarSurface`, `Group`, sizing and animation padding | `SoulHeaderAvatar` creates the surface. Surface chooses custom image/emoji versus animation and sets a square frame; animation has 2pt padding. Previously default SwiftUI hit participation; now inherits the visual subtree exclusion. | No gesture. Notification observer refreshes metadata; task changes celebration state until its existing deadline; scene phase/reduce motion control playback. |
| `SoulAvatarView` custom image branch | Surface creates it at `size * 0.76`, `fitsImage=true`. It creates resizable `Image(uiImage:)`, aspect-fit, circular clip and AX label. | No gesture or UIKit host created by app code. `onAppear` and `onReceive` reload metadata only. |
| `SoulAvatarView` emoji branch | Same creator; creates `Text(trimmed)` with font, minimum scale and one line. | No gesture or touch handler. |
| `SoulAvatarView` empty emoji fallback | Same view can create resizable/scaled `Image("ZeAssistantAvatar")`. Surface ordinarily selects animation instead when both custom image and emoji are absent. Included for completeness. | No gesture or touch handler. |
| `SoulAvatarAnimation` platform host | SwiftUI creates `PlatformViewHost<PlatformViewRepresentableAdaptor<SoulAvatarAnimation>>`; #676 records **interactive=true** at the animation frame. The app previously had no SwiftUI hit exclusion here. | No project-installed recognizer on this host; framework internals are not project source. The new visual-subtree exclusion targets possible competition with the Button's label target; such competition is a hypothesis, not demonstrated by the flag. |
| `SoulAvatarAnimationView` | Representable `makeUIView` constructs it; initializer is the sole writer: `isUserInteractionEnabled=false`. `updateUIView` only configures playback; dismantle stops it. #676 confirms false. | No recognizer, `UIInteraction`, or touch override. Lifecycle/layout overrides update playback and layer frames only. |
| Fallback `UIImageView` | Animation view's stored initializer creates it and `init` adds it. UIImageView defaults to noninteractive; no later interaction writer. #676 confirms false and hidden=true after decoded video appears. | No gesture. |
| Current/incoming/outgoing `AVPlayerLayer`s and root layer | Animation view's `Clip` creates muted queue players, loopers and layers; reveal/layout/dispose manage opacity, geometry and lifetime. Layers are not UIViews or independent hit targets. | KVO decoded-frame readiness and opacity animations only; no player controls or touch handlers. |
| DEBUG `ChatSoulTapTargetMarker` host and UIView | `titleView` background only under DEBUG plus `--verify-soul-avatar`; `makeUIView` creates UIView and writes false, registers its weak evidence target. Trace: host true, child false. Now `.allowsHitTesting(false)` also excludes its SwiftUI host. | No gesture. Frame registration remains active; disabling hits does not remove it or change its bounds. |
| `ChatHeaderButtonStyle` | Applied to avatar and provider Buttons. On iOS 18 adds a Capsule fill overlay with `.allowsHitTesting(false)`, scale and spring; on iOS 26 returns label. | Reads `configuration.isPressed`; installs no independent gesture. Existing overlay already excluded. |
| `ChatNavigationGlassSurface` | Applied outside the Button, not literally inside its label. iOS 26 calls `.glassEffect(.regular.interactive(), in: Circle())`; other branch adds legacy background. Included because it surrounds the same hit region. | Native glass intentionally reacts to interaction. Its API and content remain enabled and unchanged. |
| `ChatNativeGlassMarker` hosts and UIViews | Each circle/capsule native/fallback branch creates the representable. `makeUIView` is sole false writer; DEBUG flag only supplies AX ID. Trace: host true, child false at full avatar frame. All four call sites now exclude the marker host with `.allowsHitTesting(false)`. | No gesture, touch handling, update writer, or rendering role. It only identifies the chosen branch and geometry. |
| `ChatLegacyGlassSurface` ZStack | Glass modifier creates it. Contains reduce-transparency solid shape OR active-Metal refractive representable OR material/color/gradient fills; always adds gradient stroke and shadow. Whole background already has `.allowsHitTesting(false)` and `.accessibilityHidden(true)`. | No gesture; environment reads select rendering. |
| `ChatLegacyRefractiveGlass` host / `OpenGlassView` | `makeUIView` constructs `OpenGlassView(configuration: .clear)` and writes false, hides AX descendants. Trace: host true, OpenGlassView false. The enclosing legacy background already excludes SwiftUI hit testing. `updateUIView` sets refraction, blur, tint, corner radius and **physicsMode=.none**. | OpenGlass `didMoveToWindow` installs press/pan only if physics is not none. `GlassConfiguration.clear` starts with none, before attachment as well as after updates. Thus this path installs neither. |
| OpenGlass CAMetalLayer and backing layer | `OpenGlassView.setup` creates CAMetalLayer; layout/engine registration configure/draw it. No child UIView is created here. | Layers have no UIKit hit participation or touch handler. |
| `PortalGroupMarkerView`, two `_UIInheritedView`s, `_UIShapeHitTestingView` | SwiftUI runtime, no project class definition or interaction assignment. Trace flags respectively true, false/true, false. Present at full avatar bounds, alongside the context-menu/effect infrastructure. Exact private construction is not exposed by source. | No app-installed handler on these views. Their presence alone is not evidence of a cancelling gesture. They are not removed or mutated. |
| iOS 26 `UIPlatformGlassInteractionView` | The review26 trace lists this framework view at the avatar bounds with `interactive=true`. It is consistent with the native `.glassEffect(.regular.interactive(), in: Circle())` branch; the trace does not expose its private construction or arbitration. | Not the chosen blocker: overlap and a true flag do not prove interception, and the same missing-action failure occurs in the legacy trace without this view. Its possible contribution on iOS 26 remains unresolved; native interactive glass is preserved. |
| iOS 26 window `_UIFlexInteractionPanGestureRecognizer`s | The review26 delivered-ancestry gesture list contains four enabled recognizers on `UIWindow`. At `touch.ended` one has state **3** (ended/recognized), while the other three have state 0. No project installation site is established. | Not the chosen blocker: state 3 shows recognition but does not identify the touch dependency, prevention relationship, or cause of the missing SwiftUI Button action. Its role remains unresolved; it is not removed or disabled. |
| Context menu and its conditional menu Button | `titleView.contextMenu` genuinely exposes `编辑会话` when `titlePillSession` exists; its Button sets `titlePillEditSession=session`. This surrounds the avatar control rather than being a decorative descendant. | Legitimate long-press/secondary-click interaction; preserved. Removing it would remove a production action without evidence that it caused this tap failure. |

Two containing layers are **outside** the avatar closure but also appear in the
trace: the badge `_UIHostingView<AnyView>` is intentionally interactive and owns
the SwiftUI controls; its `ChatCallLayoutMarker` platform host is interactive,
while the returned `ChatLayoutGeometryUIView` writes false in `init`. That marker
measures the whole badge (200x112), installs no gesture, and is unchanged.

The badge's DEBUG `ChatSoulTouchObserver` is the only app-added recognizer on
the delivered path: it records began/ended, cannot prevent or be prevented,
does not delay/cancel touches, and fails at end. Window event swizzling forwards
each original event once. Both remain byte-identical. UIKit's hover, duration,
simple-press, secondary-click, relationship and system-gate recognizers in the
trace are framework-created. The trace is not an internal SwiftUI recognizer
decision log; it cannot uniquely blame one private recognizer or portal class.

OpenGlass has a second, distinct source path: `OpenGlassWrapperRepresentable`
and `OpenGlassConfigWrapperRepresentable.makeUIView` construct
`OpenGlassWrapperView`, which embeds another hosting view and unconditionally
calls `glassView.installGestures(on: self)`. That installs zero-duration press
and pan recognizers for interactive physics. **Neither wrapper is instantiated
by this avatar**: `ChatLegacyRefractiveGlass` constructs OpenGlassView directly.
Those real interactions and all vendor code are left alone.

## Production hypothesis and minimal change

The demonstrated failure is between delivery into the badge at the avatar
circle center and the absent Button action. The trace does not establish that
Button label hit testing is the cause. The former label was primarily a platform
representable with no explicit label-local hit shape; its Circle shape was
outside the styled Button. Competition from that visual subtree is a suspect,
not a demonstrated mechanism. The production change is a targeted hypothesis
consistent with the trace: exclude the visual avatar subtree at the SwiftUI
level and give the enclosing label ZStack an explicit circular content shape,
with the intention that the Button owns the tap target. Custom image and emoji
branches use the same structure. The ZStack takes its size from the same
content; no padding, dimension, controller or gesture was added.

The change also excludes purely diagnostic glass markers and the tap-frame
marker at the SwiftUI level. Their child-UIView flags do not establish whether
their hosts interfered with the Button. Neither those flags nor the true host
flags demonstrate a repair. The already-excluded legacy glass host is a concrete
counterexample to inferring SwiftUI participation from `interactive=true`.
The trace cannot isolate which, if any, overlapping host wins internal
arbitration. The extended iOS 26 enumeration above leaves native glass and the
recognized window pan unresolved; it does not prove that the production change
targets the wrong layer. This revision therefore leaves production code intact.

Legacy physics is none from construction, and no OpenGlass press/pan recognizer
is present on the delivered ancestry. Native interactive glass configuration
and the edit-session context menu remain enabled; their actual response after
the change still needs device validation. Portal presence, a failed relationship
recognizer, and a recognized window pan do not establish which interaction caused
the missing action. No replacement tap recognizer, direct settings invocation,
verification-only action, mount change or routing change was added.

The same production label change applies without the verification flag. Its
verdict comes from the unchanged CI trace gate, not from this document: the real
production chain must fire after an actual avatar touch on iOS 18 and iOS 26:
`window touch -> badge -> avatar.action -> settings.requested -> settings.appeared -> settings.doneAppeared`.

## Voice budgets derived from both runs

The old stage caps were not timing measurements. #676's prepare runs from
03:35:18.307642 to 03:35:18.757823 (0.450181s including wrapper overhead), then
assets is killed after 60.099181s at 03:36:18.857004, exit 124. **60s is a censored
lower bound, not actool's completion time.** No later stage ran in #676.

#674's step starts at 19:26:50.601413; prepare prints at 19:26:50.948461;
actool output ends at 19:27:09.545750; signing prints at 19:27:21.539866.
Prepare+assets+compile+sign therefore take about 30.94s together, not minutes
each. Selection/boot occurs next; bootstatus itself logs 19:29:28.651039 to
19:29:29.081552 (0.430513s, already booted). The roughly 127.54s since signing
belongs to the **combined selection/boot interval**, not a measured 128s
bootstatus call. Do not move the later 162.565s runner install into this interval.
The previous investigation records that runner install at 19:34:18.168 to
19:37:00.733 inside test execution, followed by job cancellation at 19:37:05.123.
There is no completed UI-test duration in either run. The audit measures the
test stage's observed lower bound as **201.682141s**, including runner install.
Three times that lower bound is **605.046423s**, already greater than 510s.
The original brief's pair of constraints (every stage >=3x its worst observed
duration AND total <=510s) is arithmetically unsatisfiable. That contradiction
belongs to the brief; the shared-pool design stands with **no per-stage 3x
promise**, even for one stage in isolation.

The rule is **504s command pool + 6s termination reserve = 510s nominal**.
All command stages share the remaining pool, with stage names retained for
logs. The largest single observed operation, the **162.565s runner install**,
fits approximately 3x inside the pool only when other stages are fast:
3x is 487.695s, leaving just 16.305s for all other commands. It is an operation
inside the test stage, not the whole test stage's duration or a stage guarantee.

| Command label | Observed duration / evidence boundary | Resulting budget and limitation |
| --- | --- | --- |
| prepare | 0.450181s in #676; <0.35s to first output in #674 | Remaining pool; no separate stage reserve. |
| assets | ~18.60s from prepare output to actool output in #674; >60s in #676 | Remaining pool replaces the 60s cutoff; completion time remains unknown. |
| sdk-path | No separate measurement; previously outside the bounded compile command in shell substitution | Remaining pool bounds the xcrun subprocess tree. Only its trimmed stdout becomes the SDK path; stderr stays in the diagnostic log. |
| compile | ~11.994116s window includes SDK lookup, compilation, plist work and signing output | Remaining pool; compilation is not separately measured. |
| sign | Not isolated; all four early stages together ~30.94s | Remaining pool replaces the separate 15s cutoff. |
| build | No isolated build duration in supplied job logs; bootstatus-to-test-log gap also contains app installation and other startup | Shares up to 504s. No invented 120s success-duration estimate. The current generic build order is preserved. |
| select-device | Included in ~127.54s combined selection/boot interval | Remaining pool replaces the separate 15s cutoff; selection is not separately measured. |
| device-state | New diagnostic list; no isolated observation | Remaining pool; no separate stage reserve. |
| boot | Included in the same combined interval; no isolated completion duration | Remaining pool; still only boots shutdown devices. |
| bootstatus | 0.430513s directly observed, but only on already-booted device | Remaining pool; cold-boot completion time remains unknown. |
| install | Harness-app install not separately timed; distinct from runner install | Remaining pool replaces the separate 60s cutoff. |
| test | At least 201.682141s before cancellation, including 162.565s runner install; no completion | Remaining pool cannot provide 3x the observed stage lower bound. Per-test allowance remains exactly 180s. |
| export | No completed duration in either run | Shares remaining pool rather than receiving a separate guessed 30s allowance outside the envelope. Ordinary diagnostic export failure remains best effort; export timeout after successful tests returns 124. |

The execution deadline is set once to `SECONDS + 504`; each command receives
only its remaining time, never a fresh 504s. Six seconds are reserved for the
bounded runner's two three-second termination graces.
Commands fail with 124 on expiry; if no time remains before a command, it also
returns 124. Normal command failures propagate through `set -e`; test status is
captured and restored after diagnostic export. Export cannot replace a real
test failure with success or another code. The xcodebuild test invocation is
byte-identical. The explicit-runtime selector is unchanged and still fails
loudly for a missing requested iOS major.

The 510s figure bounds command execution and termination grace nominally;
it is **not an enforced strict wall-clock bound for the whole script**. Inline
filesystem/Python operations between stages (directory/copy/read operations,
SDK whitespace trimming, device JSON parsing and plist rewriting), shell and
process startup, and the runner's final log read/print have no independent
timeout. The runner now reads and prints only the last **64 KiB** of each log,
retaining the full file as evidence. This bounds the output size, not the time
of filesystem access or a blocked console write. These small inline operations
remain outside the nominal bound; time spent on them before a subsequent stage
also reduces that stage's remaining pool. No completed voice run proves that
the pool is sufficient or that the old simulator stall is cured.

## Assertion inventory and preservation

No assertion/check source, message, wait, timing, fixture, or test invocation
was removed or relaxed. Source byte comparisons against the starting HEAD
verify this, including the entire in-app verifier, provider harness, full-app
XCTest, voice XCTest/fixture and trace gate. In this revision the bounded runner
only changes its final log output to a capped tail; statuses and timeouts are
unchanged. Relative to the pre-fix source, AIChatView differs only in the avatar
label and four decorative glass-marker call sites; therefore
its mount, `ChatHeaderHitRouting`, trace code, action, presentation, styles and
context menu are byte-identical.

| Guarding assertions / checks | Why the change preserves the invariant |
| --- | --- |
| In-app header: actual badge/avatar/navbar and provider/leading/trailing markers exist | All views/markers remain mounted, sized and identified as before; hit exclusion does not remove them. |
| Avatar and provider capsule receive window-level hits in badge | Button now supplies its own circular target; provider Button remains interactive; only visual/diagnostic descendants opt out. |
| Leading/trailing hit lies in navbar, is nonnil, not navbar itself, and equals bar's native target | No bar, control or window routing edits; diagnostic markers receive SwiftUI hit exclusions, whose effect still needs device validation. |
| Badge view AND controller belong directly to window root; scoped passthrough active | Mount, containment and routing blocks unchanged. |
| Size 40/80 yields animation width `size - 4`; viewport contains avatar; keyboard focus succeeds; avatar midY changes <1pt | New ZStack takes the same intrinsic size; surface frame, padding, constraints and focus remain unchanged. Checks run through the existing keyboard/size phases and before external tap. |
| Idle/thinking/speaking/awaiting/working choose correct light/dark clip, ready display, time >0.05; same view keeps advancing after token updates | All motion selection, players, layer rendering, observations and stable surface structure in SoulStore remain byte-identical. Hit exclusion changes neither lifecycle nor playback. |
| Header text matches each motion; tool output leaves label unchanged; pending question valid; completed/user-input states restore provider | Activity model and provider Button content untouched. |
| Four branch markers exist; opposite branch invisible; exactly four legacy Metal lenses; unregister/re-register safe; every lens submits new frames | Glass code/configuration/engine unchanged; marker hosts still exist and render no pixels. Hit exclusion does not detach lenses. |
| Legacy refraction finds capsule surfaces and changes pixels in >=3 samples; avatar retention one view/player after cycles; measured footprint >0, growth <32MiB | No rendering, asset, memory, or lifecycle changes. Existing runtime/pixel checks remain; local visual execution was skipped. |
| Provider harness: separator removed, native background clear, noninteractive sharp gradient exists, gradient ends at navbar center, top/bottom alpha 1/0, no page-controller mask | Frost and appearance implementation untouched. |
| Provider harness: light/dark/light preserves frost/top owner; unrelated bar unchanged; mount/collapse/expand preserve owner; provider switch reuses host; restore removes frost/badge and restores appearance | Whole ownership/lifecycle implementation untouched. |
| Provider harness: native interception fixture; root parent/superview; passthrough active; forwarded badge hit; exact leading/trailing native targets; outside content and unrelated window hits unchanged | Entire hit routing and harness source unchanged. |
| Provider harness: sheet wins; pushed picker owns navigation and disables routing; pop restores routing; remove disables immediately; restore removes routing and restores native hit/top owner | Presentation guards, routing lifecycle and navigation unchanged. |
| Provider harness: both badge toggle callbacks; artwork and provider resolution; nonblank galleries/navbar, visible badge pixels, real scrolling and viewport behind navbar | Diagnostic marker exclusion changes no content, callback or renderer. This fixture does not instantiate ChatNavigationGlassSurface; it cannot substitute for full-app glass/tap verification. |
| Full-app XCTest: ready marker, actual avatar Button exists, center coordinate tap opens actual Done Button within 5s | Same AX identifier/label and real action. No synthetic action or widened wait; this is the decisive pending iOS regression check. |
| Full-app XCTest: celebration becomes idle within 8s, avatar survives foreground, expired celebration remains idle | Same action and celebration deadline; no animation code changes. |
| Full-app XCTest: tool preview exists/hittable, upper tap opens close control; attachment tray exists and tap opens actual attachment navbar | No preview, attachment or other hit area changes. |
| Trace gate: exactly one real center touch; delivered into badge; observer same touch ID and target; ordered action, true request, sheet/Done appearances after request (either appearance order) | Gate and observers unchanged; label marker remains registered at the same bounds. Success must come from the production Button action. |

Voice XCTest has 25 unchanged assertion sites: expand exists; compact label;
expanded label; captions control; mute label; muted status; unmuted label;
captions hidden/restored; collapsed label; collapsed captions absent; fixture
reply hittable; speaking status; interrupt exists; listening status; paused
status; resume exists; resume height >=44; resume absent after resumption;
ended state; mute absent after hangup; accessibility-size expand exists; compact
hangup/mute hittable; expanded hangup hittable. The first 21 execute in both
themes. Budget pooling changes no tap, expected value or allowance. The
separate voice lifecycle/projection code and tests also remain unchanged.
The xctestrun rewrite still asserts exactly one product and one test target.

Local harness guards remain: subprocess 0/65 propagation, stubborn child-tree
timeout returns 124 and kills child, retained/printed failure logs, shell
success despite ordinary export failure, actual XCTest 65 propagation, shutdown
boot, mandatory-runtime failure, and automatic selection on iOS-26-only hosts.
Evidence tests still accept the complete real chain in either appearance order
and reject every missing link, wrong geometry/target and action before touch.

## Original commit validation results (2f6ff95)

- `python3 scripts/test-voice-call-harness.py`: **8 tests passed**. Apple tools
  and asset preparation are stubbed; no image files are opened by this run.
- `python3 scripts/test-soul-tap-evidence.py`: **4 tests passed**. The unchanged
  gate also reproduces #676's exact missing-`avatar.action` error on the original
  JSON (an expected rejection, not a post-fix trace).
- Additional temporary shell experiments, using the existing Apple-tool stubs
  with a six-second overall execution deadline and an eight-second stall at
  assets, test, or export: **all three return 124**, including export after a
  successful test. Production script and test/fixture files were not shortened.
  An initial two-second experiment exhausted the pool before reaching the test
  stage; it also returned 124, then was rerun with enough setup time to exercise
  each intended stage.
- Python compile checks for both test files, evidence gate, bounded runner and
  simulator selector: passed. `bash -n scripts/test-voice-call-ui.sh`: passed.
- Byte preservation checks described above and byte-identical xcodebuild test
  invocation: passed.
- Provider chrome source-only extraction: passed. Stopped before catalog/asset
  copy/hash operations; no image read or visual review.
- `git diff --check`: passed.
- Real Swift compilation, avatar action/presentation, glass rendering and voice
  simulator execution: unavailable locally; CI must evaluate the unchanged
  assertions and evidence gate. Text evidence proves the pre-fix failure, not
  a post-fix iOS success.

## Audit revision note (2026-11-16)

Addressed the SDK capture defect, mechanism overclaims/omitted interactions,
and budget wording from audit findings 4, 2, and 1/3 respectively. The bounded
SDK stage redirects only xcrun stdout to a separate file; its stripped value
is passed to swiftc, while multiline stderr diagnostics stay in `sdk-path.log`.
The shared pool remains 504s plus a 6s termination reserve, nominally 510s,
without a per-stage 3x or strict whole-script wall-clock promise. Final console
log output is capped at the last 64 KiB; full logs remain available.

Validation of this revision:

- `python3 -B scripts/test-voice-call-harness.py`: **9 tests passed**, including
  the new multiline SDK stderr warning/trimmed stdout case. The same new test
  rejects the original SDK capture (expected assertion failure in an isolated
  temporary script). All eight existing tests and helpers are byte-identical;
  the stub extension serves only the added regression case.
- `python3 -B scripts/test-soul-tap-evidence.py`: **4 tests passed**. Both original
  legacy and review26 JSON traces still fail the unchanged gate with exactly
  `Missing production event after actual avatar touch: avatar.action`, as
  expected. No post-change iOS success is claimed.
- `bash -n scripts/test-voice-call-ui.sh` and Python syntax compilation of the
  voice harness tests, evidence tests/gate, bounded runner and simulator
  selector: **passed**.
- Log-tail smoke check: **passed**; a 100005-byte log is retained in full,
  exactly 65536 ASCII bytes are printed, and exit status 65 is preserved.
- Byte comparisons against `2f6ff95`: **passed**. Entire `AIChatView.swift`
  (including the production fix, DEBUG trace, header mount/containment and
  `ChatHeaderHitRouting`) is unchanged. The shell from `voice_run compile`
  through test/export/exit is byte-identical, including the xcodebuild test
  invocation, assertions and timing. The shared-pool implementation is also
  byte-identical. Only this document, the shell SDK capture/comments, runner
  log tail and harness regression addition change; all other checks, tests
  and fixtures are unchanged.
- `python3 -B scripts/test-voice-call-chat-bridge.py`: **skipped** by its existing
  macOS swiftc availability check; real Swift/iOS execution remains for CI.
- `git diff --check`: **passed**.

No workflow file was edited and no image file was opened or viewed. This
revision is one new local commit on top of `2f6ff95`, without amending or pushing.
The avatar mechanism remains a targeted hypothesis; the verdict requires the
real action/request/appearance chain to pass the unchanged CI trace gate.
