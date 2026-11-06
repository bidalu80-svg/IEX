# ChatGPT 网页直连实验接入

2026-11-06，实施基线 `208a89b732ba089035514787cea0a2eae16f0759`，最低部署版本 iOS 16.0。

## 已核对的来源与实际边界

用户选择手机直接连接，不使用自建网关。参考固定为
[basketikun/chatgpt2api@92dd80e91543157d36a4ddad60e765c5293760e9](https://github.com/basketikun/chatgpt2api/tree/92dd80e91543157d36a4ddad60e765c5293760e9)。
已阅读其 `services/openai_oauth.py`、`services/oauth_login_service.py`、
`services/openai_backend_api.py` 的授权、消息、模型和 requirements 实现。
README/feature-status 与代码存在差异，以固定版本源码为依据。

尝试读取 OpenAI Docs 的 developers.openai.com Codex auth 与 platform.openai.com API authentication 页面，均返回 HTTP 403，未取得可引用正文。因此本文不把第三方源码中的流程描述为 OpenAI 面向 Ze 开放或保证兼容的 OAuth 接口。

网页客户端使用 `app_2SKx67EdpoN0G6j64rFvigXD`、
`https://auth.openai.com/api/accounts/authorize` 和 `/api/accounts/oauth/token`，
回调为 `https://platform.openai.com/auth/callback`。它与现有 Codex 的客户端、回调及 Responses 端点不同。
原生登录在隔离的 WKWebView 中打开授权网页，只捕获精确 HTTPS 回调及匹配的 state；保持 PKCE S256、TLS 验证、五分钟超时，不收集密码。
网页或第三方身份提供商可能限制嵌入式浏览器，此时登录会失败；此前尚无真实账号成功证据；2026-11-07 用户反馈首次邮箱登录可保存服务商并加载模型，但发消息被浏览器验证阻断，二次登录出现回调地址校验错误。此反馈不等于聊天通过。

## 接入范围

- OpenAI 服务商新增 `chatGPTWeb` 凭据类型，原 `oauth` 继续表示 Codex。新凭据有必须存在的 schema discriminator，防止误解码旧 token。
- 文字聊天走 `https://chatgpt.com/backend-api/conversation`，按网页消息/SSE 协议解析；模型目录读取 `/backend-api/models`，默认 `auto`，不套用 API 模型 ID。
- requirements prepare/finalize 及有界 proof 计算在后台执行。2026-11-07 补充参考 `utils/turnstile.py` 的受限 dx 指令计算：结果同时进入 finalize 的 `turnstile_token` 和对话请求的 `OpenAI-Sentinel-Turnstile-Token`。未知指令、无效输入及超限必须停止，不能提交空结果假装完成验证。Arkose 交互验证及 HTTP 403 仍可能阻断；原生 URLSession 不等同于浏览器会话，不保证账号或网络环境被接受。
- 首版为文字对话；不宣称图片、音频、Ze 本地工具或子代理支持。网页原生工具调用不等于 API function calling。包含工具历史或附件的请求明确提示切换服务商。
- API token usage 未在网页响应中出现时保持未知。网页请求不伪造 API 采样参数、max_tokens 或费用。
- 每个实例独立 Keychain，刷新合并并发请求，保留未轮换的 refresh token；取消/退出后用 generation 防止晚到结果重新保存凭据。

## 验证与回滚

`scripts/test-web-oauth.py` 编译生产回调与令牌解码逻辑，覆盖来源、state 重复/错配、错误回调、缺失/无效有效期、JWT 有效期调度、refresh token 保留、Codex schema 隔离。
`scripts/test-chatgpt-web.py` 编译生产协议/传输，使用隔离 HTTP fixture 验证 digest、proof 时限、SSE、消息字段及错误路径。
它们接入现有 `.github/workflows/build.yml`。Windows 静态检查不等于 Xcode 编译，fixture 成功也不等于真实账号授权成功。完整构建与设备结果以最终 commit/run 记录为准。

保持已有聊天/搜索/分享应用回归和 IPA 发布门槛。代码回滚应针对本次提交做 revert；不要重置用户数据或现有凭据。新版本可以读取旧凭据；旧版本不理解新 `chatGPTWeb` 类型，跨版本降级/旧设备同步需要先移除新类型实例并保留备份。

## 2026-11-07 故障拆分与协议对照

| 通道 | 登录完成依据 | 聊天前额外步骤 |
| --- | --- | --- |
| GitHub Copilot | device code 轮询取得凭据；pending/slow_down 继续等待 | 按账号路由换取服务 token 或使用直接 token |
| Kimi | device flow 轮询取得凭据 | 按该服务接口调用，不能移植别家的 client/redirect |
| OpenRouter | PKCE code 换取 key | 使用换得的服务凭据 |
| Codex | 独立 client 的授权码/PKCE 流程 | Codex Responses 端点，与 ChatGPT 网页隔离 |
| WorkBuddy | state → 浏览器授权 → token 轮询 → account | 使用账号/realm 信息构造请求；11217 是轮询等待状态 |
| ChatGPT 网页 | 精确 HTTPS 回调 + query state/code + PKCE 换取 token | 首页 → requirements prepare → 验证计算 → finalize → conversation |

回调问题：此前导航拦截允许 fragment，但 `callbackCode` 拒绝任何 fragment。现统一精确来源判断，忽略 `#` 之后的内容；只从 query 读取并验证唯一 code/state。域名、端口、路径、userinfo 和重复参数约束不放宽。**实际失败回调未采集，fragment 是与报错路径吻合的推断，不是已证明的设备根因。**

聊天问题：旧版本在 turnstile.required 时直接退出，并把任意 HTTP403 显示为相同的重新登录提示。现补 dx 路径并按 WEB-HOME / WEB-PREPARE / WEB-FINALIZE / WEB-CHAT / WEB-MODELS 标出 403 阶段。WEB-DX 表示验证数据缺失、格式/指令尚未适配或预算超限；WEB-ARKOSE 表示交互验证尚未完成。错误信息不含凭据、回调地址、账号信息或响应原文。

`scripts/test-web-challenge.py` 验证独立解释器的固定向量与资源上限；`scripts/test-chatgpt-web.py` 在生产传输上验证 prepare 的 source → dx → finalize body → conversation header → SSE，并覆盖缺失/损坏 dx、Arkose 与各阶段403。全部为隔离 fixture，不声称真实服务已接受 dx 或真人对话成功。

验收分三层记录：生产 Swift fixture、iOS16 部署目标的完整构建/既有运行回归、真人账号登录及连续对话。最后一层仍待安装最终构建后验证，不能以能列出模型替代。
