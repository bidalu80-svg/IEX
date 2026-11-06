# WorkBuddy 原生授权与聊天参考核对（2026-11-06）

## 核对边界

本文记录源码和公开官网资源的核对结果，不代表已经完成真人账号登录、模型调用或 iPhone 验收。下载源码只作阅读，没有运行第三方脚本。生产实现需要保持 iOS 16 部署目标。

主参考固定为 [HanawaBanana/workbuddy2api@af5e77947c93fd6b7f8b3815ee047d64e0b97752](https://github.com/HanawaBanana/workbuddy2api/tree/af5e77947c93fd6b7f8b3815ee047d64e0b97752)。其 README 说明这是原 Sliverkiss/workbuddy2api 删除后的延续仓库。[LICENSE](https://github.com/HanawaBanana/workbuddy2api/blob/af5e77947c93fd6b7f8b3815ee047d64e0b97752/LICENSE) 为 MIT，Copyright (c) 2026 Sliverkiss；如复制实质代码须保留该版权与许可。接口事实参考与自行实现分开记录。

补充阅读 [linguo2625469/workbuddy2api-panel@73a7560efc7a88ebd9865db4c71ae7f6d85859f8](https://github.com/linguo2625469/workbuddy2api-panel/blob/73a7560efc7a88ebd9865db4c71ae7f6d85859f8/internal/panel/login.go)，其登录也是 state 轮询。没有采用面板中的自动签到、试用领取、区域自动激活、账号池等额外行为。

## 授权协议

证据：[cmd/login/main.go](https://github.com/HanawaBanana/workbuddy2api/blob/af5e77947c93fd6b7f8b3815ee047d64e0b97752/cmd/login/main.go#L1)，尤其 `realmConfig`、`commonHeaders`、`runURL`、`runPoll`。

| Realm | API base | Origin / Referer |
| --- | --- | --- |
| cn | `https://copilot.tencent.com` | `https://www.codebuddy.cn` / 末尾附 `/` |
| global | `https://www.workbuddy.ai` | 同 base / 末尾附 `/` |

| 步骤 | 请求 | 成功字段 |
| --- | --- | --- |
| 发起 | `POST /v2/plugin/auth/state?platform=CLI`，JSON `{}` | `data.state`、`data.authUrl` |
| 浏览器授权 | 打开服务端返回的 HTTPS `authUrl` | 用户在服务商网页完成认证 |
| 轮询 | `GET /v2/plugin/auth/token?state=<URL encoded state>` | `accessToken`、`refreshToken`、`expiresIn`、`domain` |
| 账号确认 | `GET /v2/plugin/login/account?state=<state>`，Bearer access token | `uid`、`enterpriseId`、`nickname` |
| 刷新 | `POST /v2/plugin/auth/token/refresh`，空 body | 新 token、有效期、domain |

业务响应为 `{code,msg,data}`，`code == 0` 才成功。源码描述等待授权时为非零 code + `login ing`。不要把所有 HTTP/业务错误都当作等待；取消、失效、拒绝、网络故障应结束或明确显示错误。为轮询设置总时限和单请求超时，取消时中止任务，重新发起时作废旧 state，避免旧任务写回新账号。

这是服务端 state 驱动的浏览器授权流程，源码没有 authorization-code callback、PKCE、client secret 或可猜测的 app redirect URL。原生 iOS 可用 Safari 授权页面 + URLSession 轮询，关闭授权页面后应取消会话。state 与 realm 绑定；国内/国际凭证不得混用。

登录参考 UA 是 `CLI/2.63.2 CodeBuddy/2.63.2`。通用头包括 JSON Content-Type、Accept、`X-Requested-With: XMLHttpRequest`、对应 Origin 和 Referer。聊天参考使用 `WorkBuddy/5.5.4 WorkBuddy/5.5.4 CLI/2.137.1`；global 第二段为 `WorkBuddy AI/5.5.4`。这些是固定源码的协议兼容值，不代表 Ze 是官方客户端，也不能由此推断上游长期可用。

## 凭证与刷新

证据：[client.go RefreshToken](https://github.com/HanawaBanana/workbuddy2api/blob/af5e77947c93fd6b7f8b3815ee047d64e0b97752/internal/upstream/client.go#L960)、[headers.go RefreshHeaders](https://github.com/HanawaBanana/workbuddy2api/blob/af5e77947c93fd6b7f8b3815ee047d64e0b97752/internal/upstream/headers.go#L433)。

刷新只在刷新端点发送 `X-Refresh-Token` 和 `X-Auth-Refresh-Source: plugin`，可加企业 ID。普通聊天绝不发送 refresh token。刷新响应 access token 非空才替换旧凭证；响应未返回新 refresh token 时保留旧值。有效期必须校验正数与合理上界。原生实现应按 provider instance 隔离 Keychain，登录完成后原子保存；刷新用 single-flight 合并；删除/退出后晚到结果不得复活凭证。

Ze 实现中的缺失/异常 `expiresIn` 兜底为 300 秒，这是客户端保守的缓存策略 **[推断/实现选择]**，并非服务器承诺的有效期；其目的只是避免把未知有效期当永久令牌。账号 `uid` 和 `enterpriseId` 按固定参考 `cmd/login/main.go` 的 string 类型解码。

`X-Device-Token` 在参考中来自已存在的桌面设备状态文件或显式配置，只用于 chat/billing；登录端点没有返回或生成它。没有取到时参考选择省略此头。**具体账号是否需要设备校验尚未真人验证**，不能生成任意假 token 后声称等价，也不能把授权成功等同聊天成功。

## 请求、流式、模型能力

证据：[client.go ChatStreamContext](https://github.com/HanawaBanana/workbuddy2api/blob/af5e77947c93fd6b7f8b3815ee047d64e0b97752/internal/upstream/client.go#L1042)、[payload.go](https://github.com/HanawaBanana/workbuddy2api/blob/af5e77947c93fd6b7f8b3815ee047d64e0b97752/internal/upstream/payload.go)、[sse.go](https://github.com/HanawaBanana/workbuddy2api/blob/af5e77947c93fd6b7f8b3815ee047d64e0b97752/internal/upstream/sse.go#L27)。

- CN/global 都是 `POST {base}/v2/chat/completions`，OpenAI Chat messages/tools/SSE 协议，**必须 `stream: true`**；普通非流式业务也要本地聚合 SSE。
- 输出上限用 `max_tokens`；将 `max_completion_tokens` 转为此字段，二者同时存在时保留显式 `max_tokens`。
- `developer` 转成 `system`；global 首条需要 system（已有 system 保留）。
- 图片是 `{"type":"image_url","image_url":{"url":"..."}}`，不能把 image_url 写成直接字符串。是否可用由具体模型的 `supportsImages` 决定。
- 工具为标准 `tools` / `tool_calls` / `tool_call_id`；`tool_choice` 是字符串：`auto`、`required`、指定函数名。`none` 应同时移除工具定义。历史工具调用与返回应完整配对。
- 流式消费 `choices[].delta.content`、`reasoning_content`、`tool_calls`，按 index/id 合并工具参数片段，尾帧 usage 和 `[DONE]`。空流、截断、JSON 业务错误要作为失败处理。
- `stream_options.include_usage = true` 可索取最终 usage；不要猜费用与剩余额度。
- 请求头含 Bearer access token、`X-User-Id`、`X-CodeBuddy-Request: 1`、realm 对应 domain/enterprise 信息。会话 ID 多轮稳定、conversation request ID 单轮稳定、message/request ID 每次请求独立。不要每个 token 分片创建新的会话。

动态模型证据：[client.go ModelInfo/FetchModels](https://github.com/HanawaBanana/workbuddy2api/blob/af5e77947c93fd6b7f8b3815ee047d64e0b97752/internal/upstream/client.go#L1148)。

| 请求 | 用途 |
| --- | --- |
| `GET /v3/config` | CN/global 主目录，读取 `data.models` |
| CN `GET /console/enterprises/personal/models` | 旧目录补缺，按 `data.agents[name=cli].models` 关联 |
| global `GET /v2/enterprises/personal/models` | 国际账号旧目录补缺，同上 |

模型对象实际字段包括 `id/name/disabled/maxInputTokens/maxOutputTokens/supportsImages/supportsReasoning/supportsToolCall/onlyReasoning/reasoning.supportedEfforts/reasoning.defaultEffort`。应尊重 disabled 和非聊天模型标记；未知能力保留未知，不给每个模型一律赋 vision/tools。参考过滤 `nes-` / `completion-` / `codewise-`、极小输出模型、`text-to-image`。模型列表取决于 realm、账号权限与当时目录；没有可保证通用的固定“全部模型”清单。

Ze 在普通/Agent 聊天实际出站前检查账号目录；冷启动先拉取目录再构造能力相关字段，同实例、账号、realm 和登录代际的并发目录请求合并。退出或重新登录会作废目录及在途请求，旧结果不得写回。当前目录不存在选中模型时明确报错要求重新选模型，不猜测该模型能力。只有明确 `supportsToolCall == true` 才发送工具；其余模型的 Agent 请求移除工具与工具系统提示，按普通聊天回答。图片同样要求目录明确声明能力。

## 官方图标溯源

2026-11-06 实际 GET `https://www.workbuddy.ai` 的 HTML 中 rel=icon 指向：

`https://download.codebuddy.ai/web/workbuddy/7bf1aef23c4134d8f69ba630fcbe783de5f0dc8f/assets/logo.svg`

已下载原始 SVG，4142 bytes，SHA-256：

`10ccbc099e7bc3d5ff12c315c4edd7b21386aa7166c1ec19997b3d55010d5c7d`

本地参考：`C:\Users\Administrator\AppData\Local\Temp\ze-provider-oauth-20261106\reference\workbuddy-official-logo.svg`。绿色圆底白色机器人图形，含渐变和 blur，应按原 SVG 正确渲染导出静态资源，不能换成 SF Symbol 或手绘近似。MIT 源码许可不自动覆盖官方商标/图标；资源保留官方来源说明。`workbuddy.com` 是另一个工单管理产品，不是此服务的图标来源。

## 验收与剩余限制

源码核对已完成：域、授权三步、刷新、模型发现、聊天协议和 logo 来源均有固定证据。尚待实际执行的验收：CN/global 真人授权、取消/失效、刷新并发和退出竞态、文字流式、支持图片模型的图片请求、支持工具模型的工具回合、iOS 16 编译和真机显示。源码声称成功的案例不计入 Ze 的验收结果。
