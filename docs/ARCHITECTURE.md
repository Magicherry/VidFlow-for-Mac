# VidFlow for Mac 架构

## 技术方案比较

| | A. SwiftUI + Swift 业务层（已选） | B. SwiftUI + .NET Core 业务层 |
|---|---|---|
| 维护 | 业务逻辑两份，但 Core 只有约 3000 行，且多为纯函数；由移植的单元测试约束行为 | 逻辑一份，但多一层进程通信协议，两端都要维护 |
| 部署 | App 仅 14 MB，只有一个进程模型 | 需内嵌 .NET 运行时（通用二进制约多 100 MB+），每个 dylib 都要签名公证 |
| 性能 | 启动快；重活本来就在 yt-dlp / ffmpeg 子进程里 | 多一个常驻进程和一层序列化，Core 并不做重计算，收益为零 |
| 扩展 | 可直接用 Keychain、WKWebView、SMAppService、Dock | 平台能力仍要写 Swift，C# 侧 WebView2、Job Object 等本就要重写 |

C# Core 中真正可复用的是**规则**，不是代码：yt-dlp 参数、输出解析、错误映射。这些规则 1:1 移植，
C# 测试用例也随之移植，期望值保持不变。字符串表 `Strings.tsv` 与 Windows 版同格式、可直接同步。

## 目录

| 路径 | 内容 |
|---|---|
| `Packages/VidFlowCore` | 无 UI 业务层（Swift 6 严格并发）：参数构建、输出解析、进程、组件、账号保险库、更新 |
| `VidFlow/App` | 入口、`AppModel`、菜单命令、Debug 驱动（只编入 Debug） |
| `VidFlow/Services` | 下载队列、Dock、通知、剪贴板、登录项、组件与更新模型、WKWebView 会话 |
| `VidFlow/Views` | SwiftUI 界面 |
| `Helpers/aria2c` | `scripts/build-aria2.sh` 由未修改的源码构建的通用二进制，只依赖系统库 |

工程使用 Xcode 文件夹同步组，新增文件无需改动 `project.pbxproj`。

## 与 Windows 不同的实现

| 能力 | Windows | macOS |
|---|---|---|
| 进程树管理 | Job Object | 独立进程组（`posix_spawn`），SIGTERM 后升级 SIGKILL；PID 记录在文件中，下次启动清理崩溃遗留 |
| 登录信息 | `cookies.txt` | Keychain 保存；运行时写入 0700 临时目录的 0600 文件供 yt-dlp 读取，退出时写回并删除 |
| 内嵌浏览器 | WebView2 | WKWebView（数据只在内存，每次启动从 Keychain 恢复） |
| 抖音响应读取 | WebView2 响应事件 | WKWebView 无此 API，改为文档开始时注入脚本，包装 fetch / XHR |
| ffmpeg 来源 | yt-dlp/FFmpeg-Builds | 该项目没有 macOS 版，改用 ffmpeg.martin-riedl.de（静态构建，有 SHA-256），不可用时退回 eugeneware/ffmpeg-static |
| aria2 来源 | 官方发布 | 官方没有 macOS 版，随 App 提供 |
| 自更新 | Inno Setup 安装器 | zip + SHA-256 + 开发者签名校验，退出后由脚本替换 |
| 托盘 | 通知区域 | 关闭窗口继续下载 + Dock 进度 + 可选菜单栏项 |

## 为什么不用 App Sandbox

沙盒 App 不能执行自行下载的 yt-dlp / ffmpeg，组件必须能独立于 App 更新（站点一变 yt-dlp 就得更新），
因此不上架 Mac App Store，走 Developer ID + Hardened Runtime + 公证。下载的工具不带隔离属性，
也不在 App 包内，公证不涉及它们。

## 目标系统

部署目标 macOS 14，优先 Apple Silicon，同时产出 x86_64（通用二进制）。使用系统控件，
以 macOS 26+ SDK 构建时由系统自动采用 Liquid Glass；没有手工模拟玻璃效果。
