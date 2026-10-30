#if DEBUG
import AppKit
import VidFlowCore

/// Debug builds only: lets scripts/drive.swift operate the running app through the same model the UI uses, and photograph
/// its windows without needing Screen Recording permission. Not compiled into release builds.
final class DebugDriver {
    static let shared = DebugDriver()
    private var observer: NSObjectProtocol?

    func start() {
        observer = DistributedNotificationCenter.default().addObserver(forName: .init("VidFlowDebug"), object: nil, queue: .main) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated { DebugDriver.shared.run(command) }
        }
    }

    private func run(_ command: String) {
        let model = AppModel.shared
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts.first {
        case "sidebar":
            model.sidebar = switch arg {
            case "new": .newDownload
            case "templates": .templates
            case "accounts": .accounts
            case "active": .downloads(.active)
            case "completed": .downloads(.completed)
            case "failed": .downloads(.failed)
            default: .downloads(.all)
            }
            model.showMainWindow()
        case "settings":
            model.openSettings(SettingsTab(rawValue: arg) ?? .general)
        case "links":
            model.open(links: arg)
        case "download":
            model.composer.requestDownload()
        case "firstrun":
            model.showFirstRun = arg == "on"
            if arg == "off" { model.settings.firstRunCompleted = true }
        case "install":
            Task { await model.components.install(model.components.missing) }
        case "refresh":
            Task { await model.components.refresh(remote: true) }
        case "option":
            let kv = arg.split(separator: "=", maxSplits: 1).map(String.init)
            setOption(kv[0], kv.count > 1 ? kv[1] : "")
        case "pause": model.downloads.items.first(where: \.canPause).map(model.downloads.pause)
        case "resume": model.downloads.items.first(where: \.canResume).map(model.downloads.resume)
        case "cancel": model.downloads.items.first(where: \.canCancel).map(model.downloads.cancel)
        case "retry": model.downloads.items.first(where: \.canRetry).map(model.downloads.retry)
        case "clear": model.downloads.clearFinished()
        case "appearance":
            model.settings.theme = arg
        case "size":
            let wh = arg.split(separator: "x").compactMap { Double($0) }
            NSApp.windows.first { $0.title != "" && $0.isVisible && !($0 is NSPanel) }?.setContentSize(NSSize(width: wh[0], height: wh[1]))
        case "snap":
            snap(to: arg)
        case "dump":
            dump(to: arg)
        case "quit":
            model.updates.isInstallingNow = true // skips the confirmation
            NSApp.terminate(nil)
        case "dup":
            model.composer.resolveDuplicates(downloadAgain: arg == "again")
        case "refreshfiles":
            model.downloads.refreshFiles()
        case "network":
            model.downloads.networkChanged(online: arg == "on")
        case "repair":
            Task { await model.components.repair() }
        case "diag":
            Task {
                let report = Diagnostics.report(appVersion: "test", tools: model.components.components.map { ($0.tool.rawValue, $0.version, model.tools.path($0.tool)) })
                try? await Diagnostics.export(to: URL(fileURLWithPath: arg), report: report, settings: model.settings)
            }
        case "fakefree":
            model.downloads.debugFreeBytes = Int64(arg).map { $0 << 20 }
        case "stress":
            stress(Int(arg) ?? 5000)
        case "cookiestore":
            model.vault.store([CookieRecord(domain: ".bilibili.com", path: "/", name: "SESSDATA", value: "fake", secure: true, httpOnly: true, expires: 1_900_000_000)])
            model.accountsRevision += 1
        case "cookiecheck":
            Task {
                await WebSession.prepare()
                let inProfile = await WebSession.hasSessionCookie(.bilibili)
                let before = model.vault.isLoggedIn(.bilibili)
                await model.signOut(.bilibili)
                let text = "keychain=\(before) profile=\(inProfile) afterSignOut=\(model.vault.isLoggedIn(.bilibili)) stored=\(KeychainSecret().read() != nil) cookies=\(await WebSession.allCookies().count)"
                try? text.write(toFile: arg, atomically: true, encoding: .utf8)
            }
        case "login":
            Task { await LoginWindowController.show(arg == "douyin" ? .douyin : arg == "youtube" ? .youTube : .bilibili) }
        case "language":
            model.settings.language = arg
        case "installtool":
            if let c = model.components.components.first(where: { $0.tool.rawValue == arg }) {
                Task { await model.components.install([c]) }
            }
        case "tree":
            var out: [String] = []
            for w in NSApp.windows where w.isVisible { if let v = w.contentView { tree(v, 0, &out) } }
            try? out.joined(separator: "\n").write(toFile: arg, atomically: true, encoding: .utf8)
        default:
            Log.warn("Debug driver: unknown command \(command)")
        }
    }

    private func tree(_ v: NSView, _ depth: Int, _ out: inout [String]) {
        guard depth < 12 else { return }
        let name = String(describing: type(of: v))
        if v is NSSplitView || name.contains("Split") || name.contains("Inspector") || name.contains("Table") || name.contains("Sidebar") || v is NSTextField {
            let text = (v as? NSTextField)?.stringValue ?? ""
            out.append(String(repeating: " ", count: depth) + "\(name.prefix(50)) \(Int(v.frame.minX)),\(Int(v.frame.width))x\(Int(v.frame.height)) hidden=\(v.isHidden) \(text)")
        }
        for sub in v.subviews { tree(sub, depth + 1, &out) }
    }

    /// Adds finished rows and logs how long the work a row change triggers takes.
    private func stress(_ count: Int) {
        let downloads = AppModel.shared.downloads
        let t0 = Date()
        downloads.batch {
            for i in 0..<count {
                let r = DownloadRequest(url: "https://www.youtube.com/watch?v=stress\(i)", mode: "audio", maxHeight: 0, writeSubtitles: false, outputFolder: "/tmp/vf-stress")
                downloads.enqueue(r, title: "Stress \(i)", thumbnailURL: nil)
            }
            downloads.pauseAll()
        }
        let t1 = Date()
        let filter = DownloadFilter(query: "99")
        let shown = downloads.items.filter { filter.matches(state: $0.state, title: $0.title, url: $0.request.url, platform: $0.platform) }
            .sorted(using: [DownloadSort(field: .added, order: .reverse)])
        let t2 = Date()
        let records = downloads.items.map(\.record)
        DownloadStore.save(records)
        Log.info(String(format: "Stress %d: add %.0f ms, filter+sort %.1f ms (%d rows), save %.0f ms", count, t1.timeIntervalSince(t0) * 1000, t2.timeIntervalSince(t1) * 1000, shown.count, Date().timeIntervalSince(t2) * 1000))
    }

    private func setOption(_ key: String, _ value: String) {
        let c = AppModel.shared.composer
        switch key {
        case "mode": c.options.mode = value
        case "height": c.options.maxHeight = Int(value) ?? 0
        case "codec": c.options.codec = value
        case "container": c.options.container = value
        case "audio": c.options.audioFormat = value
        case "subs": c.options.subtitles = value == "1"
        case "folder": AppModel.shared.settings.downloadFolder = value
        case "proxy": AppModel.shared.settings.proxy = value
        case "speed": AppModel.shared.settings.speedLimitKBps = Int(value) ?? 0
        case "concurrent": AppModel.shared.settings.maxConcurrent = Int(value) ?? 2
        default: break
        }
    }

    /// Draws each visible window's frame view (title bar and toolbar included) into a PNG.
    private func snap(to prefix: String) {
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview, view.bounds.width > 60 else { continue }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let name = window.title.isEmpty ? "window\(i)" : window.title.replacingOccurrences(of: "/", with: "-")
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
        }
    }

    private func dump(to path: String) {
        let model = AppModel.shared
        let c = model.composer
        let result: String = switch c.result {
        case .empty: "empty"
        case .loading: "loading"
        case .video(let v): "video: \(v.title) | \(v.qualities.map(\.height)) | \(v.codecs) | \(v.hdrKinds) | langs \(v.audioLanguages.count)"
        case .playlist(let p): "playlist: \(p.title) | \(p.entries.count) entries"
        case .batch: "batch: \(c.batch.map { "\($0.isLoading ? "loading" : $0.failed ? "failed" : "ok") \($0.title)" })"
        }
        var lines = ["composer: \(result)", "message: \(c.message?.text ?? "-")", "window: \(NSApp.windows.map { "\($0.title)[\($0.isVisible) \(Int($0.frame.width))x\(Int($0.frame.height))]" })", "inspector: \(model.showOptionsInspector) duplicates: \(c.confirmDuplicates?.count ?? -1)"]
        lines += model.components.components.map { "tool \($0.tool.rawValue): \($0.state) \($0.version ?? "-") latest \($0.latest ?? "-") path \(model.tools.path($0.tool) ?? "-") \(Int($0.progress ?? -1))%" }
        lines.append("install: installing=\(model.components.installing) \(model.components.lastResult?.message ?? "-")")
        lines += model.downloads.items.map { i in
            "dl [\(i.state.rawValue)] \(String(format: "%.1f", i.progress))% \(Int(i.speed))B/s eta \(Int(i.eta)) | \(i.title) | \(i.statusText) | \(i.filePath ?? "-") | \(i.errorDetail?.suffix(300) ?? "-")"
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
#endif
