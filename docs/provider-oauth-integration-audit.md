# Provider OAuth integration audit

Baseline: `208a89b732ba089035514787cea0a2eae16f0759`, branch `codex/aojit-real`, 2026-11-06. This is a local integration audit, not evidence that either external protocol has been authenticated on a device. Production sources were not changed by this audit.

## Scope and conclusions

Reviewed provider types/instances, credential probing, the LLM and agent factories, model seeding/fetching, JSON import/export, SQLite instance reads/writes, OAuth UI branches, voice routing, existing refresh coordination, provider sync mappings, and project registration. Large files were inspected by relevant functions and ranges; this is not a claim that every project source line was read.

1. Existing OpenAI OAuth means Codex in several independent layers. A ChatGPT web login cannot be implemented by changing its button label or by feeding a web session token into `OpenAIProvider(oauthTokenProvider:)`.
2. OpenAI currently persists only `.apiKey` / `.oauth`. Separate native login modes need a persisted discriminator with an explicit legacy Codex default. A new field must survive SQLite, JSON mirrors/import/export and per-record sync. Alternatively, a distinct provider type changes the product semantics; this must be an explicit design choice, not an accidental workaround.
3. WorkBuddy needs protocol-specific authentication and transport based on verified reference/official behavior. OpenAI-compatible reuse is appropriate only if the selected endpoint actually accepts that wire protocol. Model IDs, tools, images, reasoning and usage must follow verified upstream responses.
4. The app deployment target is iOS 16.0. New views/session APIs must compile for that target. Existing test-only targets also contain newer deployment targets; those do not change the app compatibility requirement.

## Integration map and required changes

| Surface | Current evidence | Required coverage |
|---|---|---|
| `Providers/ProviderTypes.swift` | `ProviderType` is Codable/CaseIterable; unknown raw types map to `.unsupported`; `ProviderCredential` has two cases | Add WorkBuddy display name, model catalog policy, picker subtitle and default modality; keep unknown-type preservation |
| `Providers/ProviderInstance.swift` | Manual Codable; `computeHasAnyCredential` decodes OpenAI/Responses as `CodexTokenStorage`; credential results cached by instance | Add auth-mode persistence/default; mode-aware token probe; WorkBuddy typed credential; invalidate auth cache after every credential change |
| `Providers/LLMProviderFactory.swift` | `makeProvider` dispatch; OpenAI/Responses builders call Codex manager; `applyCustomUserAgent` deliberately skips OAuth | Explicit native web transport vs Codex routing; WorkBuddy factory; preserve instance ID, timeout, thinking rules and correct UA semantics |
| `Providers/OpenAI/OpenAIProvider.swift` | OAuth constructor implies Responses behavior; request builders send to `https://chatgpt.com/backend-api/codex/responses` with Codex headers; comments explicitly distinguish web-session tokens | Keep Codex behavior stable. Web conversation protocol needs its own request/response handling, not only different bearer token |
| `Agent/Chat/AIChatViewModel+ProviderFactory.swift` | Both `makeAgentProvider` and independently implemented `makeLLMProvider` dispatch providers; lightweight OpenAI branch directly calls Codex | Update both paths. Title generation, subagents, fallback and `model_use` must not silently retain Codex routing |
| `Providers/AgentProvider.swift` | Unified text/tool/thinking/usage/done stream contract; instance-bound idle timeout | New transport must emit correct event boundaries, tool results, cancellation and completion. Do not advertise tool support solely because a text stream works |
| `Providers/ProviderConfigStore.swift:addInstance` | OpenAI OAuth always seeds `allOpenAICodexOAuth`; other OAuth uses provider built-ins | Mode-aware seed or authenticated catalog discovery; do not offer Codex IDs for web sessions |
| `ProviderConfigStore.fetchModelsForInstance` | OpenAI OAuth returns static `OpenAIModelsAPI.fetchModelsOAuth`; tuple switch is exhaustive | Add WorkBuddy and ChatGPT-specific catalogs; preserve user models on transient failures |
| `ProviderConfigStore.exportInstanceJSON/importInstanceJSON` | Typed token switches handle `.openAI` as Codex; `.openAIResponses` currently falls through; Copilot explicitly omits token export | Add mode metadata and intentional token export/import policy; reject/migrate incompatible token schemas; tests must cover old exports |
| `Providers/ProviderConfigDB.swift` | `schemaVersion = 2`; fixed SQL columns; `dumpProviderConfig`, bulk replace, public upsert and private upsert map fields explicitly | Persist auth discriminator additively with legacy default. Update CREATE/repair or migration, SELECT column indexes, row mapping, all upserts and dump. Existing `extras_json` is not automatically decoded into `ProviderInstance` |
| `Agent/Sync/V2/SyncedTypes.swift` | `SyncedProviderInstanceV3` explicitly declares fields and registry metadata | Add optional auth-mode field with forward compatibility |
| `Agent/Sync/V2/ChatStoreSyncHydrators.swift` | `buildProviderInstanceV3` and `mergeProviderInstanceV3` explicitly map DB rows/portable fields | Carry discriminator in both directions; no token-to-mode ambiguity after sync |
| `Providers/ProviderMigration.swift` | Legacy singleton Codex migration only `.openAI`; exhaustive provider switch | Preserve old Codex migration semantics; new provider needs explicit no-legacy case |
| `Providers/Voice/VoiceProviderFactory.swift` | OpenAI/Responses voice route loads API key; unsupported families return nil | Explicit WorkBuddy nil unless audio is verified; web login must not become an API-key voice configuration |
| `Providers/ProviderAPIQuota.swift` | Provider-specific base-URL switch; OAuth credential policy separate | Add nil/unavailable for unverified balance API; do not synthesize zero balances |
| `NativeOffloads/ModelUseOffloadBridge.swift` | Exhaustive optional provider switch in `imageParamHint` | WorkBuddy case with actual supported image contract, or no hint |
| `Agent/Chat/AIChatViewModel.swift` | `entryAllowsReasoning` and `currentModelThinkingInfo` switches | Only expose verified thinking control and wire mapping |
| `Debug/DebugRPCProviderChat.swift` | Provider credential switch | Cover new provider and actual authentication options |
| `Shared/Config/Collections/ProvidersCollection.swift` | Agent-created providers currently default `.apiKey`; credential fields are write-only | Ensure native OAuth-only provider is not advertised as usable with arbitrary API key; expose mode only if schema supports it |
| `ZeApp.swift` | Foreground auth diagnostic uses typed manager/token switch with default false | Keep diagnostics accurate for new credentials; no raw token logging |

