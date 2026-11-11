# Chat progressive blur

Based on nikstar/VariableBlur commit 5073a0d9080e488a2d317e04859c001a57fbb3e8, Sources/VariableBlur/VariableBlur.swift, MIT license in variable-blur-LICENSE.md.
Source: https://github.com/nikstar/VariableBlur/blob/5073a0d9080e488a2d317e04859c001a57fbb3e8/Sources/VariableBlur/VariableBlur.swift

The gradient is inputMaskImage for the live backdrop variableBlur filter, not an alpha mask over systemMaterial. UIKit tint subviews are hidden as in the upstream implementation. Max radius14; gradient from44pt above navigation bottom to18pt below it. Existing24pt overlay extent and badge layout retained.

CAFilter, variableBlur and the backdrop scale key are non-public APIs. No App Store acceptance or future OS guarantee is claimed. Availability is checked dynamically; missing factory/backdrop uses UIKit fallback. No forced casts or image unwraps. Upstream warns super.traitCollectionDidChange can crash with its custom filter; it is only invoked for the standard-material fallback. Reduce Transparency uses an opaque background.

Verification must include actual reference-like white text, dark image backgrounds, scroll, navigation restoration, and theme changes. Fixture screenshots do not establish physical-device behavior.
