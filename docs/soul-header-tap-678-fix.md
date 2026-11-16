# Run #678: cancelled native-glass avatar touch and provider badge discovery

## Evidence and scope

Starting HEAD: `c74416956df76e7e0e6f9fb3451c26786dabac0f`. Solo review and fix;
no delegated review, push, image/binary inspection, or voice harness changes.
Artifact paths below are relative to
`/home/hatch/workspace/goals/iex-run/hidden_files/43803492432/`.

Read both `legacy2/chat-layout-evidence/chat-verification/avatar-tap-events.json`
and `review26/chat-layout-evidence/chat-verification/avatar-tap-events.json`
in full, including every controller, containing view, gesture and subsequent
touch. Repeated structures were compared by field and array index. Also read
both summaries, result metadata, review26 test.log, the provider section of
build-job.log, provider-interface-review/provider-chrome-evidence's result,
progress and source manifest, and the earlier #674/#676 investigation documents.
Source-manifest SHA-256 values for AIChatView.swift and the provider harness
match the starting checkout. No screenshot or asset was opened or hashed.

## Tap diagnosis before editing

**PROVES:** #678 iOS 18 succeeds through the actual production action and
settings presentation. Its 22 rows contain two observer installations, one
avatar touch, action/request/binding/appearance events, a later dispatch
snapshot, settings dismissal and three later, non-avatar touch pairs.
The avatar touch (sequence 3–6, ID `0x000000010e7efe10`) is at
`(201, 84.33332824707031)` in the 56-point circle at
`(173, 56.33333333333334)`. Both the window and badge observe began/ended;
the action is sequence 7, request 8, binding true 9, appeared 10, Done appeared
11. The summary is success=true; the independent in-app verifier passes 243
checks. Later touches are outside the circle and must not be mistaken for
additional avatar attempts.

**PROVES:** #678 iOS 26 has six rows: observer installations 1/2, window began
3, badge began 4, window cancelled 5 and badge cancelled 6. ID
`0x000000016f4bda40` stays the same; the point stays `(201, 90)`, the center
of the circle `(173, 62, 56, 56)`. At began it is delivered into the badge's
`_UIHostingView<AnyView>`. At cancellation `touch.view` is absent, hence the
empty delivered path/gesture list and false deliveredIntoBadge; this does
not erase the successful initial delivery. There is no ended, action,
request or appearance row. The unchanged gate reports
`Missing production event after actual avatar touch: avatar.action`.
ShareDriver.swift:62 fails the real Done query; 236 independent in-app checks
pass. No action-followed-by-presentation failure is observed.

### Working iOS 18 versus failing iOS 26

| Stack / state | iOS 18 | iOS 26 |
| --- | --- | --- |
| Delivered ancestry at began | Badge hosting view → root hosting view → UIDropShadowView → UITransitionView → UIWindow | Identical types and order |
| Controller list at began | 11 entries, no presented controller; one inactive NavigationStack host | Identical types, order, presentation and viewInWindow flags |
| Geometry | Badge 200×112; label 56×56; animation 52×52 with 2pt padding | Same sizes; label is 5.6667pt lower |
| Overlapping representable hosts | Layout marker, glass marker, tap marker and animation hosts report UIKit interaction=true; returned UIViews false | Same, with UIKitPlatformViewHost names replacing PlatformViewHost |
| Glass overlap | Legacy refractive host/OpenGlassView; OpenGlassView false; shape hit view false | UIPlatformGlassInteractionView true; three full-size inherited views true, two false; inset inherited view false |
| Shared ancestry gestures | Hover, observer, two duration, simple press, secondary click, two relationship recognizers on badge; root hover; two window system gates | Same types/counts |
| Extra window gestures | None at avatar touch | One UITapGestureRecognizer and four enabled flex pan recognizers |
| Began gesture changes | Secondary click and one system gate fail (5) | Three flex pans fail (5); fourth begins (1); other recognizers stay possible (0) |
| Completion | Window ended then badge ended; one duration and one relationship recognizer fail; action follows | Window cancelled then badge cancelled, with no target or gesture list |

