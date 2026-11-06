# iOS 18.4/18.5 simulator WebKit overlay launch failure

Actual application verification run `42194654594` aborted in dyld before main:
`Library not loaded: /usr/lib/swift/libswiftWebKit.dylib` on the iOS 18.5
simulator. The share/search harness had not started; no verification directory
was produced. The complete Debug application had compiled successfully.

Apple/WebKit identifies this exact runtime packaging defect in
[bug 293831](https://bugs.webkit.org/show_bug.cgi?id=293831), workaround comment 2,
and fixes it in [WebKit PR 46146](https://github.com/WebKit/WebKit/pull/46146),
commit `d53b778e73acdce8bd1e707cbd0908eb4584d67b` (also Apple/WebKit PR3150).
The legacy Swift overlay became a symlink to WebKit under the OS Cryptex path.
Device dyld shared caches record that alias; the affected simulator has no
prebuilt shared cache and was missing the additional root `/usr/lib/swift` link.

The official workaround preserves the deployment target and binary: add the
affected runtime's `System/Cryptexes/OS/usr/lib/swift` directory to
`DYLD_FALLBACK_LIBRARY_PATH` for the simulator launch. The project already sets
`ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=YES`; changing that does not repair this
runtime symlink. Weak-linking the overlay is inappropriate here: actual
`WKWebView.callAsyncJavaScript` calls need its symbols, so making the library
optional could turn a missing-library abort into an unresolved-symbol failure.

`scripts/simulator-webkit-environment.py` resolves the runtime from the **selected
device UDID**, limits the workaround to versions 18.4/18.5, and outputs a fallback
only when the normal library is missing and that same runtime's Cryptex library
exists. It never copies a library from another runtime, changes system files,
patches Mach-O, weakens linking, raises the deployment target or affects a device
build. Other missing libraries continue to fail normally.

```sh
fallback=$(python3 scripts/simulator-webkit-environment.py "$device" \
  --app "$app" --output "$evidence/webkit-runtime")
# Pass only to simctl's child environment when nonempty:
SIMCTL_CHILD_DYLD_FALLBACK_LIBRARY_PATH="$fallback" xcrun simctl launch ...
```

The helper records runtime metadata, exact fallback and official source in
`webkit-runtime.json`, and `xcrun otool -l/-L` for the actual app executable
(and a debug dylib when present). The binary commands alone prove dependency
shape; successful real simulator launch/verification remains required.

The upstream source explains why this particular missing-alias defect affects
the simulator rather than device shared caches. That is not a new claim that
every supported real device has been tested. Release linking and iOS16 minimum
remain unchanged; installed-device regression is a separate gate.

Local deterministic helper checks passed for missing files, matching Cryptex
fallback, fixed-runtime bypass, nonaffected-version bypass, and exact
device-to-runtime resolution. Actual macOS dependency output and launch are
produced in the next CI run.
