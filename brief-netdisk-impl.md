# 实现：网络磁盘（五协议只读挂载）（GPT-6.1 Sol 执行）

在设置中可添加 WebDAV、SMB、SFTP、S3、FTP 服务器，作为**只读磁盘**，供 ① AI 文件工具 ② 浏览文件 ③ 聊天媒体 读取。用户验收线：**必须真能用、不许做成摆设**；没验通的协议如实标"未验证"，不许用编译通过冒充能用。

接法已经 Astra 只读核对定案（结论"能做"），以下事实与清单是既定依据，不许推翻重查；细节以代码现状为准。

## 底子（已查证）
- `Shared/RemoteServers/RemoteServerModels.swift`：`RemoteStorageProtocol` 五种齐；`RemoteStorageProfile` 现成；密钥走钥匙串。
- `Shared/RemoteServers/RemoteStorageClients.swift`：统一接口 `RemoteStorageClient`（testConnection/list/upload/download）的实现只有 **WebDAV、SMB、S3、FTP 四种**；统一工厂对 `.sftp` 直接抛错——SFTP 走独立的 `RemoteSSHConnectionService`，且已有 AI 读目录/读文本工具（RemoteServerAIToolGateway）と `RemoteSFTPBrowserView` 可复用。
- 现有消费者只有备份。文件工具现状：`file_read` 经 `executeFileRead`（AIChatViewModel+FileTools.swift）解析本地 URL 后 `Data(contentsOf:)` 读取；**不要只改 resolveHostPath**（它与写路径共用且是同步本地模型）。

## 本轮做（按序，可分多个提交）
1. **修协议阻塞点**（RemoteStorageClients.swift 内）：FTP——TLS 未实现（:247 一带）、`waitReady` continuation 重复恢复风险（:280）、`reply` 粘包/EOF 处理与列表解析；S3——自定义端口、签名、>1000 对象分页、目录前缀语义；WebDAV——输入校验与 PROPFIND 解析。SMB 先核对真实依赖（SMBClient/Citadel），不许用桩冒充。修不动的如实写进提交信息标"未验证"。
2. **磁盘配置与只读服务**：新增共享只读层（拟名 `RemoteDiskStore` + 只读服务），稳定地址 `remote-disk://<diskUUID>/<相对路径>`（凭据不进地址/工具参数）；四协议适配现有客户端、SFTP 适配 SSH 服务；接口层收窄为只读（list/download/testConnection），写请求直接拒绝；下载字节上限独立于文本输出上限。
3. **设置入口**：抽取/复用备份那边的存储配置表单，在设置里开"网络磁盘"入口，支持新增/编辑/删除/重新验证，连接、列目录、读取分别显示结果；SFTP 接通主机信任流程。
4. **接文件工具**：新增 `remote_disk_list`（列磁盘/列目录，返回可读地址）；`executeFileRead` 前端识别远程地址走只读服务，复用现有文本解码/行范围/截断；媒体经受限下载落到会话目录，返回本地路径供 read_image 等使用。错误路径/断网返回明确失败，不许伪装空内容。
5. **接浏览文件**：在现有文件浏览处加来源选择与只读远程浏览（可参考 RemoteSFTPBrowserView 的异步列目录，但**去掉一切写入口**）；目录读取失败要报错，不许显示成空目录。
6. **接聊天媒体**：附件选择加"网络磁盘"来源，复用现有附件缓存与发送链路；图片要真进模型请求、文本真可读、音视频可预览。

## 红线
- 只读是硬线：任何写路径（upload/删除/重命名/建目录）在磁盘这条线上不可达。
- 新功能放新文件（本项目既定规矩：存量文件不再拆分、新功能用新文件）；必须改存量文件时只做最小接入点改动。
- 严禁整文件行尾翻转；每个提交前 `git diff --stat` 自检。
- 顺序：先实现、分步本地提交，全部提交后再自查（scripts/ 双向扫查 + 本轮新增字面是否被检查钉死）。
- 本机无 Xcode，不能编译——如实写明；能跑的脚本检查要跑。
- 若 .git 只读无法提交：把全部提交打成 git bundle 放**本克隆根目录** `./netdisk.bundle`，最后输出写明。
- 最后输出：逐协议状态表（已实现什么、验到哪一步、哪些未验证），不许含糊。
