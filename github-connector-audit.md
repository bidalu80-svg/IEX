# GitHub 连接器权限排查（抢救版）

> DeepSeek 排查会话于 2026-11-18 22:5x 在写报告阶段崩溃（flush on a closed handle），本报告由 Muse 从其会话日志中提取结论、并抽查关键项后写成。抽查已核：GitHubAccountStore.swift:48 的 scope 原文、连接器实际调用的端点集合。

## 结论一句话
不是账号完整权限：是**仓库级全权 + Actions 工作流**，且 App 实际调用的接口比令牌权限还要窄。

## 1. 登录流程
- 连接器：OAuth 设备码流程，入口 `Shared/GitHub/GitHubAccountStore.swift`。
- 另一处独立流程：GitHub Copilot，`Providers/GitHubCopilot/GitHubCopilotOAuthManager.swift:237`，只申请 `read:user`，与连接器无关。

## 2. 申请的权限（原文）
- 连接器（GitHubAccountStore.swift:48）：`repo read:org workflow read:user user:email`
- Copilot：`read:user`

## 3. 实际授予的核对
- 代码会记录授予的 scope：优先取 API 响应头 `X-OAuth-Scopes`（权威值），回退到令牌响应里的 scope，存进账号记录。
- 但登录完成时**不比对**"申请的"与"实际授予的"是否一致——少授了也不会提示。

## 4. 令牌的实际用途（端点）
只用到：`/user`（资料）、`/user/repos`、`/repos/{owner}/{repo}`、仓库内容读/写/删、git blobs/trees/commits/refs。
未发现：议题、PR、Actions、组织、gist、webhook 的任何端点调用；没有建仓/删仓、没有组织管理。

## 5. 与"完整权限"的差距（未申请）
- `delete_repo`：删仓库 ✗
- `admin:org` / `write:org`：组织管理（成员、团队）✗（只有 `read:org` 只读）
- `gist` ✗
- `admin:repo_hook`：webhook 完整管理 ✗（注：`repo` 本身含仓库 webhook 的读写，缺的是 ping/删除级）
- 其余未申请：`admin:public_key`（SSH 密钥）、`notifications`、完整 `user`（写资料/关注）、`read/write:packages`、`admin:gpg_key`、project 类 scope。
- 已有大头：`repo`（公私仓库代码、状态、部署、协作者邀请、安全事件）+ `workflow`（可改工作流文件、可触发）。


## 2026-11-19 实施版本说明与 webhook 勘误

以上为扩权前的历史排查，保留原文，不代表本次实现的验证结果。第 5 项关于 `admin:repo_hook` 的判断有误：`repo` 已包含仓库 webhook 的完整管理（包括 ping、删除），`admin:repo_hook` 不是新增能力；组织 webhook 的 `admin:org_hook` 是独立范围。

本次新增共享有限的 20 项 OAuth 目标集合、父子覆盖、三态和缺失说明；设备授权在保存前匹配目标账号并核验实际授予，响应头优先且空头不回退；手工令牌允许受限连接。旧账号可显式补权，成功才替换原凭据。最终清单、OAuth 无法覆盖的凭据类型及待核验的企业/产品专项见 `docs/github-connector-audit.md`。

本机无法在线复核官方文档，且没有 macOS Swift/xcrun 和真机 OAuth 环境。因此不宣称字面完整账号权限，不把申请清单当作实际授予，也不把仓库客户端测试通过当作登录验证。
