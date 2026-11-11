# Claude Fable 5.2 compatibility

Verified on 2026-11-11 for Ze v1.1.5.

## Sources

- Anthropic model overview: https://platform.claude.com/docs/en/models/fable-5-2/overview
- Anthropic migration guide: https://platform.claude.com/docs/en/models/fable-5-2/migration-guide
- Anthropic release changes: https://platform.claude.com/docs/en/models/fable-5-2/whats-new-fable-5-2
- Official full documentation, successfully fetched when individual pages redirected by region: https://platform.claude.com/llms-full.txt
- Anthropic SDK model IDs: https://github.com/anthropics/anthropic-sdk-python/blob/main/src/anthropic/types/model.py
- Provider catalog snapshot: https://models.dev/api.json

Local evidence is under `artifacts/tasks/fable52-2026-11-11/`. The official documentation SHA-256 is `b992422e80853a87bf874638710830354a42095dabfcd529a10b1da03fa37c79`; `fable52-official-excerpt.md` contains its model page and migration sections. The official SDK model blob is `170712be972c4d31797654cf8892e4641d3d99a7`.

## Implemented contract

- Built-in `claude-fable-5-2`: 1,000,000-token context, 128,000-token output, text/image/PDF inputs, reasoning, and tools. Bundled catalog additions are copied from models.dev for existing providers only; all previous entries and provider metadata are retained.
- Exact Fable 5.2 IDs, including slash namespaces and dotted `5.2`, share the verified Messages normalization path with Claude 5.5. Future Fable names do not inherit these rules automatically.
- Adaptive thinking is always on. The UI offers low through max; a previously saved off selection becomes low. Explicit disabled or Sonnet-only between_tools request bodies become adaptive + low.
- `xhigh` remains `xhigh`, instead of silently becoming `max`. A legacy manual budget becomes adaptive thinking; when no effort was chosen, Fable 5.2 uses its documented high default.
- Remove temperature, top_p, and top_k. Change forced any/tool choice to auto, retaining other choice fields. A trailing assistant prefill remains in history and receives a final user continuation instruction.
- Existing valid effort is retained by final normalization. Only an explicit disabled/between_tools intent selects low; a legacy enabled body with no effort selects high.
- The existing chat UI reads `currentModelSupportsThinkingOff` into `thinkingCanTurnOff` and removes the toggle closure for always-on models (`AIChatView.swift`). Stored preferences go through `normalizedLevel` in `AIChatViewModel.swift`.
- Keep structured output configuration and existing message content unchanged. Remove obsolete effort/interleaved-streaming beta tokens while preserving OAuth and unrelated beta tokens.

## History and scope

Fable 5.2 checks every signed thinking block against its original preceding conversation, system, and tools for every account. The final request normalization leaves existing message content untouched, including empty signed thinking blocks. Ze's existing agent adapter stores visible reasoning text but does not capture/replay signed Claude thinking blocks; this change does not invent signatures or introduce unsigned Claude thinking. Native signed-thinking persistence and account-backed multi-turn tool replay remain separate validation work. No new block-binding beta or blanket drop_block workaround is enabled.

Ze uses its own ordinary function tools and subagent orchestration, not Anthropic's computer_20251124 or advisor tool, so those migration requirements do not require changing these tool definitions. Existing refusal stop-reason handling remains active.

## Verification

- `python scripts/test-model-compatibility.py`: bundled catalog assertions pass locally. Actual production Swift rules/serializer checks are executed by the macOS CI step of the same name; Windows reports an explicit skip when swiftc is absent.
- Request-wire regression cases include all thinking efforts, old off/budget settings, no-intent requests, exact and namespaced IDs, sampling removal, forced tool choices, prefills, structured output preservation, unchanged signed history, and legacy/unknown-model isolation.
- Baseline comparison confirms every previous bundled catalog entry and provider metadata value is unchanged; 20 Fable 5.2 provider entries are added.
- `git diff --check` passes locally. macOS build/run evidence must be bound to the final commit SHA; these local checks are not an Xcode build or a real-account API test.

Pre-edit file copies and SHA-256 values are in `artifacts/tasks/fable52-2026-11-11/baseline/` and `baseline-sha256.json`. Restore only these scoped files from that snapshot to roll back the adaptation; version and voice/UI work are independent.