`viewsAtTouchInBadge` is geometric overlap, not delivered ancestry or a
SwiftUI hit/gesture decision log. A true UIKit flag on a platform host does
not override the meaning of its SwiftUI `.allowsHitTesting(false)`: the
working legacy stack is a direct counterexample to that inference.

**HYPOTHESIS:** native glass interaction participates in cancelling this
short avatar touch. The OS-specific glass interaction view plus the flex pan
entering began before cancellation support investigating that interaction.
They do not identify the recognizer's owner, prevention dependencies or
which callback cancelled the touch. Context-menu/framework arbitration is
also unresolved. A mechanism without direct evidence is a suspect, not a
fix. These artifacts cannot decide the private cancellation mechanism.
There is no supporting evidence for changing root containment, window hit
routing, the action or sheet presentation.

### Complete avatar interaction participants and writers

Line references in this section refer to the starting HEAD. Literal label
descendants are distinguished from modifiers wrapping the Button and from
ancestor infrastructure. Searches covered the relevant type references,
extensions, UIView constructors/updates, interaction setters, gestures,
targets, interactions and touch overrides in Swift/Objective-C sources.
There are no additional app writers on these avatar descendants.

| Participant | Every app creator/configurer and interaction writer |
| --- | --- |
| Avatar Button, label ZStack and Circle hit shapes | AIChatView.swift:2198–2230 constructs the enabled Button, ZStack, label-local Circle and outer Circle. Only its production action opens Soul settings. No extra tap recognizer or disabled modifier. |
| SoulHeaderAvatar / surface / Group / frame / padding | AIChatView.swift:2212 creates the avatar and excludes its whole visual subtree from SwiftUI hit testing. SoulStore.swift:676–742 creates the stable surface, chooses custom/animation, applies 2pt animation padding and the square size. Message/block notifications update revision; metadata notification updates image/emoji; scene/reduce-motion update playback; celebration task sets/clears celebrating. None enables interaction or installs a gesture. |
| Custom image, emoji, empty-emoji fallback image | SoulStore.swift:575–615 builds Image(uiImage:), Text or Image("ZeAssistantAvatar"), sizing/clip/AX metadata. onAppear/onReceive reload metadata only. All inherit the call-site hit exclusion; no UIKit interaction writer or gesture. Surface normally chooses animation for the empty fallback. |
| Animation representable host | SoulStore.swift:745–752 supplies make/update/dismantle. SwiftUI creates/configures UIKitPlatformViewHost; app code does not set its UIKit flag. It inherits the visual hit exclusion. |
| SoulAvatarAnimationView | makeUIView constructs it; init at SoulStore.swift:801–811 is the sole interaction writer, setting false. update calls configure(motion:playing:); dismantle stops it. No gestures, UIInteractions, targets or touch overrides. Layout/window/trait callbacks manage layers/playback only. |
| UIImageView fallback and AVPlayer layers | SoulStore.swift:785/807 creates/adds the UIImageView, whose default is noninteractive and has no interaction setter. Trace confirms false and hidden. Clip init at 765–774 creates queue player/looper/layer; readiness/reveal/layout/dispose write opacity, geometry and player state, never UIView interaction. Layers are not independent hit targets. |
| DEBUG tap-frame marker and host | AIChatView.swift:2219 constructs ChatSoulTapTargetMarker and excludes its host. makeUIView at 5118–5124 constructs UIView, writes false and registers the weak evidence target; update is empty. Framework creates/configures the host, which still reports true in both traces. No marker gesture. |
| ButtonStyle | AIChatView.swift:2225 applies ChatHeaderButtonStyle; 4873–4887 returns label on iOS 26. Legacy branch adds an excluded pressed overlay and scale/animation. It reads isPressed and installs no separate handler. |
| Native glass, wrapping rather than inside the literal label | AIChatView.swift:2227 applies ChatNavigationGlassSurface. Its body at 4792/4795 configures `.regular.interactive()` for circle/capsule; compiler and availability gates select this path. These are the only native-interaction configuration writers; the runtime owns UIPlatformGlassInteractionView and its recognizers. The other modifier callers are leading circle at 805, trailing capsule at 817 and provider capsule at 2248. |
| Native/fallback branch marker and host | The four background sites at 4794/4797/4811/4814 construct ChatNativeGlassMarker and exclude SwiftUI hits. makeUIView at 4892–4901 constructs UIView and writes false; DEBUG only sets identifier; update is empty. The runtime owns the host's true flag. Marker is decorative, not a gesture owner. |
| Context menu surrounding avatar | AIChatView.swift:2231–2238 installs contextMenu; when titlePillSession exists it constructs Edit Session Button, whose action sets titlePillEditSession. This is a real independent long-press/secondary-click interaction. SwiftUI creates its infrastructure; app does not configure private portal/relationship recognizers. |
| PortalGroupMarkerView and inherited views | All are framework-created. In the native trace, the full-size portal reports true; full-size inherited indices 4/11 false and 7/8/10 true, inset index 14 false (zero-based viewsAtTouchInBadge). No app class, extension, constructor, setter or recognizer installer exists for these private types. Their exact association with glass/context-menu internals is not exposed. |
| Legacy-only background (comparison closure) | ChatLegacyGlassSurface at 4821–4850 chooses accessibility solid fill, active Metal lens, or material/colors/gradient, then stroke/shadow. Whole background excludes hits. ChatLegacyRefractiveGlass makeUIView at 4855 creates OpenGlassView(.clear), writes interaction=false and hides AX; update sets configuration with physicsMode=.none. GlassConfiguration.swift:21 defaults physics to none; OpenGlassView.swift:118 gates automatic gesture installation; installGestures at 126–142 would install press/pan, but is not reached on this path. Alternative vendor wrapper representables call installGestures but are not instantiated here. |

