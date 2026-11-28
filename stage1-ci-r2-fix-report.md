# 阶段 1 CI 修复轮 2：Rust 操作线程栈

基线 `b5a58fd`。实现提交 `9adba4b`，之后才进行编译、测试与自查。本报告在最终全套运行前提交，随后冻结 HEAD 和受控文件；最终实测结果及提交号以 `/home/hatch/workspace/selfsign-stage1-ci-r2-final/summary.json` 为准，必须 status=PASS、treeUnchanged=true，且 sourceCommit 等于交付 HEAD。未推送；workflow 不动。

## 定位与改动

只读输入为 run 46093870106 的 `/home/hatch/workspace/selfsign-stage1-ci-r2/fixtures2/native-abi/`。已读 contract-result.json、contract-stderr.log、.ips 与 LLDB 回溯。

- 原进度01–06已完成，首次允许创建身份的 prepare 后中止；原运行 SIGBUS / exit138。
- .ips 的地址0x16cfeb230属于 STACK GUARD，故障线程1为 `Ze.ConnectionExperiment.native`，其可写栈区仅544KiB；不是把所有EXC_BAD_ACCESS都推测为栈溢出。
- LLDB同样停止于该GCD线程、`ze_connection_run` 的future poll，原 `lib.rs:241` 直接在调用方执行 current-thread runtime的block_on。未发现与工作线程小栈溢出判断相矛盾的直接证据。

`Installer/Native/src/lib.rs:49` 定义16MiB栈；`:50` 用 `std::thread::Builder::spawn_scoped` 建立 `Ze.Connection.run` 专用线程，并显式join。取值依据是已通过原Linux契约的8MiB栈的两倍，给debug大future及嵌套SRP/TLS/serde调用留余量；不是声称测量过所有操作的栈峰值。每次run只创建一个工作线程；同步join后才返回，不将它detach，也不改成Tokio多线程runtime。

`:64` 的 RunRequest 借用session与输入CStr，`:71` 在Rust工作线程上解析JSON、锁定state、构造future并block_on。原生调用方仅校验句柄/空指针/取消，建立小的借用请求并等待join，避免在小栈上预先构造大型future再搬运。`:275` 的C入口继续同步返回原JSON格式；线程创建失败或worker panic均归backendUnavailable，取消仍是原有AtomicBool和运行中轮询，超时语义不变。

session使用正常的共享借用跨线程，编译器要求其Sync及State的Send，未对session强行添加unsafe Send/Sync。唯一新增的unsafe Send是`:58` 的CallbackContext封装；其依据是C ABI允许worker回调，Swift在整个同步调用期间保留context，scoped join保证指针不越过调用生命周期。Rust只透传context，由既有C回调读取。

文件清单：

| 文件 | 改动 |
|---|---|
| `Installer/Native/src/lib.rs` | 16MiB scoped工作线程、RunRequest/同步join、三项回归 |
| `Installer/Native/include/ze_connection.h` | 声明同步join、回调线程、输入/context有效期与禁止重入/free |
| `Installer/Native/README.md` | 登记栈值依据、调用/回调语义与失败分类 |
| 本报告 | 定位、回调核对、验证命令和平台边界 |

## Swift 回调及所有权核对

Swift生产调用与契约测试均未改，未调大GCD队列栈。

| 原有处理 | 工作线程改变后的核对结果 |
|---|---|
| `NativePairingBackend.swift:56` 串行queue.async进入C ABI | 仍保持串行、同步阻塞直到Rust工作线程结束；不存在同一session同时运行两个operation |
| `:57` passRetained(callbacks)，`:58` defer release | C入口join结束后才返回；回调context在全部原生回调期间仍有效 |
| `:27` nativeEvent复制 `String(cString:)` | PIN指针仍只在单次回调内有效；先复制才跨线程，不保留Rust临时CString指针 |
| `:21` PIN用Task派发到MainActor | 已经支持任意native线程来源；Task强持有callbacks，run返回后仍能安全交付；backend的run ID门控不变 |
| `:22` 非PIN事件存入NSLock保护的collected | Rust工作线程执行回调，join后GCD才drain；锁与事件重放顺序仍有效，不新增独立回调线程排序假设 |
| `:71` MainActor恢复后校验session/activeID/取消 | 保持原跨轮隔离；旧结果不会因Rust线程变化成为当前轮证据 |
| stop中的atomic native cancel及NativeSession捕获 | 取消可从其他线程置位；GCD闭包强持有session到C run返回，free发生在join之后，不释放运行中的session |

callback不可同步重入run或free同一session，继续遵守原有约束；从其他线程cancel仍允许。所有回调在工作线程中同步发出，不在run返回后从Rust继续调用。当前Swift回调不会同步等待GCD调用线程，也不会阻塞等待MainActor，因此未引入join环形等待。

## 提交后回归与最终验证

首次提交后 `cargo test --locked --manifest-path Installer/Native/Cargo.toml` 已实际通过16/16（原13+新增3）。新回归：

- `ffi_prepare_and_restore_from_512k_caller_stack`（lib.rs:296）：显式512KiB调用线程真实调用C ABI，完成新身份prepare、保存身份恢复、监听、取消及释放，生产实现没有复制到测试。
- `run_worker_callback_is_joined_before_context_release`（:315）：使用生产线程helper与emit，验证回调线程区别于caller、线程名正确，函数返回时回调已完成且栈上context可安全销毁。
- `run_worker_panic_becomes_backend_unavailable`（:336）：worker panic经join变为受控错误，不越过C ABI展开。

最终完整命令（本报告提交后执行，不在运行期间改源码）：

```bash
PATH=/home/hatch/workspace/selfsign-tools/swift-6.0.3-RELEASE-ubuntu24.04/usr/bin:/home/hatch/workspace/selfsign-tools/rust/cargo/bin:$PATH \
RUSTUP_HOME=/home/hatch/workspace/selfsign-tools/rust/rustup \
CARGO_HOME=/home/hatch/workspace/selfsign-tools/rust/cargo \
python3 Installer/run-stage1-local-review.py \
  --evidence /home/hatch/workspace/selfsign-stage1-ci-r2-final
```

入口依次实际执行 `run-review.py`（77项Swift、19项脚本、原2项变异）、`run-connection-review.py`（28项连接fixture、4项变异）、Rust全套、`test-native-abi.sh`（含新增原生CI脚本5项与真实Swift→C→Rust契约）。最终交付必须核对：Swift77/77、连接专项28/28、脚本19/19+5/5、Rust16/16、契约PASS且进度01–15全完成；六项变异各build0/test1/controlledAssertionFailure=true；所有阶段退出0，HEAD和源码摘要不变。失败必须修复、另行提交、换新目录完整复跑，不能用本段预期值代替实测证据。

提交后自查：保持C符号签名与输出格式；C输入及callbackcontext借用到join结束；错误路径也join；未新增subscriber；未改Swift/GCD或减弱契约；`git -c core.whitespace=cr-at-eol diff --check b5a58fd`通过；workflow、InstallerHost、只读参考目录diff为空。

本轮Linux验证不能代替下一轮macOS对原SIGBUS点的实际复跑。用户提供的run46093870106已验证iOS归档符号、Ze标志关/开模拟器编译、真机目标链接和unsigned IPA打包成功；这些是上轮CI结果，不充作本轮Linux实测。修复后的macOS/iOS编译与契约仍待推送后CI确认；真实设备配对/查询仍未测。