## UI and icon mapping

`Views/Providers/AddProviderView.swift` owns type choices, available credential choices, OAuth sheet state, `startOAuth`, `loadMaskedToken`, labels, descriptions, provider icons and tint. Existing OpenAI login invokes `CodexOAuthManager`. On Back/cancel it deletes the pending instance token and auxiliary strings. New modes must reset pending state when switched and clean up any browser/session/polling task as well as Keychain values. Login completion must mean a usable credential was obtained, not merely that a browser was presented.

`Views/Providers/ProviderInstanceDetailView.swift` separately owns authentication status/detail, login label/action, logout, token copy and default base URL. Every mode needs accurate status, re-login and logout. WorkBuddy metadata cannot be decoded using another provider's token type.

`Views/Providers/ProviderInstancesView.swift` has another typed authentication switch. It currently renders a special Copilot icon and status dots for other providers. Adding an icon only in AddProviderView leaves the saved provider row inconsistent.

`Views/Providers/UnifiedModelPicker.swift` uses `entry.displayTraits` capability symbols in model rows, not provider-branded icons. Its provider section can be extended deliberately if product intent requires a brand there; replacing capability symbols indiscriminately would lose modality meaning.

There is no central universal brand-icon registry in these audited provider screens. WorkBuddy's official icon should be a sourced asset/vector with provenance, reused by addition and saved-provider views. A guessed SF Symbol or unrelated logo does not satisfy the requested icon.

## Credential lifecycle requirements

`ProviderKeychainHelper` stores typed OAuth JSON in account `oauth-token` under service `com.ze.app.provider.<instanceId>`. It first reads synchronizable storage, then legacy storage. Writes/deletes call `notifyAuthChanged`, which is important because auth availability and model resolution are cached. Generic helper writes currently return Void and log Keychain status; a new login manager must not equate calling save with demonstrated successful persistence.

Existing shared `OAuthRefreshSingleFlight<Token>` serializes refresh per instance. `OAuthRefreshCoordinator.resolveAfterRefreshFailure` reloads current storage and compares refresh tokens before deleting stale credentials. Preserve these semantics for a refresh-token protocol. If a web session uses cookies/session refresh instead, use its real lifecycle rather than inventing an OAuth refresh token.

Test logout/cancel versus in-flight login/refresh. The shared single-flight helper does not expose cancellation itself; copying a manager without a generation/cancellation guard may allow an awaited refresh to write credentials after logout. Copilot has its own in-flight cancellation and cached tokens. New managers need explicit task ownership and stale-result rejection.

