# Ze v1.1.4 compatibility and child-agent verification

## Model evidence (2026-11-06)

The existing catalog update path is `LLMTypes` fallback entries plus `ModelsDevAPI` enrichment and the bundled `Resources/models-dev-api.json`. This update refreshes the four requested provider sections only. Provider model-list responses remain authoritative for account availability.

| Provider | Model IDs | Context / output tokens | Input / output |
| --- | --- | --- | --- |
| OpenAI | `gpt-6.1-sol`, `gpt-6.1-terra` | 1,050,000 / 128,000 | text, image, PDF / text |
| Anthropic | `claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5` | 1,000,000 / 128,000 | text, image, PDF / text |
| Google | `gemini-4-argon` | 1,048,576 / 32,768 | text, image, audio, video, PDF / text |
| DeepSeek | `deepseek-flash` (V4.1 Flash 1017) | 1,048,576 / 393,216 | text, image / text |

All listed entries advertise reasoning and tool calls in the [models.dev catalog](https://models.dev/api.json). Catalog modalities describe upstream capabilities, not a promise that every Ze attachment route or OAuth endpoint exposes them.

Official evidence obtained:

- [DeepSeek model pricing/capabilities](https://api-docs.deepseek.com/quick_start/pricing/): Flash alias, vision, context/output limits, tool calling; V4 Pro remains text-only. Retired V4 Flash aliases are accepted and routed to Flash 1017.
- [DeepSeek thinking mode](https://api-docs.deepseek.com/guides/thinking_mode/): root `thinking.type` and `reasoning_effort`; low maps to low, medium/high/xhigh to high, max/ultra to max; explicit disabled omits effort.

Direct documentation pages initially returned HTTP 403 (OpenAI), timed out (Google), or redirected to a region-unavailable page (Anthropic). Additional official source verification subsequently established:

- [OpenAI Python SDK model enum](https://github.com/openai/openai-python/blob/c6fc264689d384d5caec150fafa1a9567c4a3f56/src/openai/types/shared/chat_model.py#L9): exact `gpt-6.1-sol` and `gpt-6.1-terra` names. SDK enumeration does not prove account availability or every capability.
- [Google Python SDK model enum](https://github.com/googleapis/python-genai/blob/afb10e88fbefe929f08376787ea84d0715680cce/google/genai/_gaos/types/interactions/model.py#L76): exact `gemini-4-argon` name in the Interactions model enum. This does not establish a new generateContent thinking contract or OAuth availability.
- [Anthropic official model reference](https://github.com/anthropics/skills/blob/ca45fc496a3436251f191354091d557da31c15b5/skills/claude-api/shared/models.md#L64): all three 5.5 IDs, 1M context and 128K output. Its migration notes distinguish Opus mandatory adaptive thinking, Sonnet `between_tools` for low-effort thinking-off, and Haiku adaptive/disabled rules.

OpenAI/Google limits and modalities above remain catalog evidence where official source details were not obtained. No live credentialed inference request was run.

The existing GPT-6 request family handles the new IDs. Claude 5.5 has model-specific last-mile Messages request rules: Opus maps legacy off to adaptive + low, Sonnet maps off to `between_tools` with effort at most high, and Haiku maps off to disabled with effort at most high. Enabled thinking uses adaptive without a legacy token budget. Retired sampling parameters and beta flags are removed, mandatory-thinking tool choice is normalized, and a trailing assistant turn is preserved as history followed by a user continuation. The UI treats Opus legacy off as low. Tests execute the actual request patcher and serialized JSON, including old-model and non-Messages isolation. Signed thinking-block replay remains an existing provider limitation and is not established by this compatibility update.

Gemini 4 reasoning is provider-managed until its tuning contract is verified: Ze displays automatic thinking and omits guessed thinking parameters. The public API catalog and Cloud Code OAuth fallback are kept separate so a public model is not advertised as available through an unverified OAuth route.

## Child-agent reference and implementation

Reference: [iOS source tree](https://github.com/OpenMinis/OpenMinis/tree/1a71df0f381cefde80bf912b723de6f9831bc177/src/ios), including `HelperBlockView.swift`, `HelperSheet.swift`, `SubAgentRunDetail.swift`, `SubAgentStore.swift`, and lifecycle tests. `SubAgentRunDetail.swift` blob: `951e443e8bacaeeded68874a34ef59b25c29caea`.

Implemented in Ze's existing runtime and message renderer:

- Stable task identity across inline cards, floating thumbnails and tool sheets; wait results show each referenced child, including completed tasks.
- Running corrections use the existing persisted prompt queue and are consumed after tool results commit. Polling remains active.
- Replacements await the previous task's actual completion; Stop invalidates delayed replacements and clears queued corrections.
- User Stop targets the selected delegation's sibling group and descendants, determined by parent ID and recorded parent-turn ID. Older records without turn identity do not guess sibling ownership.
- Resume reloads the original child session and preserves prior work; process interruption is not shown as completion.
- Inline presentation follows the reference two-line 58pt treatment: a 34pt state circle, name chip and task, current activity, and direct Stop/Resume controls. Floating previews use a separate 100x65pt black surface; the former shared black card was removed.
- Tool sheets embed the detail content directly. Sections use the reference 10pt corner radius, separate gray header, divider and 0.5pt outline. Recent tools show the latest eight calls without an expanding output log. Completed output uses Markdown; the latest screenshot is asynchronously downsampled. Transcript opens the actual `CollectionViewMessageListV3` renderer with Stop and 0.35/medium/large detents.
- Active rim uses Core Animation instead of per-frame SwiftUI updates; animations stop off-window, in background and for Reduce Motion. Output previews are bounded, historic tool snapshots cached, writes throttled on a serial background queue, list order stable, and live expanded output avoids Markdown reparse.

Runtime correction after the UI review adds FIFO admission (six executing, up to 24 queued), a default ten-minute budget capped at sixty, a tool-boundary final-answer request and a ninety-second grace limit. User Stop suppresses future callbacks and removes already queued child-result messages. Optional progress reports follow the reference default of none, with frequent updates every fifteen seconds when facts change or moderate updates every sixty seconds. A busy parent retains only the latest pending progress item per child; progress alone does not interrupt its current tool chain. Results use the existing parent prompt queue without replacing the user's composer or attachments; explicit wait consumption prevents duplicate delivery. Request model identity is captured at the actual provider call, including fallback, and is labelled as request identity rather than server-confirmed identity. Restored children explicitly receive a warning that browser/process state may have been lost.

Remaining architecture differences are explicit: Ze keeps its three-level child tree; completion is delivered through the existing visible message queue rather than rewriting the original delegation tool result; the twenty-second soft interruption uses Ze's existing shell/browser/delay cancellation, with the ninety-second final cancellation covering the remaining run. Pending questions after process restart expire instead of restoring an upstream deferred continuation.

This is adaptation to Ze's tool/runtime architecture. Device-level visual equivalence, scrolling/frame-time measurements, image-preview visual parity and live provider calls still require an installed build; source changes and CI alone do not establish those results.

## Question interaction cards

Reference iOS files: `Views/Chat/UserAskCardView.swift` (blob `a25b5871a124a0f639469c6ef516a530d7fc4239`), `Agent/Chat/UserAskCore.swift`, `UserAskCenter.swift`, and `AIChatViewModel+UserAsk.swift`.

Ze keeps its existing `ask_user` tool name and supports both legacy single-line questions and JSON-encoded structured questions. New structured fields include multiple selection, option descriptions, explicit confirmation, impact and risk. Selection remains a draft until Next/Submit; there is no timed auto-submit. Confirmation cards require an explicit allow/deny action and do not offer delegation or an arbitrary replacement answer.

The corrected pending card uses the reference single-line 28pt icon header, exact typography ratios, first-option recommendation badge, 44pt capsule controls and body cap `max(160, screenHeight * 0.5 - 120)`. Resolved cards use the 34pt icon and two-line summary with 46pt expanded-content inset. Other answers and notes open a large-only independent input sheet using a 3...8-line bordered TextField, dictation, Cancel and Done. Drafts survive view changes and previous-question navigation. Inline and tool-sheet surfaces share the same card.

The earlier self-rendered screenshots were rejected: they proved rendering, not reference parity. The new comparison harness fetches unmodified view declarations and localization from the pinned reference commit, renders the same question states and dimensions, and produces side-by-side PNGs. Its source manifest records Git blob and SHA256 hashes. Successful image generation is explicitly not a visual-parity verdict. In run `42166614741` (commit `b1eab572999a2a6cc3c325342d8056e078e2526f`), manual review and aligned pixel comparison found all ten pending/resolved/timeout card pairs identical; the two input sheets differed only in the blinking caret. This finding covers those fixtures, not arbitrary content or a full installed application. Four additional pending/resolved floating-thumbnail fixtures exercise the source-derived miniature summary and tile rendering.

Notification replies are bound to the originating session and exact question index. Registering question actions preserves unrelated notification categories. Saved pending state includes a process identity: a process restart marks an orphaned request expired while preserving partial answers and drafts, rather than claiming the suspended continuation is still alive.

## Validation and rollback

The existing push-triggered `.github/workflows/build.yml` now also executes:

- `scripts/test-model-compatibility.py`: catalog contracts and compiled production thinking-rule behavior.
- `scripts/SubAgentLifecycleHarness.swift`: production coordinator with fixture dependencies, exercising queue, cancellation, sibling grouping, restoration and legacy decoding.
- `scripts/test-subagent-delivery.py`: executes the shipping callback queue helpers to verify composer/attachment preservation, progress coalescing, and Stop removing child callbacks while preserving user prompts.
- `scripts/SubAgentBlockLinkTests.swift`: compiled production task identity parser, including persisted and malformed results.
- `scripts/test-question-core.py`: compiled production question schema/state, notification identity and persistence contracts.
- `scripts/test-question-layout.py`: compiled production typography and per-question layout cache.
- `scripts/test-question-reference-ui.sh` and `scripts/compare-question-ui.py`: pinned upstream declarations rendered separately and paired with Ze at identical dimensions.
- `scripts/test-subagent-reference-ui.sh` and `scripts/compare-subagent-ui.py`: original upstream inline/thumbnail Views and original digest-based stats/timeline sections, paired with the corresponding production surfaces. This does not by itself verify the entire detail page or runtime controls.
- `scripts/test-subagent-full-detail.sh` and `scripts/compare-subagent-full-detail.py`: complete original detail component and Ze production detail, light/dark and running/completed, captured at top and bottom scroll positions with coverage assertions. Empty-output fixtures exercise metadata, activity, history and live controls; Markdown, screenshot images, thinking badges and action side effects are explicitly excluded and fail if unexpectedly rendered.
- `scripts/test-subagent-ui.sh` and `scripts/test-question-ui.sh`: real production views hosted in a simulator window, with PNGs and result JSON. Fixtures supply record data and app integration dependencies; microphone capture is not exercised. These are component rendering checks, not full-app device performance measurements.

The normal unsigned iOS build and IPA audit assert version 1.1.4 (build 8). Local Windows checks can validate catalogs, source structure and diffs; Swift and iOS compilation require the macOS workflow. See the delivery's exact commit and workflow URL for the actual result.

Baseline before this update: `355bd26`. To roll back the delivered changes without rewriting branch history, revert the v1.1.4 commits on the same branch and push; the existing workflow will rebuild that source.
