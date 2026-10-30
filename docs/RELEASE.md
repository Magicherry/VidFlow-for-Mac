# 发布

## 前提

- Apple Developer Program 成员资格和 **Developer ID Application** 证书。
- 公证凭据：`xcrun notarytool store-credentials vidflow --apple-id … --team-id … --password <App 专用密码>`

## 本地发布

```bash
DEVELOPER_ID="Developer ID Application: 姓名 (TEAMID)" NOTARY_PROFILE=vidflow scripts/build-release.sh 1.0.0
```

脚本依次运行测试、构建通用二进制、以 Hardened Runtime 签名（先 helper 后 App）、公证并装订 App 和 DMG，最后生成更新清单。

## GitHub Actions

`.github/workflows/macos.yml` 平时推送不运行。测试和构建要在 Actions 页面手动触发；推送 `v*` 标签时签名、公证并创建 Release，这一步不会先跑测试，发布前请自行运行。需要的 secrets：
`DEVELOPER_ID_P12_BASE64`、`DEVELOPER_ID_P12_PASSWORD`、`DEVELOPER_ID_NAME`、`APPLE_ID`、`APPLE_TEAM_ID`、`APPLE_APP_PASSWORD`。

测试和构建部分已在 GitHub 上跑通；签名、公证和发布部分还没有运行过。

## 与 Windows 版的关系

Mac 版在独立仓库 `Magicherry/VidFlow-for-Mac` 发布，版本号和 Release 都与 Windows 版互不影响。App 从该仓库的
`releases/latest/download/update-macos.json` 读取更新清单，所以每个 Release 都要上传 `dist/` 下的全部文件。
要换仓库名，请修改 `UpdateService.manifestSource`、`scripts/build-release.sh` 的 `BASE_URL`，以及设置和帮助菜单里的链接。

## 更新 aria2

修改 `scripts/build-aria2.sh` 中的版本号并运行，然后提交 `Helpers/aria2c`。aria2 是 GPL-2.0，发布时需提供对应的源码途径（脚本里的上游地址）。
