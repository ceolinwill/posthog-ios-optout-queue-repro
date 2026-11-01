# posthog-ios: events queued before `optOut()` are still sent after it

Reported upstream: [PostHog/posthog-ios#1003](https://github.com/PostHog/posthog-ios/issues/1003)

`optOut()` stops new captures, but events already in the SDK's on-disk queue are still uploaded afterwards: the queue's flushes (its timer, the reachability callback, `flush()`) check only connectivity and retry backoff, never opt-out, and there's no public API to drop the queue. So events a user generated before opting out, such as while offline, go to PostHog after they opt out, as soon as the device is back online or on the next launch. Each one carries the user's `distinct_id`.

## Reproduction

```sh
git clone https://github.com/ceolinwill/posthog-ios-optout-queue-repro
cd posthog-ios-optout-queue-repro
swift test
```

The tests point the SDK at a `URLProtocol` stub through `PostHogConfig.urlSessionConfiguration`, so nothing leaves the machine. "Offline" means the stub fails every request with `URLError(.notConnectedToInternet)`; "online" means it answers `200 {"status":1}` and records each `/batch` body. `compression = .none` keeps the bodies readable. No test calls `flush()`.

Each test starts with `PostHogSDK.with(config)` and `identify("user-123")`, then:

- `testEventsQueuedBeforeOptOutAreNotSentAfterOptOut`: `capture(...)`, `optOut()`, `capture(...)`, wait up to 5 seconds.
- `testEventsQueuedOfflineAreNotSentAfterOptOutOnReconnect`: go offline, `capture(...)`, wait for the queue's failed upload, `optOut()`, go back online, wait up to 10 seconds.
- `testEventsQueuedBeforeOptOutAreNotSentOnNextLaunch`: go offline, `capture(...)`, `optOut()`, `close()`, wait for its failed upload, go back online, set up a new instance with the same project token (`isOptOut()` is `true`), wait up to 5 seconds.

Output on 3.93.1 (paths shortened):

```
Test Case '-[OptOutQueueTests.OptOutQueueTests testEventsQueuedBeforeOptOutAreNotSentAfterOptOut]' started.
OptOutQueueTests.swift:45: error: -[OptOutQueueTests.OptOutQueueTests testEventsQueuedBeforeOptOutAreNotSentAfterOptOut] : XCTAssertEqual failed: ("["$identify (distinct_id: user-123)", "captured before opt-out (distinct_id: user-123)"]") is not equal to ("[]") - sent after optOut()
Test Case '-[OptOutQueueTests.OptOutQueueTests testEventsQueuedBeforeOptOutAreNotSentAfterOptOut]' failed (0.200 seconds).
Test Case '-[OptOutQueueTests.OptOutQueueTests testEventsQueuedBeforeOptOutAreNotSentOnNextLaunch]' started.
OptOutQueueTests.swift:79: error: -[OptOutQueueTests.OptOutQueueTests testEventsQueuedBeforeOptOutAreNotSentOnNextLaunch] : XCTAssertEqual failed: ("["$identify (distinct_id: user-123)", "captured offline before opt-out (distinct_id: user-123)"]") is not equal to ("[]") - sent after optOut()
Test Case '-[OptOutQueueTests.OptOutQueueTests testEventsQueuedBeforeOptOutAreNotSentOnNextLaunch]' failed (0.225 seconds).
Test Case '-[OptOutQueueTests.OptOutQueueTests testEventsQueuedOfflineAreNotSentAfterOptOutOnReconnect]' started.
OptOutQueueTests.swift:61: error: -[OptOutQueueTests.OptOutQueueTests testEventsQueuedOfflineAreNotSentAfterOptOutOnReconnect] : XCTAssertEqual failed: ("["$identify (distinct_id: user-123)", "captured offline before opt-out (distinct_id: user-123)"]") is not equal to ("[]") - sent after optOut()
Test Case '-[OptOutQueueTests.OptOutQueueTests testEventsQueuedOfflineAreNotSentAfterOptOutOnReconnect]' failed (1.066 seconds).
	 Executed 3 tests, with 3 failures (0 unexpected) in 1.503 (1.503) seconds
```

The event captured after `optOut()` is dropped, as documented. The ones captured before it are uploaded under the user's `distinct_id`. All three failed in each of 5 runs.

## Expected

After `optOut()`, nothing the user generated is sent: `optOut()` clears (or holds back) what's queued, or the SDK offers a public way to clear the queues so an app can do it when the user opts out. The three tests then pass.

## Actual

Everything queued before `optOut()` is uploaded after it. Pinned to 3.93.1:

- [`PostHogSDK.optOut()`](https://github.com/PostHog/posthog-ios/blob/990479a3a4ef860f78099ead840b636fd7849c2e/PostHog/PostHogSDK.swift#L2849-L2875) sets `config.optOut`, persists it and uninstalls integrations. It doesn't touch `queue`, `replayQueue` or `logsQueue`.
- [`PostHogQueue.flush()`](https://github.com/PostHog/posthog-ios/blob/990479a3a4ef860f78099ead840b636fd7849c2e/PostHog/PostHogQueue.swift#L318-L332), reached from the [flush timer and the reachability callback](https://github.com/PostHog/posthog-ios/blob/990479a3a4ef860f78099ead840b636fd7849c2e/PostHog/PostHogQueue.swift#L215-L275), gates only on [`canFlush()`](https://github.com/PostHog/posthog-ios/blob/990479a3a4ef860f78099ead840b636fd7849c2e/PostHog/PostHogQueue.swift#L519-L536) (reachability pause and retry backoff), so it sends whatever is on disk.
- [`setup()`](https://github.com/PostHog/posthog-ios/blob/990479a3a4ef860f78099ead840b636fd7849c2e/PostHog/PostHogSDK.swift#L293-L310) creates and starts the queues whether or not the stored state is opted out, so the next launch sends them too.
- [`PostHogQueue.clear()`](https://github.com/PostHog/posthog-ios/blob/990479a3a4ef860f78099ead840b636fd7849c2e/PostHog/PostHogQueue.swift#L277-L285) exists but is internal ("used for testing").

## Environment

- posthog-ios 3.93.1 (`990479a`), the latest release on 2026-11-01, via Swift Package Manager
- macOS 27.2 (arm64), Xcode 27.2, Swift 6.4.2

## Related

- Android has the same behavior: [PostHog/posthog-android#919](https://github.com/PostHog/posthog-android/issues/919)
