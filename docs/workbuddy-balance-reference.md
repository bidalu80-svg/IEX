# WorkBuddy OAuth 账号积分（2026-11-10）

本次修复模型选择页和服务商详情页共用的额度仓库。此前仓库只接受 API Key；WorkBuddy OAuth 登录即被拒绝，详情页也隐藏整个额度分组。API Key 中转服务的 `/status` 不属于原生 OAuth 积分协议，保留原路径与原解析。

## 协议证据

沿用已固定的 [HanawaBanana/workbuddy2api@af5e77947c93fd6b7f8b3815ee047d64e0b97752](https://github.com/HanawaBanana/workbuddy2api/tree/af5e77947c93fd6b7f8b3815ee047d64e0b97752)。只参考接口事实，本次 Swift 实现独立编写。

- `internal/upstream/client.go:882`：CN `https://www.codebuddy.cn/v2/billing/meter/get-user-resource`；global `https://www.workbuddy.ai/billing/meter/get-user-resource`，只有 HTTP 404 才使用 `/v2` 备用路径。
- `client.go:1592`：POST，`PageNumber`、`PageSize:100`、`ProductCode:p_tcaca`、`Status:[0,3]`、有效期过滤范围。
- `internal/upstream/headers.go:406`：Bearer access token、`X-User-Id`、企业/租户 ID、domain 和已经存在的 device token；不生成 device token，不发送 refresh token。
- `internal/upstream/report.go:26`、`client.go:910`：billing 解开 `{code:0,data:...}` 信封。内部有效内容为 `Response.Data.Accounts`，不是直接 `balance` 字段。
- `client.go:1565,1666`：套餐字段 `CapacitySize/Remain/Used`，有正数 `CycleCapacitySize` 时优先使用周期三字段。中文展示单位为积分，非货币。

## 实现边界

`WorkBuddyBalanceAPI` 通过已有 `validCredentials` 复用 OAuth 刷新合并和退出竞态保护，使用现有拒绝重定向的 URLSession。仅访问固定 billing 域，不使用用户配置的聊天 base URL。缓存身份绑定实例、登录代际、realm、用户与企业；令牌正常轮换不丢弃同账号成功结果，退出/换号后晚到结果被丢弃。

套餐列表按页聚合，100 条满页继续请求，最多 10 页，超限明确失败而不显示不完整余额。过滤时间采用参考的 UTC+8 墙钟，避免依赖 iPhone 当前时区。严格拒绝缺失字段、布尔数值、异常数字、失败信封或内部 Error；只有明确的空 Accounts 才显示零。有效套餐已用量取服务端报告与总量减剩余的较大值，不重复计算周期和总套餐字段。异常范围返回不可用，不悄悄修成零。

模型选择页继续使用现有余额徽章，点击打开当前服务商详情。详情对 WorkBuddy OAuth 显示「WorkBuddy 可用积分」、已用、总额、来源、更新时间和刷新按钮；API Key 服务商原展示保持。登录代际变化触发两个界面重新查询。

## 验证范围

`scripts/test-workbuddy.py` 编译真实 OAuth、billing、模型目录及请求适配器，以隔离 URLProtocol 验证 CN/global 域和路径、请求体、企业头、不泄露刷新令牌、周期优先与套餐汇总、HTTP/业务错误、缺失和异常字段、明确零、global 404 备用路径、在途退出后丢弃旧结果。测试凭证全为 fixture，不使用真实账户。

`scripts/test-model-picker-header.sh` 另编译真实额度仓库、OAuth 管理器、billing 客户端及模型选择标题。仅注入带 URLProtocol 的 session，保留完整生产 fetch 路径；验证缓存、切换账号、取消和在途退出。`extract-provider-quota-detail.py` 精确提取详情页额度 Section 和所有格式化方法，带源码哈希；通过真实 Form / UIHostingController 导出 loaded、error、zero 三种状态的浅色/深色截图，共六张。积分格式仅在 WorkBuddy OAuth 分支使用，既有 API Key 服务商格式保持。

本地 Windows 只执行 Python 语法/结构检查；生产 Swift fixtures、iOS 编译和渲染结果以本次 CI 实际报告为准。当前工作区没有用户可用 OAuth 凭证，真人账号接口返回值与 iPhone 显示仍应独立标记为待实测；离线通过不等同真人余额已验证。
