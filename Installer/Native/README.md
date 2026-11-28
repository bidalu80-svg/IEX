# Native connection integration guard

Source: jkcoxson/idevice 0.1.68, commit
`c8fff6d7fb2690eaeb591ce510754effa7b1e19b`, MIT. The copied source subset,
original hashes and local patches are listed in `upstream/manifest.json`.
That provenance record does not itself prove an independent upstream-object audit.

The integration installs **no tracing subscriber**. Upstream source still contains
sensitive payload tracing statements, including the decrypted identity TLV in
`remote_pairing/responder.rs` (upstream line 385), raw RPPairing payload in
`remote_pairing/socket.rs` (upstream line 134), and decoded XPC objects in
`xpc/format.rs` (upstream line 536). Patched line numbers may differ.

**Before enabling any native logging, strip these sensitive payload statements
and all other PIN/key/pairing-record/identifier/raw-handshake logging, then repeat
redaction verification.** Do not install a subscriber or forward native tracing
to Ze logs until that work is complete. This document does not enable logging.

Discovery probes LocalDevVPN's documented Wi-Fi address, `10.7.0.1`. The candidate
set is the full dynamic range 49152–65535 excluding unrelated lockdown 62078;
49152, the reference-observed 55021, and 65535 are tried first. At most 32 probes
are in flight, with 200ms TCP and 1s protocol deadlines and a 30s overall discovery
deadline. A timeout does not mean all candidates were examined. Refusal, timeout,
wrong protocol and saved-identity rejection remain distinct outcomes. A rejected
identity terminates discovery and is preserved; it never triggers silent pairing.

No-record identity creation requires explicit user consent, passed separately
through the Swift contract and C ABI. Keychain item-not-found cannot reliably
distinguish first use from loss of access after re-signing. It is never treated
as permission to create a replacement identity.

`ze_connection_run` stays synchronous, but constructs/polls its async operation
on a joined Rust thread with an explicit 16 MiB stack. Darwin CI faulted in the
future poll at the guard page of a 544 KiB GCD worker stack. The budget is twice
the 8 MiB Linux stack on which the original contract passed, allowing additional
debug SRP/TLS/serde frame headroom; it is not a measured maximum. Each call joins
before return, so input buffers, session and callback context remain borrowed
only for that call. Thread creation failure or worker panic returns
`backendUnavailable`. Concurrent atomic cancellation remains supported.

Callbacks now execute on that Rust thread. Swift copies the ephemeral PIN before
dispatching to MainActor; non-PIN evidence is protected by NSLock and drained only
after run returns. The Swift caller must retain context until return and must
not synchronously re-enter/free the session from a callback. No GCD stack tuning,
test bypass, logging subscriber or new wire protocol is involved.
