# 服务商原色图标

所有服务商图像使用 `renderingMode(.original)`，图片集也统一声明 original；不再使用 SwiftUI 主文字颜色对厂商标志统一染色。GitHub Copilot 和 WorkBuddy 的既有图形不变。

色值与图形固定于 `docs/provider-brand-assets.json` 记录的来源版本。品牌原本采用黑白的地方保留原色，并使用其公开 avatar 底色确保浅色、深色界面均可辨认，不为满足“彩色”而替换成另一品牌或任意色。

| 服务商 | 图形与原色依据 |
| --- | --- |
| OpenAI / Responses API | OpenAI 结形图标；来源明确提供的 GPT 绿色 avatar 变体 `#19C37D`，白色结形；不是动态跟随当前 GPT 型号改色 |
| Anthropic | Anthropic AI 标志；公开 avatar 奶油色 `#F1F0E8`、墨色 `#141413`；不冒用 Claude 的橙色星形 |
| OpenRouter | 原色 SVG 的 `#C8FF00` 标志；公开黑色 avatar 底色 |
| xAI | 原始黑色 xAI 标志及公开白色 avatar 底色 |
| Kimi | 原始蓝点及 K 标志，K 的黑白外观变体用于深浅主题，蓝点不变 |
| ElevenLabs | 原始双线黑标、公开白色 avatar 底色 |
| Groq | 公开 `#F55036` avatar 底色及白标 |
| Moonshot | 公开 `#16191E` avatar 底色及白标 |
| Xiaomi MiMo | 公开黑色 avatar 底色及白标 |
| Deepgram | Simple Icons 固定版本品牌数据与其指向的官方 newsroom，品牌色 `#13EF93`；原始黑标置于品牌色底板 |
| 其余厂商 | 固定版本原色 SVG，保留全部颜色 |

OpenAI、Anthropic、OpenRouter、xAI、ElevenLabs、Groq、Moonshot、XiaomiMiMo 的色值依据为同一固定版本 lobe-icons 的对应 `src/<品牌>/style.ts`，每条资产清单包含精确 URL 和 avatar 参数；OpenAI 的 `components/Avatar.tsx` 明确公开 `gpt3` 绿色变体。

Gemini 与 Antigravity 的 SVG 在 Apple 图片集编译器下分别发生星形丢失与渐变分层。本次按原 SVG 使用固定 `resvg-py==0.5.0` 离线生成 1x/2x/3x PNG，避免运行时 SVG 差异；原始 SVG 与最终 PNG 哈希均保存。原色资源预览仅是离线预检，最终仍检查实际 iOS 渲染截图。
