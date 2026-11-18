# 凭据日志泄露修复报告

## 范围与提交

- 基线：`e01b9793`（工作区初始状态）。
- 当前分支：`fix707`。
- 实现提交：`6e09aa8b` `fix(netdisk): redact credential tool payloads from provider logs`。
- 仅修改以下三个文件：
  - `Providers/Gemini/GeminiProvider.swift`
  - `Providers/Antigravity/AntigravityProvider.swift`
  - `scripts/verify-netdisk-gateway.py`
- 未改动其他服务商、其他日志点或非日志行为。提交后自查未发现需要另起修复提交的问题。

## 修复 1：Gemini SSE 工具响应参数

修改 `Providers/Gemini/GeminiProvider.swift` 的 `logStreamChunk`：

- 新增凭据工具名集合：`remote_disk_configure_credentials`、`remote_server_configure_credentials`。
- 在输出原始 JSON 预览前检查当前 chunk：
  - 解析出的 `functionCall` 事件名属于凭据工具，或
  - 原始 JSON 中出现任一凭据工具名。
- 命中时不再输出原始 JSON 前 500 字符，只输出 `raw: <redacted: credential tool payload>`。
- 输出 `functionCall` 事件时，凭据工具的 `args` 不再序列化或截取，只输出 `functionCall(<name>): <redacted>`；`thoughtSignature` 仍按原逻辑输出。

因此密码、Secret Key、私钥和口令短语不会再经该 SSE 响应日志路径输出。

## 修复 2：Antigravity 请求正文

修改 `Providers/Antigravity/AntigravityProvider.swift` 的 `logFullRequest`：

- 新增同一组凭据工具名过滤。
- 在打印请求体前扫描序列化正文；只要正文引用任一凭据工具，就整段屏蔽请求正文，只输出 `Body (N bytes): <redacted: credential tool payload>`，不调用 `LastAPIRequestBody.shared.set`，也不输出正文前 3000 字符。
- URL、Method、请求头等非正文日志保持原样；非凭据工具的普通请求正文日志路径保持不变。

由于智能体请求的工具声明本身会包含凭据工具名，工具型 Antigravity 请求的正文日志会一并省略；这是选择“按工具名整段屏蔽”后的诊断能力取舍，仅影响 DEBUG 日志。

## 静态检查

在 `scripts/verify-netdisk-gateway.py` 增加了 5 项回归检查（脚本原有检查保持不动）：

- 两个服务商文件都覆盖两个存凭据工具名。
- Gemini `logStreamChunk` 在凭据调用或原始 JSON 命中时抑制原始 JSON 预览。
- Gemini `functionCall` 参数在格式化前按工具名脱敏，且脱敏判断位于 `argsStr` 构造之前。
- Antigravity `logFullRequest` 在正文命中凭据工具时输出屏蔽标记。
- 过滤判断位于正文截断和打印之前。

实际运行结果：

```text
python3 scripts/verify-netdisk-gateway.py
...
Network disk gateway source checks passed: 32. Swift, Keychain, UI and live protocols NOT verified.
```

另外执行并通过：

- `python3 -m py_compile scripts/verify-netdisk-gateway.py`
- `git diff --check HEAD^ HEAD`
- 三个被修改文件均保持原有 LF 行尾（`git ls-files --eol` 均为 `i/lf w/lf`），未整文件翻转行尾。

## 未验证项

- 本地没有 `swiftc`、`swift` 或 Xcode，未编译 Swift，也未执行任何 Swift 测试。
- 未运行 App、模拟器或真机，未实际触发 Gemini/Antigravity 请求，未采集运行时日志验证脱敏结果。
- 以上检查均为源码静态检查，不能替代编译和运行时验证；CI/设备验证仍需后续完成。