Ancestor/sibling participants, also audited:

* Badge UIHostingController is created/configured in updateBadge at
  AIChatView.swift:5301–5327, reused by replacing rootView, mounted under
  the window root at 5407–5430, and removed by nil/restore. Its hosting view
  intentionally owns SwiftUI gestures. HeaderHitRouting installs/removes
  scoped window routing; it does not install a tap recognizer. These remain
  unchanged.
* ChatCallLayoutMarker at 2106/5668–5682 constructs the whole-badge geometry
  UIView and writes false. Its framework host reports true in both traces.
  It is outside the avatar label and has no gesture/update writer.
* DEBUG ChatSoulTouchObserver is created/added at 4964–4970, configured not
  to delay/cancel touches, cannot prevent/be prevented, and only records
  before failing on ended/cancelled (5091–5106). Window sendEvent hook
  forwards once. Both remain unchanged. No application code installs the
  window flex pans, extra native tap, or shared UIKit press/relationship/
  duration/hover/system-gate recognizers. Trace identifies classes/states,
  not their private creators or dependencies.

## Provider diagnosis before editing

**PROVES:** step 21 reports 149 passed checks and exactly the two named
failures. It did not produce an IPA. The fixture's check helper records
failures and continues; passing later checks do not negate either failure.

The literal assertion contract is in scripts/ProviderChatChromeHarness.swift:

* Lines 228–231: providerBadgeView searches immediate window-root subviews
  for `next is UIHostingController<AnyView>` AND bounds.width == 24 AND
  bounds.height == 24. This is stricter than merely finding a hosting child.
* Lines 523–546: real UINavigationController/owner/appearance controller are
  placed inside a plain UIViewController window root, matching production
  containment; diagnostics explicitly report topIsOwner=true.
* Lines 594–599: updateBadge without headerSize, apply and layout, then
  require nonnil badge AND unchanged navigation owner. This fails.
* Lines 606–615: collapse removes; expand recreates through the same nil
  headerSize path. Requiring nonnil again fails.
* Lines 616–620: reuse compares the two optional lookup results by identity;
  nil/nil passes, so this does not prove a discoverable host was reused.
  Collapse/restore likewise pass when the lookup is already nil.
