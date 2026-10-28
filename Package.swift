// swift-tools-version: 6.0
// SafeRetry — A composable resilience library for Swift.

import Foundation
import PackageDescription

let package = Package(
    name: "SafeRetry",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(
            name: "SafeRetry",
            targets: ["SafeRetry"]
        ),
    ],
    targets: [
        .target(
            name: "SafeRetry",
            swiftSettings: [
                // `.v6` already implies complete strict-concurrency checking,
                // so no `StrictConcurrency` upcoming-feature flag is needed.
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "SafeRetryTests",
            dependencies: ["SafeRetry"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)

// MARK: - Documentation

// `swift package generate-documentation` needs swift-docc-plugin, which is a
// build-time plugin and contributes nothing to the built library. It is opted
// into with an environment variable so that packages depending on SafeRetry
// never resolve it: the library stays genuinely dependency-free for consumers.
//
//     SAFERETRY_BUILD_DOCS=1 swift package generate-documentation --target SafeRetry
//
if ProcessInfo.processInfo.environment["SAFERETRY_BUILD_DOCS"] != nil {
    package.dependencies += [
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0"),
    ]
}
