# Chat entry crash investigation — 2026-11-06

## Device evidence

The supplied `Ze-2026-11-06-191658.ips` is preserved outside the repository.
SHA-256: `4558bb6a92e59dd26b0ee9d644068fee95a16e9b47f859c0149f3a640e3bc6ab`.
Installed build: Actions `42203569548`, commit
`78b878d5001418f459d1d2bfe904bb417b07578f`, version 1.1.4 (8).
The run's device build/package job succeeded; its application export check failed.
A successful packaging job did not establish that a chat page could open.

Device: iPhone15,4, iOS 18.1 (22B83). Exception: EXC_BAD_ACCESS / SIGSEGV,
KERN_PROTECTION_FAILURE at 0x16b28ff78, inside thread 0's STACK GUARD.
The adjacent main-thread stack is 1008 KiB. The symbolicated stack includes:

```
0  libswiftCore SubstGenericParametersFromMetadata::buildDescriptorPath
10 libswiftCore _checkGenericRequirements
15–31 libswiftCore decodeMangledType / decodeGenericArgs
37 Ze __swift_instantiateConcreteTypeFromMangledName
38 Ze closure #1 in AIChatView.inputBottomRow.getter +808
42 Ze AIChatView.inputBottomRow.getter +252
55 Ze AIChatView.inputBar.getter +632
70 Ze AIChatView.body.getter +7704
```

Confirmed: the main thread exhausts its stack while materializing Swift view
metadata on chat entry. The user also reports the same symptom opening history;
there is one supplied crash report, not a second independently symbolicated report.
Both routes instantiate the same composer. There is no evidence here that PDF
export, native-kernel execution or a search-state feedback loop caused the crash.

## Repair

- Erase opaque composer controls before HStack constructs its tuple metadata.
  The existing `AnyView(row)` only erased the already-constructed row.
- Separate composer chrome from its geometry/gesture modifiers with an actual
  `AnyView` return boundary, and erase the complete input bar before parent layout.
- Divide the chat body into erased layout, navigation, presentation, media and
  lifecycle groups. Returning `some View` from extracted getters alone would
  continue exposing their nested concrete types to parent view construction.
- Preserve control actions, state ownership, layout values, modifier ordering,
  availability branches and the existing toolbar equality gate.

These changes use AnyView, available before iOS 16. The application Debug and
Release deployment targets remain 16.0. CI checks the simulator app's
MinimumOSVersion and the device IPA's Info.plist and Mach-O minimum OS.
The existing test targets' 26.2 settings and live-activity extension's 16.2 target
are separate from the main application's deployment target.

## Acceptance and limits

The application regression must mount the real ContentView and AIChatView,
including the composer; search-model and collection-only tests are insufficient.
Exercise a fresh new chat, saved history, replacement by another new chat, and
return/reopen. Save screenshots, visible composer/history assertions and runtime
version. Run the new lifecycle case before sharing/search checks.

Windows static checks do not prove Swift compilation or runtime behavior.
A simulator pass on a newer iOS runtime does not establish iOS 16 or physical
iOS 18.1 acceptance. Device reinstallation and both entry paths remain the final
confirmation for the reported phone.

PDF glyph extraction remains a separate failing acceptance item until its real
PDFKit checks pass. Its test stays mandatory before IPA packaging; placing it
after compilation lets compiler evidence be produced even when export fails.

IPA upload additionally requires the same Actions run's complete application
runtime job to finish successfully. A compiled package from a run with failed
chat, share or search assertions is not offered as a downloadable IPA.

## First repair build: b5a0e98

Actions 42212609421 failed simulator compilation at AIChatView.swift:995:
`the compiler is unable to type-check this expression in reasonable time`.
The media presentation expression still combined many modifiers. No new-chat
runtime result was produced. Split that expression into six erased groups
(image events, file previews, browser previews, session sheets, capture and
photo/document picking), preserving the exact concatenated modifier content.
This is a compile repair, not evidence of device crash resolution.
