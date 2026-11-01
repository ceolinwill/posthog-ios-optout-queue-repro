// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OptOutQueueRepro",
    platforms: [.macOS(.v10_15), .iOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/PostHog/posthog-ios.git", exact: "3.93.1"),
    ],
    targets: [
        .testTarget(
            name: "OptOutQueueTests",
            dependencies: [.product(name: "PostHog", package: "posthog-ios")]
        ),
    ]
)
