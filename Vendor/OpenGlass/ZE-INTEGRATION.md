# Ze integration

Upstream: https://github.com/mi11ione/OpenGlass
Revision: 62b84ac9c4907056a8abc7337e1785653a7da889 (MIT; LICENSE retained).

Vendored for reproducible builds. Swift tools 6.0 / Swift 5 language mode allows the same sources to build with Xcode 16.4 for iOS 18 verification and Xcode 26 for the shipping app. No upstream 6.2-only language feature is used.

Ze uses OpenGlassView as a noninteractive background only. SwiftUI owns live buttons, video and accessibility; the library's content rasterization / hidden content physics path is not used. Circle/capsule radius updates with layout. Native iOS 26 uses Apple's glassEffect.

Local changes: shared render loop capped at 30 fps; inactive applications skip rendering; last unregister clears retained source groups and excluded layers in addition to upstream texture cleanup. Upstream texture caches have a 32 MiB eviction threshold. Reduced transparency and inactive scenes use the static material / solid fallback.

Device crash regression (iOS 18.1, 2026-11-15 22:57): UIKit layout can synchronously unregister every surface during `_renderFrame`. Disposal now defers element/group/cache destruction until after the frame, nested ticks are ignored, and a lens reattached during that layout restores weak-set registration. Frame snapshots are released after submission instead of retaining view trees between frames.
