# Ze 重签与外部文件夹访问

Ze 的外部目录访问使用 iOS `UIDocumentPicker` 发放的安全作用域书签。这个授权属于用户对具体文件夹的授权，不通过一个通用 entitlement 直接放开整台设备的文件系统。

## 重签时必须保留的签名配置

主 App、File Provider 扩展和分享扩展需要使用同一组 App Group：

```text
group.com.ze.app
```

主 App 还需要保留 iCloud 容器：

```text
iCloud.com.ze.app
```

重签工具需要对 `.app` 内所有嵌套扩展重新签名，并让扩展的 bundle identifier 保持原值：

```text
com.ze.app
com.ze.app.FileProvider
com.ze.app.ShareExtension
com.ze.app.AgentWidget
```

如果重签工具删除或替换了 App Group，Files 中的 Ze 目录可能仍然显示，但主 App 与 File Provider 会落到不同容器，表现为点击“打开”没有内容或操作无响应。此时需要在重签工具中恢复上面的 App Group，并重新安装；仅修改主 App 的 entitlement 不足以修复扩展。

## Ze 内的恢复路径

挂载记录保存在 App Group 的 `ZeConfig/mounted-folders.json`。如果重签或系统迁移使原书签失效，挂载列表会保留，并可在“挂载外部文件夹”列表中左滑或长按“重新授权”，从 Files 重新选择同一个文件夹。Ze 会生成与当前签名匹配的新书签、重新检测读写权限并立即刷新挂载。

首次选择文件夹和重新授权都通过 SwiftUI `fileImporter` 完成，Files 的“打开”按钮由系统管理其收起流程，避免嵌套 picker 导致的卡住状态。

## 验证清单

1. 在重签工具中确认主 App 与所有扩展都包含 `group.com.ze.app`。
2. 安装后打开“挂载外部文件夹”，选择 Files 中的目录并确认挂载。
3. 如果状态显示权限失效，使用“重新授权”再次选择原目录。
4. 在 Ze 的“浏览文件”和 Files → “在我的 iPhone 上”中分别打开目录，确认读写策略符合设置。
