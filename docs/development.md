# 本地开发

使用 Xcode 26 / Swift 6.2 或更新版本，以及 macOS 26 SDK。最低运行版本是 macOS 14。先启动一次 Xcode 完成工具安装；`xcode-select -p` 应指向准备使用的 Xcode Developer 目录。

## 无开发者证书构建

```sh
./script/build_and_run.sh --ad-hoc
```

这会生成本机可运行的 `.app`，并启动它。它不需要 Apple 开发者账号、发行证书或 Apple 公证配置。临时签名的身份随二进制变化；重新构建后若 Fn 或回填不再工作，请在“系统设置 → 隐私与安全性 → 辅助功能”重新授权该应用，必要时移除旧条目再添加新的应用。

只构建到一个隔离目录：

```sh
./script/build_and_run.sh --build-only --ad-hoc --output /tmp/OpenTypeless.app
```

`--output` 必须是以 `.app` 结尾的绝对路径。脚本拒绝覆盖 bundle ID 不匹配的应用。默认输出在 `~/Applications/`，应用包应放在本机目录，以免 iCloud 给包添加元数据后破坏签名。

## 使用稳定的开发签名

如果你已有自己的 Apple Development 证书，可省略 `--ad-hoc`：

```sh
./script/build_and_run.sh
```

脚本自动选择唯一有效的 Apple Development 身份。存在多个证书时，通过 `OPENTYPELESS_SIGNING_IDENTITY` 指定证书指纹；可用 `security find-identity -v -p codesigning` 查看。明确配置开发证书后不要同时传 `--ad-hoc`。

稳定签名有助于在更新应用时保留系统权限。开发签名和站外发行签名用途不同；公开分发二进制见 [发行说明](distribution.md)。源码贡献者不需要配置发行公证。

## 常用命令

```sh
swift test
./script/build_and_run.sh --verify --ad-hoc
./script/build_and_run.sh --build-only --ad-hoc
./script/build_and_run.sh --relaunch
./script/build_and_run.sh --logs --ad-hoc
./script/build_and_run.sh --help
```

除 `--build-only` 外，构建并启动的模式会结束已运行的 OpenTypeless。请先结束听写；不要在录音期间重建正在使用的应用。`--relaunch` 复用已有应用而不重新编译。

## 验证范围

`swift test` 不读取 OpenRouter 密钥，不请求真实模型。对涉及录音、Fn、辅助功能或回填的修改，另行手动测试开始、结束、取消、失败恢复，以及至少一个原生编辑器和网页编辑器。启动 GUI 应使用 `.app`，而不是直接运行 SwiftPM 的裸可执行文件。

本地调研记录、历史截图、录音和发行输出不进入 Git。评测工具可自行生成匿名样本，操作见 [评测说明](../Tools/TranscriptionBenchmark/README.md)。
