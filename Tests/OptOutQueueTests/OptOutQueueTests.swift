import Foundation
import PostHog
import XCTest

final class OptOutQueueTests: XCTestCase {
    private var projectToken = ""
    private var posthog: PostHogSDK!

    override func setUp() {
        projectToken = "phc_repro_\(UUID().uuidString)"
        StubServer.online = true
        posthog = launch()
        posthog.identify("user-123")
    }

    private func launch() -> PostHogSDK {
        let config = PostHogConfig(projectToken: projectToken, host: "https://stub.invalid")
        let session = URLSessionConfiguration.default
        session.protocolClasses = [StubServer.self]
        config.urlSessionConfiguration = session
        config.compression = .none
        config.flushIntervalSeconds = 1
        config.captureApplicationLifecycleEvents = false
        config.preloadFeatureFlags = false
        return PostHogSDK.with(config)
    }

    override func tearDown() {
        posthog.close()
        let storage = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.posthog.unknown")
            .appendingPathComponent(projectToken)
        try? FileManager.default.removeItem(at: storage)
    }

    /// Events captured right before optOut() are sent after it, without the app calling flush().
    func testEventsQueuedBeforeOptOutAreNotSentAfterOptOut() {
        posthog.capture("captured before opt-out")
        posthog.optOut()
        XCTAssertTrue(posthog.isOptOut())
        posthog.capture("captured after opt-out")

        runMainRunLoop(seconds: 5) { !self.delivered.isEmpty }

        XCTAssertEqual(delivered, [], "sent after optOut()")
    }

    /// A user captures events offline, opts out, then reconnects: the earlier events are sent.
    func testEventsQueuedOfflineAreNotSentAfterOptOutOnReconnect() {
        StubServer.online = false
        posthog.capture("captured offline before opt-out")
        runMainRunLoop(seconds: 5) { StubServer.failedBatches(for: self.projectToken) > 0 }
        XCTAssertGreaterThan(StubServer.failedBatches(for: projectToken), 0, "the queue never tried to send while offline")

        posthog.optOut()
        XCTAssertTrue(posthog.isOptOut())
        StubServer.online = true

        runMainRunLoop(seconds: 10) { !self.delivered.isEmpty }

        XCTAssertEqual(delivered, [], "sent after optOut()")
    }

    /// A user opts out offline and quits; the next launch, online, sends the earlier events.
    func testEventsQueuedBeforeOptOutAreNotSentOnNextLaunch() {
        StubServer.online = false
        posthog.capture("captured offline before opt-out")
        posthog.optOut()
        posthog.close()
        runMainRunLoop(seconds: 5) { StubServer.failedBatches(for: self.projectToken) > 0 }
        XCTAssertGreaterThan(StubServer.failedBatches(for: projectToken), 0, "close() never tried to send while offline")

        StubServer.online = true
        posthog = launch()
        XCTAssertTrue(posthog.isOptOut())

        runMainRunLoop(seconds: 5) { !self.delivered.isEmpty }

        XCTAssertEqual(delivered, [], "sent after optOut()")
    }

    private var delivered: [String] {
        StubServer.deliveredEvents(for: projectToken)
    }

    private func runMainRunLoop(seconds: TimeInterval, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !done() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }
}

/// Stands in for the PostHog host. Offline, every request fails with `notConnectedToInternet`.
/// Online, every request gets a 200 and each `/batch` body is recorded as "<event> (distinct_id: <id>)".
final class StubServer: URLProtocol {
    private static let lock = NSLock()
    private static var _online = true
    private static var delivered: [String: [String]] = [:]
    private static var failed: [String: Int] = [:]

    static var online: Bool {
        get { lock.withLock { _online } }
        set { lock.withLock { _online = newValue } }
    }

    static func deliveredEvents(for token: String) -> [String] {
        lock.withLock { delivered[token] ?? [] }
    }

    static func failedBatches(for token: String) -> Int {
        lock.withLock { failed[token] ?? 0 }
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let batch = request.url?.path == "/batch" ? Self.readBatch(request) : nil

        guard Self.online else {
            if let batch {
                Self.lock.withLock { Self.failed[batch.token, default: 0] += 1 }
            }
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        if let batch {
            Self.lock.withLock { Self.delivered[batch.token, default: []] += batch.events }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"status":1}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func readBatch(_ request: URLRequest) -> (token: String, events: [String])? {
        guard let body = request.httpBody ?? request.httpBodyStream.map(readAll),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let token = json["api_key"] as? String,
              let batch = json["batch"] as? [[String: Any]]
        else { return nil }
        let events = batch.map { "\($0["event"] ?? "?") (distinct_id: \($0["distinct_id"] ?? "?"))" }
        return (token, events)
    }

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