Manual bearer strings are currently checked before typed credentials in several routes. Define whether manual tokens are allowed for each new mode; do not accidentally let a stale `manual-oauth-token` override the newly selected web session.

## Build and validation gates

`Ze.xcodeproj/project.pbxproj` uses explicit references/build files for Providers. New source files require FileReference, group membership and app Sources build phase entries. Pure transport/auth decision helpers included in tests also need test Sources registration. Merely putting a Swift file in Providers does not compile it into the app.

Required validation before a delivery claim:

1. Codable legacy-default and round-trip tests, old/new JSON imports, SQLite reopen, sync build/merge round-trip and unknown provider preservation.
2. Mock protocol tests for login cancellation, invalid state/callback, missing token, expiry/refresh rotation, parallel refresh, transient network errors, revoked session, and logout during refresh. No credential output in logs or fixtures.
3. Request/stream fixtures for text, multi-turn continuity, tool call/result only if supported, images only if supported, reasoning, usage, upstream errors, cancellation and interrupted SSE. Exact endpoint/body/header assertions must distinguish Codex from ChatGPT web.
4. Main chat plus lightweight/title generation, subagents and `model_use` exercise the same selected instance/auth mode. Old API-key and Codex OAuth configurations continue to route correctly.
5. `git diff --check`, inspect every provider switch above, project file parse/registration validation, then macOS Xcode app build and iOS 16-target typecheck. Windows static checks are not an Xcode compile.
6. Real browser/login and installed-device tests with user-owned sessions; verify add/detail/list status, cancel/back, relaunch persistence, logout and streaming. CI without real accounts cannot certify OAuth service acceptance.

Existing related unit suites: `ZeTests/OAuthRefreshRaceAllProvidersTests.swift`, `OAuthRefreshErrorClassifierTests.swift`, `KimiOAuthTests.swift`, `ClaudeOAuthRefreshRaceTests.swift`. Reuse their deterministic patterns instead of adding superficial string-presence tests.

`.github/workflows/build.yml` triggers on pushes to all branches and cancels older same-branch runs. Keep the current branch and existing trigger policy; tie eventual build claims to exact commit SHA and run conclusion.

## External protocol decisions intentionally pending

The parent investigation owns reference repository identity/revision, actual ChatGPT web authentication versus Codex OAuth, WorkBuddy login method, OAuth client registration/redirect constraints, and verified model/feature availability. This local audit does not establish those facts and does not authorize representing a proxy API-key configuration as a completed native OAuth integration.

## Follow-up: dedicated credential raw value

The user selected experimental direct-on-phone ChatGPT web integration. A `ProviderCredential.chatGPTWeb` case is a viable narrower persistence design than adding an OAuth-mode property: the existing `credential_type` TEXT column, JSON `credentialType` and sync `credentialType` string already carry its raw value. Current-build persistence requires no new DB column or migration. Existing `.oauth` stays Codex exactly. The table's new-column work applies only if a separate property design is chosen.

Costs and safeguards of this design:

- Every `switch instance.credentialType` in `LLMProviderFactory`, both agent/lightweight factories, `ProviderInstancesView`, `ProviderInstanceDetailView` and tuple switches in model refresh/credential descriptions needs coverage. Invalid combinations such as Anthropic + `.chatGPTWeb` must fail explicitly rather than route through another credential case. UI should offer the case only for `.openAI`.
- Equality checks (`== .oauth`, `!= .apiKey`, ternary API Key/OAuth labels) also require review. They control add-instance seeding, manual-token widgets, login sheets, custom URL exposure, and credential migration. Some must include web login; others must deliberately remain Codex-only.
- `ProviderInstance` currently decodes `ProviderCredential` strictly. An older app decoding a new `chatGPTWeb` raw value from JSON can fail, while its DB reader defaults unknown credential strings to `.apiKey`. Thus the design is backward-readable by the new build but not downgrade/older-peer safe. A forward-compatible unknown credential preservation policy is desirable; silently rewriting the raw value to `.apiKey` is not safe.
- Export/import already serializes raw credential type, but typed token payload switches remain provider-based. OpenAI export/import must dispatch on `.chatGPTWeb` before trying `CodexTokenStorage`; likewise `hasAnyCredential`, list/detail status, copy, login/logout, model seed and both factories.
- Keep web session data in a distinct schema/account or use explicit discriminator checking. Never try web token decoding as fallback Codex parsing, and never let a stale manual OAuth override the new web credential route.

This option avoids SQLite schema changes while retaining OpenAI as the selected provider. It does not eliminate the wire-protocol, lifecycle and test requirements above.
