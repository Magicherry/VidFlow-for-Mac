import CryptoKit
import Foundation
import Testing
@testable import VidFlowCore

// These talk to a server on 127.0.0.1 inside the test process only.

extension VidFlowCoreTests {
    @Suite("HTTPClient proxy")
    struct ProxyTests {
        init() { TestEnv.prepare() }

        @Test(arguments: ["", "http://", "://"])
        func emptyOrInvalidValuesLeaveTheSystemProxyInCharge(value: String) {
            #expect(HTTPClient.proxyDictionary(value) == nil)
        }

        @Test func httpProxy() throws {
            let d = try #require(HTTPClient.proxyDictionary("http://127.0.0.1:7890"))
            #expect(d["HTTPEnable"] as? Int == 1)
            #expect(d["HTTPProxy"] as? String == "127.0.0.1")
            #expect(d["HTTPPort"] as? Int == 7890)
            #expect(d["HTTPSEnable"] as? Int == 1)
            #expect(d["HTTPSProxy"] as? String == "127.0.0.1")
            #expect(d["HTTPSPort"] as? Int == 7890)
            #expect(d["SOCKSEnable"] == nil)
        }

        @Test func schemeIsOptionalAndPortsDefault() throws {
            let bare = try #require(HTTPClient.proxyDictionary("10.0.0.2:8080"))
            #expect(bare["HTTPProxy"] as? String == "10.0.0.2")
            #expect(bare["HTTPPort"] as? Int == 8080)
            #expect(try #require(HTTPClient.proxyDictionary("http://proxy.local"))["HTTPPort"] as? Int == 80)
            #expect(try #require(HTTPClient.proxyDictionary("https://proxy.local"))["HTTPPort"] as? Int == 443)
        }

        @Test func socksProxy() throws {
            let d = try #require(HTTPClient.proxyDictionary("socks5://10.0.0.1:1080"))
            #expect(d["SOCKSEnable"] as? Int == 1)
            #expect(d["SOCKSProxy"] as? String == "10.0.0.1")
            #expect(d["SOCKSPort"] as? Int == 1080)
            #expect(d["HTTPEnable"] == nil)
            #expect(try #require(HTTPClient.proxyDictionary("SOCKS5://h"))["SOCKSPort"] as? Int == 1080)
        }

        @Test func configurationCarriesTheProxyAndUserAgent() {
            let withProxy = HTTPClient.configuration(proxy: "http://127.0.0.1:7890")
            #expect(withProxy.connectionProxyDictionary?["HTTPProxy"] as? String == "127.0.0.1")
            #expect(withProxy.httpAdditionalHeaders?["User-Agent"] as? String == HTTPClient.userAgent)
            #expect(HTTPClient.configuration(proxy: "").connectionProxyDictionary == nil)
        }
    }

    @Suite("FileDownloader")
    struct FileDownloaderTests {
        init() { TestEnv.prepare() }

        static func temp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("vf-dl-\(UUID().uuidString)") }

        @Test func sha256IsLowercaseHex() throws {
            let file = Self.temp()
            defer { try? FileManager.default.removeItem(at: file) }
            try Data("abc".utf8).write(to: file)
            #expect(try FileDownloader.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        }

        @Test(.timeLimit(.minutes(2)))
        func splitsALargeFileOverSeveralConnections() async throws {
            let server = try FileServer(size: 21 << 20, ranges: true)
            defer { server.stop() }
            let dest = Self.temp()
            defer { try? FileManager.default.removeItem(at: dest) }
            let reports = Locked<[Double]>([])
            try await FileDownloader.download(from: server.url, to: dest, http: HTTPClient()) { value in reports.withLock { $0.append(value) } }
            #expect(Array(try Data(contentsOf: dest)) == server.data)
            // 21 MB in 1 MB chunks, plus the first request that finds out the size.
            #expect(server.rangeRequests.current == 1 + 21)
            #expect(reports.current.last == 100)
        }

        @Test(.timeLimit(.minutes(2)))
        func retriesAChunkWhoseConnectionDrops() async throws {
            let server = try FileServer(size: 12 << 20, ranges: true, cutFirst: 2)
            defer { server.stop() }
            let dest = Self.temp()
            defer { try? FileManager.default.removeItem(at: dest) }
            try await FileDownloader.download(from: server.url, to: dest, http: HTTPClient())
            #expect(Array(try Data(contentsOf: dest)) == server.data)
        }

        @Test(.timeLimit(.minutes(2)), arguments: [
            (false, 12 << 20), // no range support
            (true, 3 << 20),   // too small to be worth splitting
        ])
        func fallsBackToOneConnection(ranges: Bool, size: Int) async throws {
            let server = try FileServer(size: size, ranges: ranges)
            defer { server.stop() }
            let dest = Self.temp()
            defer { try? FileManager.default.removeItem(at: dest) }
            try await FileDownloader.download(from: server.url, to: dest, http: HTTPClient())
            #expect(Array(try Data(contentsOf: dest)) == server.data)
            // A one-byte probe, then the download itself.
            #expect(server.requests.current == 2)
        }
    }

    @Suite("Connectivity")
    struct ConnectivityTests {
        init() { TestEnv.prepare() }

        @Test func anyAnswerCountsAsReachable() async throws {
            let server = try LocalServer { _, fd in LocalServer.send(fd, "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n") }
            defer { server.stop() }
            let result = await Connectivity.check(URL(string: "http://127.0.0.1:\(server.port)/generate_204")!, http: HTTPClient(), timeout: 5)
            #expect(result.reachable)
            #expect(result.error == nil)
        }

        @Test func noConnectionIsUnreachable() async {
            // Nothing listens on port 9 (discard) locally: the connection is refused straight away.
            let result = await Connectivity.check(URL(string: "http://127.0.0.1:9/")!, http: HTTPClient(), timeout: 5)
            #expect(!result.reachable)
            #expect(result.error != nil)
        }

        @Test func noAnswerInTimeIsUnreachable() async throws {
            // Accepts the connection but never answers.
            let server = try LocalServer { _, fd in
                var byte: UInt8 = 0
                while read(fd, &byte, 1) > 0 {}
            }
            defer { server.stop() }
            let result = await Connectivity.check(URL(string: "http://127.0.0.1:\(server.port)/")!, http: HTTPClient(), timeout: 0.3)
            #expect(!result.reachable)
            #expect(result.error != nil)
        }

        @Test func needsProxyIsForTheBlockedPlatforms() {
            #expect(Connectivity.needsProxy(.youTube))
            #expect(Connectivity.needsProxy(.x))
            #expect(!Connectivity.needsProxy(.bilibili))
        }
    }
}