* Lines 638–658: explicit 160×56 headerSize, then direct lookup through
  root.children succeeds and controller parent/view superview/top owner/
  routing checks pass. This is a different size and discovery predicate.

Production writers: updateBadge (AIChatView.swift:5301–5327) records the
optional headerSize and creates/reuses/clears the UIHostingController.
layoutFrostedOverlay at 5371–5378 selects either explicit header bounds or
the fallback 24×24 CGRect. At 5413 it converts the entire rectangle from the
bar container to root coordinates, then at 5429 assigns that converted frame.
The 24-point NavigationStatusCapsule label is constructed at 5496–5514.
applyIfNeeded's fast path still calls layoutHeader (5438–5443). Neither
collapse nor expand bypasses layout. No production navigation push occurs
in this path. Other passing checks assert the owner remains top.

The root-host migration and stricter discovery helper were introduced by
`c097d4d`, not `c7441695`. A byte comparison of the production chrome slice
actually extracted by scripts/extract-provider-chat-chrome.py gives the
same SHA-256 at c7441695 and its parent 3017d07:
`7bc497a12e45fe15a504066d5240dd387a7ab3c7dea0c491421298aab6f30fce`.
The fixture deliberately drops the glass modifier/style/markers and does not
instantiate titleView. Thus **PROVES:** the round-6 avatar changes did not
change this extracted provider implementation; claiming they caused these
two failures would contradict the source evidence. This is a latent contract
failure exposed when this run reached step 21. #676 stopped earlier.

**HYPOTHESIS:** converting a complete CGRect perturbs the fallback's exact
24-point size through floating-point edge subtraction. That can make both
nonnil lookups fail while the null/removal/reuse checks pass. The source
allows this loss: it propagates the converted size even though only position
needs conversion for this fixed-size mark. A scalar example is
`(118.66666666666667 + 24) - 118.66666666666667` yields
`24.000000000000014`, not 24.
However, the artifacts contain neither the small host's raw bounds nor its
next responder; they do not distinguish size drift, responder-chain mismatch
or transient detachment at these exact checks. The exact runtime producer
of nil is not proven. The larger header's success cannot settle it.

The minimal intervention is to preserve the fallback's declared local size
after converting its position. This addresses the concrete size-contract
hazard without changing discovery/assertions, root ownership, containment,
hit routing, or the full-size production header. It is not a claim to have
observed a bad raw size or proven the two runtime failures repaired.

## Changes and verification boundary

1. Give native glass an interaction option defaulting to true; opt only the
   avatar out. Keep the regular glass appearance and production SwiftUI
   Button, circular label, visual exclusions and context menu. No private
   recognizer manipulation. This is a targeted cancellation hypothesis.
2. Preserve 24×24 size only for the nil-headerSize badge fallback after the
   existing coordinate conversion. Root mount/controller/view containment,
   z order and window hit routing stay intact; explicit headerSize behavior
   stays identical.

Linux has neither swiftc nor xcrun; passing text suites cannot prove an iOS
tap or provider runtime repair.

## Local verification results

* `python3 -B scripts/test-voice-call-harness.py`: **9 tests passed**. Apple
  operations/asset preparation are stubbed. Voice source, scripts, tests and
  budgets are unchanged; no real voice UI run was attempted.
* `python3 -B scripts/test-soul-tap-evidence.py`: **4 tests passed**.
* Replayed both full original #678 traces through the unchanged gate:
  legacy2 **accepted**, review26 **rejected** with the exact missing-action
  error. This verifies evidence interpretation, not the new production code.
* Byte comparisons against starting HEAD: production Button action and order,
  round-6 label fix, material fallback/style/markers, DEBUG observer/window
  routing, host creation, containment/z-order/removal and remaining provider
  chrome all **unchanged**. Every tracked file except AIChatView.swift is
  unchanged; this document is new. In particular the entire provider harness,
  extractor and shell, full-app XCTest (the ShareDriver source), in-app
  verifier, tap gate, SoulStore and voice harness are byte-identical.
* Source-only execution of the original provider extractor through Swift
  assembly: **passed**; new fallback size assignment is included, glass
  modifier is excluded. Stopped before catalog/asset/plist binary operations.
