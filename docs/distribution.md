# macOS 安装包与发行

OpenTypeless 使用 DMG 分发。用户下载后将 `OpenTypeless.app` 拖入 `Applications`，从“应用程序”启动；不需要 Xcode、命令行或开发者证书。首次使用仍需提供自己的 OpenRouter API Key，并授权麦克风、辅助功能。模型调用需要联网，并由用户自己的 OpenRouter 账户付费。

默认构建 Universal 应用，同时包含 Apple Silicon（arm64）和 Intel（x86_64），最低系统要求来自 `Resources/Info.plist`（当前为 macOS 14）。跨架构编译与签名校验不等同于在每种硬件、系统版本上完成实机验收。

## 正式发行前提

- Xcode 26 / Swift 6.2 或更新版本，包含 macOS 26 SDK。
- 钥匙串内有效的 **Developer ID Application** 证书及其私钥。`Apple Development` 是本机开发身份；`Apple Distribution` 不能替代站外发行身份。拖拽安装的 DMG 不需要 Developer ID Installer 证书。
- Apple 开发者账号的协议与权限有效。Xcode 若提示 `PLA Update available`，需要账号持有人亲自在 Apple 开发者账号页处理协议，然后创建/安装 Developer ID Application 证书。
- 已保存在钥匙串中的 `notarytool` 认证配置。

公证认证可以使用开发者团队的 App Store Connect API Key，或个人 Apple 账户的 App 专用密码。App 专用密码不是公证的必需条件；两种方式都可保存为同名钥匙串配置，后续打包命令不变。

### 使用开发者团队 API Key

在 App Store Connect 中取得用于公证的 Team API Key、Key ID 和 Issuer ID，把 `.p8` 私钥保存在源码目录之外的本机私密目录，然后保存公证配置：

```sh
xcrun notarytool store-credentials OpenTypeless-notary \
  --key "/本机私密目录/AuthKey_KEYID.p8" \
  --key-id "KEY_ID" \
  --issuer "ISSUER_ID"
```

以上路径和 ID 都需要替换为实际值。这个方案不需要个人 Apple 账户的 App 专用密码，API Key 用于 Apple 开发者服务。它仍是需要保护的发布凭据：Team API Key 的权限由角色决定，访问范围不能只限定为 OpenTypeless 一个应用。不要将 `.p8` 文件或其内容放进源码或聊天。

### 使用 App 专用密码

如果维护者选择个人 Apple 账户认证，可以在自己的终端交互式保存公证凭据：

```sh
xcrun notarytool store-credentials OpenTypeless-notary
```

按提示填写 Apple 账号、Team ID 和 App 专用密码。不要将密码、私钥或证书导出文件放进源码、聊天、命令参数或 Git。这里的 Apple 账号凭据仅用于维护者公证，与用户在应用里配置的 OpenRouter API Key 无关。

## 一条命令生成正式安装包

```sh
./script/package_release.sh --notary-profile OpenTypeless-notary --check
./script/package_release.sh --notary-profile OpenTypeless-notary
```

脚本自动选择唯一有效的 Developer ID Application 证书；有多个时用 `--identity <SHA-1 指纹>` 明确指定。也支持 `OPENTYPELESS_RELEASE_IDENTITY`、`OPENTYPELESS_NOTARY_PROFILE` 环境变量，二者不包含私钥或密码。

流程为：分别编译两个架构的 Release 二进制 → 合并 Universal 应用 → 打包必要的 Swift 运行库 → hardened runtime 签名 → 提交应用公证并附加票据 → 创建带 Applications 快捷方式的 DMG → 对 DMG 签名、公证并附加票据 → 挂载、模拟拖拽复制、校验应用及 Gatekeeper → 输出 DMG 和 SHA-256。

应用和 DMG 都附加公证票据，便于离线校验安装来源；**听写功能仍需要联网**。应用的开发验证菜单不包含在 Release 构建中。脚本只复制编译结果、Info.plist、图标和运行库，不读取作者的 API Key、设置、历史、词典或录音。

默认输出：

```text
dist/OpenTypeless-0.1.0-universal.dmg
dist/OpenTypeless-0.1.0-universal.dmg.sha256
dist/OpenTypeless-0.1.0-universal-notarization/
```

版本号由 Info.plist 提供。发布新版本时同时递增 `CFBundleShortVersionString` 和 `CFBundleVersion`。输出已存在时脚本拒绝覆盖；临时重测可用 `--output-dir /tmp/opentypeless-release-check`。正式命令缺少发行证书、公证凭据或验证失败时直接退出，绝不自动生成冒充正式版的测试包。

脚本先将构建所需源码复制到本地临时目录，保证两个架构使用同一份输入，并避开 iCloud 下载文件时修改时间戳导致的编译失败。应用也在该目录打包，防止 iCloud 给应用包添加元数据并破坏签名。最终只把封装好的 DMG 写入 `dist/`，不替换 `~/Applications/OpenTypeless.app`，也不结束正在录音的开发版进程。

## 没有发行凭据时检查安装包

```sh
./script/package_release.sh --preview
./script/verify_release.sh --preview dist/OpenTypeless-0.1.0-universal-local-preview.dmg
```

这会生成 `local-preview.dmg`，明确标注“本地测试包”。它使用临时签名，**没有 Developer ID 签名、没有 Apple 公证，不能作为普通用户直接下载安装的正式版**。只用于验证两个架构的编译、DMG 结构、复制安装和代码签名完整性；不会关闭或绕过 Gatekeeper。

可用 `--architecture arm64` 或 `--architecture x86_64` 只构建一个架构。验证时须传入相同的 `--architecture`；默认要求 Universal。

## 发布检查

```sh
swift test
./script/verify_release.sh dist/OpenTypeless-0.1.0-universal.dmg
(cd dist && shasum -a 256 -c OpenTypeless-0.1.0-universal.dmg.sha256)
```

验证器检查磁盘映像、Applications 链接、应用图标、两个 CPU 架构、hardened runtime、麦克风 entitlement、开发调试 entitlement、可移植的动态库路径、签名、公证票据和 Gatekeeper。正式验证不会接受本地测试包。

在 GitHub Release 中上传通过正式验证的 DMG 和 `.sha256`，写明 macOS 要求、API Key 配置及当前实验性状态。仓库中的源代码 ZIP 不能替代安装包。不要上传 `local-preview`、证书或公证日志作为正式安装资产。

发布前仍应在另一台 Mac 上通过浏览器下载并测试：拖拽安装、首次启动、麦克风与辅助功能授权、Fn 听写、回填、退出重启，以及旧版覆盖升级。当前开发证书换成 Developer ID 后，既有开发安装可能需要重新授权辅助功能或确认钥匙串访问；后续发行保持相同 bundle ID 和 Developer ID 身份。

## 公证失败或超时

公证服务返回 `Accepted` 才继续。失败时保留临时工作目录、提交 ID 和响应 JSON；不会在 `dist/` 生成正式包。若等待超时，服务端仍可能继续处理，可以先查询该提交，避免重复上传：

```sh
xcrun notarytool info <提交-ID> --keychain-profile OpenTypeless-notary
xcrun notarytool log <提交-ID> --keychain-profile OpenTypeless-notary /tmp/opentypeless-notary-log.json
```

诊断日志可能含本机路径和签名账号信息，应留在本机检查。解决原因后重新运行打包。首次公证或服务繁忙时耗时可能更长，脚本每次提交最多等待 20 分钟。

## Apple 参考

- [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Migrating notarization credentials: App-specific password or App Store Connect API key](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)
- [Creating App Store Connect API keys](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)
- [Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
- [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
