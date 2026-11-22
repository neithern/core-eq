// This target supports Swift extension language services. Build the app with Xcode.
// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CoreEQ",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "CoreEQ", targets: ["CoreEQ"]),
    ],
    targets: [
        .executableTarget(
            name: "CoreEQ",
            path: "CoreEQ",
            exclude: ["Resources"],
            swiftSettings: [
                .define("COREEQ_TCC_SPI"),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("InternalImportsByDefault"),
                .enableUpcomingFeature("MemberImportVisibility"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .unsafeFlags(["-enable-upcoming-feature", "ImmutableWeakCaptures"]),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)