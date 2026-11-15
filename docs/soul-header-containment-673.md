# Run #673: header containment probe

Candidate (c), the immediate-responder lookup, is the source-supported failure.
`(badge.next as? UIViewController)?.parent` does **not** necessarily read the
badge host's parent. Its `"nil"` diagnostic also represents a failed cast.
There is no app-source path that installs this badge view without first
parenting its controller. The fix measures actual UIKit containment, with the
same immediate probe and the same required root ownership.

## Evidence and its limits

Both artifacts under `43747410581/{legacy,review26}` report 46 successful checks
and then the combined structural assertion failure at `avatar-size-40.0`.
All four window hit probes and both native navigation target comparisons pass.
The badge is `_UIHostingView<AnyView>` directly below
`_UIHostingView<ModifiedContent<AnyView, RootModifier>>`, above the window's
`UIDropShadowView` / `UITransitionView` ancestors, on iOS 18.5 and 26.4.1.
The source-manifest hashes match the starting production header and XCTest.

The larger hosting view is the root controller's view in the app's install
path: the sole badge insertion target is literally
`navigation.view.window?.rootViewController?.view`. It is not an extra overlay
container below that view. The old JSON did not record object identity or the
type of `badge.next`; it cannot independently establish either identity or
that the *actual host* had a nil parent. In particular, it cannot establish
which private responder class occupied the immediate next slot in #673.

`next` belongs to the responder chain, not the containment hierarchy. The
existing `nearestViewController` helper in `AIChatView.swift` already walks
that chain rather than assuming the first responder is a controller. As
supporting framework-source context, OpenSwiftUI's reconstruction explicitly
returns an event bridge's `UIKitKeyPressResponder` ahead of the default next
responder when its hosting view enters a window:

- [_UIHostingView.next](https://github.com/OpenSwiftUIProject/OpenSwiftUI/blob/808ef19d5658a05ebbdfd60fe431d7559e8bc9cf/Sources/OpenSwiftUI/Integration/Hosting/UIKit/View/UIHostingView.swift#L603)
- [UIKitEventBindingBridge.hostingView](https://github.com/OpenSwiftUIProject/OpenSwiftUI/blob/808ef19d5658a05ebbdfd60fe431d7559e8bc9cf/Sources/OpenSwiftUI/Event/Platform/UIKit/UIKitEventBindingBridge.swift#L43)

That reconstruction explains the invalid assumption; it is not a runtime
trace of Apple's implementation in #673. The new responder-path diagnostic
will expose the actual chain alongside the independently resolved controller.

## Complete app-source lifecycle inventory

The owner is `ChatNavigationBarAppearance.Controller` (not a Coordinator).
`badgeHost` is private; all its writers and containment operations are in
`AIChatView.swift`:

| Operation | Complete set of paths at c097d4d1 |
| --- | --- |
| Create / assign | `updateBadge`: constructs `UIHostingController<AnyView>` only when `badgeHost == nil`, then assigns it. It loads/configures its view but never inserts it. |
| Reuse | `updateBadge`: swaps `badgeHost.rootView` when a host exists; no app containment change. |
| Clear | `updateBadge(nil)`: removes routing, calls `willMove(nil)`, removes the view, removes the controller from its parent, then sets `badgeHost = nil`. |
| Parent / install | Only `layoutFrostedOverlay`: if the parent differs, removes the old view and parent, calls `root.addChild`, adds the view to `root.view`, then calls `didMove(root)`. If the parent already matches but the superview differs, adds the view to `root.view` with containment already correct. |
| Detach without clearing | Only `restore`: removes routing, calls `willMove(nil)`, removes the view, removes the parent, and removes the frost. It retains `badgeHost` for reuse. |

All callers and timing:

- The sole production `updateBadge` caller is
  `updateUIViewController`. It immediately calls `applyIfNeeded` in the same
  synchronous invocation. Production's `NavBarStyleModifier` always receives
  `AnyView(chatNavPrincipalContent)`; it never conditionally sends nil. The
  `@AppStorage` size setting feeds `chatHeaderSize` and `titleView`, not a
  collapse/expand switch.
- `applyIfNeeded` also runs from `viewWillAppear` and `viewDidAppear`. Its
  early guards require a navigation controller and the chat to be topmost.
  The already-installed appearance branch **still calls** `layoutHeader`.
  The changed-item branch calls `restore`, installs appearances, then calls
  `layoutHeader` synchronously; there is no deferred reinstallation there.
- `viewDidLayoutSubviews` calls `layoutHeader` when navigation and `item`
  exist. These and `applyIfNeeded` are the only `layoutHeader` callers;
  `layoutHeader` is the only `layoutFrostedOverlay` caller.
- `layoutFrostedOverlay` returns if the bar has no superview. Its badge block
  requires a host, a window root, and a root different from navigation. Frame
  caching gates only frost/frame assignments, never badge installation.
  The async inset/overflow callbacks update SwiftUI state; they neither detach
  nor install the badge.
- `restore` runs on changed navigation item, `viewWillDisappear`, and
  representable dismantling. Every detach removes the view before unparenting.
- Outside the app, `ProviderChatChromeHarness.swift` directly invokes
  `updateBadge` at lines 591, 594, 610, 617, 638, 703, and 706, covering nil,
  expand, provider replacement, and hit-routing fixtures. Each nonnil call is
  immediately followed by `applyIfNeeded`. Its direct restore calls are at
  621 and 709. This separate synthetic application is not the #673 verifier.
- The size-loop verifier sets defaults, awaits the avatar width, then probes
  immediately, before requesting keyboard focus. It probes again after focus
  and a 0.6-second settle; the third call site is just before the external
  coordinate-tap stage after a 0.5-second settle. Only the first size probe was
  reached in #673. Width readiness proves rendering, not responder type.

Thus (a)'s production nil/recreate sequence has no caller, and even an initial
unparented host waiting for layout has **no installed view**. (b)'s restore
cannot leave a view installed while unparented. At installation, parenting
precedes `addSubview`, including the synchronous callbacks caused by insertion;
at removal, view detachment precedes unparenting. No source evidence supports
changing production containment or pumping a later layout to conceal this
measurement failure.

## Corrected measurement

The verifier finds a direct root child whose `viewIfLoaded === badge` and
still requires both `badge.superview === root.view` and that controller's
`parent === root`. An orphan, a host under another controller, a root child
owning a different view, or an intervening superview all fail. This does not
substitute an ancestor controller or infer ownership from pixels or hit tests.
All functional hit assertions, the routing assertion, XCTest, production
hosting, and `ChatHeaderHitRouting` remain unchanged. There is no added wait,
layout pump, or repair before the structural check.

Each JSON entry now records `badgeSuperviewIsRootView`, the actual matching
controller and its parent, the responder chain, and the original immediate
responder's parent read under a separate name. Future evidence can distinguish
an ownership defect from responder indirection without this ambiguity.

## Local validation

`git diff --check`, avatar asset validation (all nine assets), and production
chrome extraction pass. Artifact source hashes match c097d4d1 in both runtimes.
Reviewing all 67 `require` calls confirms only the controller lookup changed;
the production header and XCTest have identical contents. This Linux workspace
has neither Xcode nor an iOS simulator, so the corrected probe has not been run
on iOS locally; the added diagnostics remain to be observed in the next CI run.
