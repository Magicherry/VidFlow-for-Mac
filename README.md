# VidFlow for Mac

[VidFlow](https://github.com/Magicherry/VidFlow) 的 macOS 原生版本：粘贴链接，选好画质，开始下载。支持哔哩哔哩、抖音、小红书、微博、YouTube 与 X。

简体中文 · [English](README.en.md)

> **测试阶段。** 目前的版本未经 Apple 公证，也还不能在 App 内自动安装更新。抖音、微博、小红书和账号登录尚未用真实链接和账号验证，可能无法正常工作。

## 功能

- **下载内容：** 视频、仅音频（MP3、M4A、Opus、FLAC、WAV）或封面；可解析播放列表、合集，也可一次粘贴多个链接。
- **画质与格式：** 按视频实际提供的选项选择，支持 4K、60fps、HDR，H.264、H.265、AV1，MP4、MKV、WebM，以及多语言音轨和字幕。
- **下载队列：** 暂停、继续、限速、同时下载多个；网络失败自动重试，下载停滞自动重启，磁盘空间不足时暂停，重启后接着下载。
- **模板：** 内置 5 个预设，也可以自建，并设置文件命名和子文件夹。
- **账号：** B 站扫码登录，YouTube、抖音网页登录，登录信息保存在钥匙串。
- **Mac 原生：** SwiftUI 界面，深浅色、Dock 进度、通知、菜单栏、拖放链接、中英文。

## 安装

需要 macOS 14 或更高版本。Apple Silicon 和 Intel 通用，但 Intel 机型还没有实际运行过。

1. 从 [Releases](https://github.com/Magicherry/VidFlow-for-Mac/releases) 下载 `VidFlow-<版本>-macos.dmg`。
2. 打开后把 VidFlow 拖到“应用程序”。
3. 第一次打开时，系统会提示无法验证开发者。前往“系统设置 › 隐私与安全性”，在页面下方点“仍要打开”。
4. 按向导安装组件（约 150 MB）。

新版本暂时需要手动下载，App 会在有新版本时提示。

## 数据与隐私

设置、下载记录、组件和日志在 `~/Library/Application Support/VidFlow`，登录信息在钥匙串（名称 `VidFlow sign-in`）。VidFlow 不收集任何使用数据。

## 开发

需要 Xcode 26 或更高版本。

```bash
open VidFlow.xcodeproj
```

```bash
cd Packages/VidFlowCore && swift test
```

```bash
scripts/build-release.sh 1.0.1
```

详见 [架构](docs/ARCHITECTURE.md)、[功能对齐](docs/PARITY.md)、[发布](docs/RELEASE.md)。

## 许可

VidFlow for Mac 自身的代码使用 [MIT 许可](LICENSE)。随 App 提供的 aria2 是独立程序，使用 GPL，详见 [第三方声明](VidFlow/Resources/ThirdPartyNotices.txt)。

## 声明

VidFlow 用于个人使用和备份。请仅下载你有权保存的内容，并遵守各平台的服务条款和版权规定。平台名称和标志归其所有者所有，仅用于标识相应平台。
