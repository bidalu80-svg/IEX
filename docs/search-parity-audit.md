# In-chat search source audit

Baseline: `4d3d3c65df68e50220a89dfe9b124949316601ed`, successful run `42168726240`.
Reference: OpenMinis/OpenMinis `1a71df0f381cefde80bf912b723de6f9831bc177`.

| Contract | Baseline mismatch | Required correction |
| --- | --- | --- |
| Query | Split keywords AND on one line | One trimmed literal substring; case/diacritic insensitive |
| Results | Dedupe identical lines, first occurrence only, 400 lines | Stable unit key + occurrence ordinal; 200/unit, 2000/chat |
| Initial navigation | First/oldest | Newest; next/previous wrap with notice |
| Streaming | Main queue search; reset index | Copy models on main, resolve/search background, cancel stale generations; preserve active match without scroll |
| Search scope | User text + assistant raw markdown only | Rendered Markdown incl code/table text; visible file names/tool summaries/info/subagent/resolved question/footer; exclude hidden tool output/thinking/pending questions |
| Highlight | Process-global query; mutate attributed background and erase original backgrounds on clear | Per-conversation, per-unit tokens; yellow ordinary/orange current; draw without changing storage/layout; code/table outline |
| Scroll | First identical line; cell-local rectangle used as content coordinates; flash ring | Exact ordinal, converted content rectangle, expand target folded row, stop auto-follow, keep comfortably visible |
| Bar | 17pt field, custom fills, 0/0 empty | Original 15pt field/36pt height, material bar, No results, keyboard shortcuts, transient wrap notice |
| Export isolation | Global query leaks into unrelated renders | No injected center outside transcript |

Verification must execute production matcher/navigation/Markdown projection, actual TextKit storage-preservation and attachment mapping, and real bar screenshots. Source structure alone is not acceptance.
