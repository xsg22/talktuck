# Mac App Store 本地打包

此流程生成签名候选包并检查已知拒审符号，不安装、不上传、不提交审核。使用前核对商店版本、构建号、证书、发行区域、加密声明和当前版本的功能验收。构建成功不等于产品验收或 Apple 审核通过。

## 从当前提交构建

需要已挂载且可写的“外接硬盘”、至少 8 GiB 空间、Apple Distribution 与 Mac Installer Distribution 证书、Xcode，以及 Python 3.12。首运行会下载固定依赖并建立独立缓存，可能需要较长时间。证书名称也可通过 `TALKTUCK_MAS_APP_IDENTITY` 和 `TALKTUCK_MAS_INSTALLER_IDENTITY` 环境变量提供。签名身份可通过钥匙串访问确认；私钥不会写入日志。

```sh
python3 Scripts/mac-appstore-package.py \
  --version 1.0 --build 3 \
  --python /path/to/python3.12 \
  --output-root '/Volumes/外接硬盘/Codex/talktuck/mas-build-1.0-3' \
  --app-identity 'Apple Distribution: TEAM NAME (TEAMID)' \
  --installer-identity '3rd Party Mac Developer Installer: TEAM NAME (TEAMID)'
```

版本和构建号须自行确认 App Store Connect 尚未使用；输出目录必须是外接盘 `Codex` 下尚不存在的目录，不覆盖旧包。源码采用当前 Git 提交的快照，已跟踪文件有未提交改动时停止；未跟踪文件不会打进构建。依赖缓存在外接盘的 `Codex/talktuck/mas-dependency-cache/`，可用 `--cache-root` 指定专用外接盘目录。脚本对缓存加锁，同一缓存的并发打包会安全退出。Qwen 运行时按输入摘要复用；依赖有变化时重新构建。Swift 编译子进程因本机外接盘临时目录不兼容使用系统临时目录，其余可指定的构建和缓存仍使用外接盘。

控制台只显示摘要；完整日志、来源和 SHA-256 在任务目录的 `evidence/`，安装包及校验文件在 `deliverables/`。成功后自动清理本次 `build/`、`tmp/` 并记录路径；`--keep-build` 可保留中间文件用于排查。失败时保留现场供检查。日志、交付包及依赖缓存保留；其他历史包按项目约定单独核对。

## 以现有 App 生成候选

使用 `--from-app /path/to/App.app` 可跳过源码构建，检查和签名已存在的 App。此模式无法证明 App 与当前源码的对应关系，清单会标记 `verified_against_source: false`。发布前须另行绑定实际源码和验收证据，不能把它当作源码构建。

## 上传与限制

通过 Transporter 手动选择生成的 `.pkg`；账户登录、出口合规、地区、版本资料和最终提审由有权限的人在 App Store Connect 核对。包未嵌入 provisioning profile，Apple 会提示 90889，不能用于 TestFlight；本脚本暂不支持生成或校验商店描述文件。签名包含沙盒、麦克风、网络客户端、网络服务端和用户选择文件读写权限；网络服务端为现有局域网接收功能准备，实际局域网接收仍需在最终沙盒版本中验收。上线前需对最终版本做功能和沙盒验证，并核对模型许可及商店声明。

也可在已有 App Store Connect API 密钥时使用命令行上传，避免操作 Transporter：

```sh
export ASC_API_KEY_ID='KEY_ID'
export ASC_API_ISSUER_ID='ISSUER_UUID'
export API_PRIVATE_KEYS_DIR='/path/to/private_keys'
python3 Scripts/mac-appstore-upload.py '/Volumes/外接硬盘/Codex/talktuck/mas-build-1.0-3/deliverables/TalkTuck-MacAppStore-1.0-3.pkg'
```

将 Apple 签发的 `AuthKey_KEY_ID.p8` 放在该私钥目录，限制目录及文件访问；不要把密钥放进源码仓库或聊天。脚本验证包和 SHA-256，然后调用 Apple `altool`，仅在显式执行时上传，日志放在该任务的 `evidence/`。上传成功不等于处理完成或已提交审核；需要在 App Store Connect 完成剩余流程。尚未配置 API 密钥时可继续使用 Transporter，此脚本不会创建密钥。
