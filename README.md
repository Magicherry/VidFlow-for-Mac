# VidFlow for Mac

[VidFlow](https://github.com/Magicherry/VidFlow) 的 macOS 原生版本：粘贴链接，选好画质，开始下载。支持哔哩哔哩、抖音、小红书、微博、YouTube 与 X。

使用 Swift、SwiftUI 和 AppKit 构建，下载由 yt-dlp、ffmpeg、aria2 完成。需要 macOS 14 或更高版本，通用二进制。

## 安装

打开 `VidFlow-<版本>-macos.dmg`，把 VidFlow 拖到“应用程序”。首次启动时按向导安装组件（约 150 MB）。

## 数据位置

设置、下载记录、组件和日志在 `~/Library/Application Support/VidFlow`，登录信息在钥匙串（名称 `VidFlow sign-in`）。不收集任何使用数据。

## 开发

需要 Xcode 26 或更高版本。

```bash
open VidFlow.xcodeproj
```

```bash
cd Packages/VidFlowCore && swift test
```

```bash
scripts/build-release.sh 1.0.0
```

`build-release.sh` 产出 `dist/` 下的 DMG、更新用 zip 和 `update-macos.json`。设置 `DEVELOPER_ID` 和 `NOTARY_PROFILE` 后会签名并公证，否则是仅供本机使用的 ad-hoc 签名。详见 [发布说明](docs/RELEASE.md)、[架构](docs/ARCHITECTURE.md)、[功能对齐](docs/PARITY.md)。

## 声明

VidFlow 用于个人使用和备份。请仅下载你有权保存的内容，并遵守各平台的服务条款和版权规定。平台名称和标志归其所有者所有。
