# 图片模型与 GPT-6.2 标识兼容核对

## 来源与确认范围

2026-11-06，用户提供的服务商模型列表包含 `gpt-image-2.5`、`gpt-image-2.6`、`gpt-image-2.6-flare`、`gpt-image-2.6-sunburst`，其中部分缺少图片能力图标；用户另要求 GPT-6.2 推理兼容。

OpenAI Docs 模型及图片指南页面本次请求返回 HTTP 403，未取得正文。转而实际读取官方 SDK 的固定源码：

- [openai-python image_model.py](https://github.com/openai/openai-python/blob/c6fc264689d384d5caec150fafa1a9567c4a3f56/src/openai/types/image_model.py)
- [image_generate_params.py](https://github.com/openai/openai-python/blob/c6fc264689d384d5caec150fafa1a9567c4a3f56/src/openai/types/image_generate_params.py)
- [image_edit_params.py](https://github.com/openai/openai-python/blob/c6fc264689d384d5caec150fafa1a9567c4a3f56/src/openai/types/image_edit_params.py)
- [chat_model.py](https://github.com/openai/openai-python/blob/c6fc264689d384d5caec150fafa1a9567c4a3f56/src/openai/types/shared_params/chat_model.py) 与同目录 `responses_model.py`、`reasoning.py`。

官方 SDK 明确列出 `gpt-image-2.5-flare`、`gpt-image-2.5-sunburst` 及其 2026-09-08 快照、`gpt-image-2.6-flare`、`gpt-image-2.6-sunburst`，并将它们用于 generation/edit 参数。没有在该固定版本找到无后缀 `gpt-image-2.5`、`gpt-image-2.6` 或 GPT-6.2 的官方枚举。本次把这些服务商返回/用户要求的标识作为兼容别名处理，不声称它们都是正式公开型号。GitHub 官方组织代码搜索没有找到 GPT-6.2；搜索没有结果也不足以证明型号不存在。

实时 models.dev 目录读取成功，包含 GPT Image 2，Azure 下有 2.5 Flare/Sunburst，未补足 2.6/GPT-6.2；它仅为辅助目录，不覆盖官方 SDK 证据。

## 确认的协议能力

| 项目 | 官方源码证据 / 实现处理 |
| --- | --- |
| 图片生成与编辑 | generation/edit 均允许上述 2.6 型号；Ze 保留原始模型 ID，分别走 Images generation / multipart edit |
| 返回格式 | GPT Image 固定返回 base64，`response_format` 为旧模型参数；从 GPT Image 请求中移除 |
| 质量 | SDK 参数枚举为 low/medium/high/xhigh/max/auto 等；注释明确 2.5 支持 xhigh/max，2.6 精确档位说明尚未齐全。Ze 原样透传所选质量，不强制提升默认值 |
| 输出与高级选项 | SDK 有 PNG/JPEG/WebP/GIF/SVG、complexity、background、output_compression；Ze 当前完整图片路径接 PNG/JPEG/WebP，GIF/SVG 和分片流式明确提示未适配，不当作普通 PNG |
| 尺寸 | SDK 对 2/2.5 说明可用 WIDTHxHEIGHT、16 的倍数及比例/像素约束；2.6 精确限制未另行确认。Ze 保留调用者传入尺寸，不编造新默认额度 |
| GPT-6.2 推理 | 本次修复 namespace 识别与既有 GPT-6 兼容路线；Chat 为 reasoning_effort，Responses 为 reasoning.effort，保留原模型 ID；不新增未经确认的上下文/输出规格 |

## 故障链与修复

`/models` 没返回模态字段时，原实现赋值 `.textOnly` 并缓存。名字推断没有 GPT Image 规则，且非空缓存不再推断，导致图片输出图标缺失，也可能走错聊天端点。

新增严格数字版本家族匹配和 namespace 归一化。新模型缺元数据时推断精确 `[textInput, imageInput, imageOutput]`；有效 ModelEntry 修复旧 nil/textOnly 默认缓存，原始存储不改写，用户模态 override 始终最高优先。没有保留 textOutput，纯图片路由会进入 Images API。

历史缓存没有记录模态来源，旧客户端默认 textOnly 与服务端明确 textOnly 形状相同。本次对严格 GPT Image 家族的这一形状统一修复；确有特殊用途的用户可通过显式 override 保留 textOnly。其他服务端模态组合不被改写。

GPT-6.2 裸 ID 已被旧 GPT-6 家族规则涵盖，遗漏的是 `openai/gpt-6.2…` 等带前缀 ID 和 UI 中 `gpt6*` 别名。修复只规范化判断值，不重写请求 ID；服务端明确 reasoning=false 和用户覆盖继续有效。Ultra 是本地档位，线上仍映射 max。

Codex 图片工具目前没有已验证的选定 2.5/2.6 版本参数，继续保留原 gpt-image-2 路线；其他 GPT Image 型号在此登录方式下明确提示使用 API Key 图片服务商，避免偷偷调用默认图片模型。

## 验证

新增 `test-image-model-capabilities.py`、`test-image-wire.py`、`test-openai-reasoning-wire.py`，编译实际生产逻辑并验证旧缓存、新目录、用户覆盖、生成/edit 字段、原 ID 保留、Chat/Responses 推理形态、显式关闭及 namespace。已有模型兼容测试同步覆盖 GPT-6.2 标识。

Windows 仅完成静态/脚本组装检查；最终 Swift fixture、iOS 16 编译、完整应用运行结果以新提交对应的 Actions 为准。真实图片生成及实际 GPT-6.2 服务商调用需要账号联调，fixture 不替代上游验收。
