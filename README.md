# OpenTypeless

原生 macOS 听写工具。按一下 **Fn** 开始录音，再按一下结束；通过 OpenRouter 将语音识别为文字，再按所选模式整理并回填到当前输入框。

**当前为 v0.1 实验性原型，以源码形式发布。** 你需要自行编译，并提供自己的 OpenRouter API Key。模型调用由你的 OpenRouter 账户计费。

## 功能

- Fn 开始／结束听写，Esc 取消；支持备用快捷键和手动选择麦克风。
- 忠实整理、仅转写、结构化指令三种模式，可分别配置识别与整理模型。
- 个人词典、拼写纠正学习、原稿与成稿对比。
- 本地历史记录、失败录音恢复、识别超时备用模型。
- 原生 SwiftUI 主窗口、菜单栏入口和不抢焦点的录音浮窗。
- 回填前检查输入目标，无法可靠回填时保留结果供复制；不会自动按回车发送。

## 环境要求

- macOS 14 或更高版本。
- Xcode 26 或更新版本，包含 Swift 6.2+ 与 macOS 26 SDK；使用前完成 Xcode 的首次初始化。
- 用于模型调用的网络连接与 OpenRouter API Key。

下面的本地构建方式不需要 Apple 开发者证书或公证凭据。

## 从源码运行

```sh
git clone https://github.com/BruceStyle/OpenTypeless.git
cd OpenTypeless
./script/build_and_run.sh --ad-hoc
```

脚本会构建并启动 `~/Applications/OpenTypeless.app`。重新构建前请先结束当前听写。

`--ad-hoc` 使用本地临时签名，更新二进制后可能需要重新授予辅助功能权限。长期开发可以使用自己的 Apple Development 证书，操作见 [开发说明](docs/development.md)。

## 首次配置

1. 在“设置 → 模型与连接”填写自己的 OpenRouter API Key，点击“保存并连接”。
2. 在“设置 → 隐私与权限”允许麦克风，并在系统设置中允许 OpenTypeless 使用辅助功能。
3. 在“设置 → 通用”确认快捷键和麦克风。回到一个可编辑的输入框，按 Fn 开始录音，再按 Fn 结束。

如果 Fn 同时打开表情面板，可以在 macOS“系统设置 → 键盘”中调整 Fn／🌐 键动作，或在应用中选择备用快捷键。其他占用同一快捷键的听写工具可能产生冲突。

## 数据与费用

识别会把本次录音发送给 OpenRouter；文字整理会发送原稿、词典与整理规则。模型服务的数据处理规则取决于 OpenRouter 和实际模型提供方。

API Key 保存在本机钥匙串。设置、词典、历史和待恢复录音保存在 `~/Library/Application Support/OpenTypeless/`。仓库不包含维护者的密钥、录音、历史或账号凭据。

应用显示的已记录费用可能不包含所有请求，应以 OpenRouter 账单为准。取消请求也不保证服务端停止计费。

## 开发与测试

```sh
swift test

# 只构建到指定位置，不启动应用
./script/build_and_run.sh --build-only --ad-hoc --output /tmp/OpenTypeless.app
```

自动测试使用合成音频与模拟网络响应，不调用付费模型。独立的 [转写评测工具](Tools/TranscriptionBenchmark/README.md) 提供额外对照实验，其付费运行需要显式指定 `--run`。

| 目录 | 内容 |
| --- | --- |
| `Sources/OpenTypelessCore/` | 音频分段、识别请求、整理规则、词典与回填判断 |
| `Sources/OpenTypeless/` | SwiftUI 界面、录音、快捷键、辅助功能与本地存储 |
| `Tests/` | 单元与组件测试 |
| `Resources/` | 应用信息、权限声明与图标 |
| `script/` | 构建、图标生成与可选发行工具 |

贡献方式见 [CONTRIBUTING.md](CONTRIBUTING.md)。维护者需要分发二进制时，可参考可选的 [签名与公证说明](docs/distribution.md)。

## 当前边界

目前主要面向中文及中英文术语混输。语音识别和文字整理可能出现错误，重要内容应核对原稿；回填兼容性取决于目标应用提供的 macOS 辅助功能信息。

项目仍在迭代，尚未完成所有编辑器、Intel 硬件、macOS 14、复杂噪声环境与跨版本升级场景的实机验收。

## 许可证

[MIT License](LICENSE) · Copyright (c) 2026 BruceStyle