* Python syntax checks for the two local suites and evidence gate: **passed**.
* `git diff --check`: **passed**.
* Real iOS 18/26 compilation, actual touch/appearance verification, provider
  fixture execution and rendering: **not run**, Apple tools unavailable.

## Final diagnosis, changes and guarding assertions

**PROVES:** iOS 18's real tap/action/presentation chain succeeds. iOS 26's
center touch reaches the badge, a native-only flex pan begins, and that touch
is cancelled before action. The provider fixture fails its two positive
24×24-host discovery checks while separate ownership/routing checks pass.
The round-6 commit did not change its extracted production implementation.

**HYPOTHESIS:** native glass interaction causes the cancellation; fallback
CGRect size drift causes the provider lookup failures. Neither private
cancellation causality nor the failing small host's actual bounds/responder
is recorded. These remain suspects. This commit implements a narrowly
targeted native-glass interaction opt-out for the avatar and preserves exact
fallback dimensions; it does not claim either runtime mechanism or repair
has been proven. The iOS 18 label fix is retained. The window-root mount,
controller ownership, routing, production action statements/order and every
existing test/assertion/gate are unchanged. Only fallback frame sizing is
adjusted inside the existing layout block, under headerSize == nil.

The following unchanged verification assertions guard every touched area:

| Area | Assertions that must still pass |
| --- | --- |
| Actual avatar action / settings | ShareDriver's actual Button exists, center-coordinate tap opens the real Done Button within the original 5s, then taps Done. Trace gate requires exactly one center touch, initial badge delivery, matching observer touch identity, action after touch, true request after action, settings/Done appearances after request (either appearance order); all missing-link/geometry/target/pre-touch-action rejection tests remain. |
| Native glass option / other controls | In-app verifier requires at least four actual native/fallback branch markers and no visible opposite branch. Other glass call sites retain default interaction=true; avatar still has a regular circle surface. Existing window-hit checks require avatar/provider hits inside badge, leading/trailing hits inside native bar and exactly equal to native targets. The actual-tap gate, not marker existence, decides whether disabling avatar glass interaction helped. |
| iOS 18 rendering / label | Four real Metal lenses, safe unregister/re-register, every lens submits new frames, capsule refraction changes pixels in at least three samples. Legacy fallback/style and label exclusion/Circle are byte-identical. Size 40/80 checks require animation width size−4, avatar in viewport, keyboard focus success and avatar midY movement <1pt through keyboard phases. |
| Avatar playback / activity | Existing motion/theme asset, ready display and time>0.05 checks; stable view keeps advancing across token updates; celebration expires within 8s and stays expired after foreground; activity text/tools/pending-question/provider restoration; one view/player after cycles and footprint growth <32MiB. No SoulStore or action changes. |
| Provider fallback's exact size / lookup | Fixture requires each rendered provider mark square and 24pt; mounting requires a root-hosting view with exact 24×24 bounds and top===owner; conditional mounted hit must land in badge; collapse requires nil with same owner; expand requires nonnil; provider switch compares identity with same owner; restore requires nil and same owner. These predicates and their execution order are byte-identical. |
| Full header geometry / root mount / routing | Explicit 160×56 fixture requires actual host parent===root, superview===root.view, top===owner; scoped routing active; intercepted hit forwarded to badge; exact leading/trailing targets; outside content and unrelated windows unchanged; sheet wins; pushed picker owns navigation and disables routing; pop restores routing; nil disables routing; restore removes routing and restores native hits/owner. Explicit-header frame conversion is unchanged. |
| Provider chrome / lifecycle | Separator absent, native background clear, noninteractive gradient below bar without blur or unrelated page masks, gradient ends at toolbar centerline with alpha 1→0, live light/dark/light preserves frost/owner, unrelated appearance unchanged; restore removes frost and restores prior appearance; both toggle callbacks; nonblank galleries/navbar, visible provider pixels, actual scrolling and viewport behind navigation. Frost and appearance code are byte-identical. |
