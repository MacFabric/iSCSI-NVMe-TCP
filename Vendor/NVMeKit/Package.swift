// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NVMeKit",
    platforms: [.macOS(.v15)],
    products: [
        // The NVMe/TCP initiator engine: PDU codec, capsules, controller and
        // queue actors with recovery, discovery, and a block device.
        .library(name: "NVMeKit", targets: ["NVMeKit"]),
        // A scriptable in-process NVMe/TCP subsystem, for tests and simulators.
        .library(name: "NVMeMockTarget", targets: ["NVMeMockTarget"]),
    ],
    dependencies: [
        // Up to the next minor: before 1.0 a minor release may break API.
        .package(url: "https://github.com/MacFabric/FabricKit", .upToNextMinor(from: "0.1.0")),
    ],
    targets: [
        // Pure protocol logic. No sockets of its own and no side effects:
        // everything here is unit-testable and fuzzable.
        .target(
            name: "NVMeKit",
            dependencies: [.product(name: "FabricKit", package: "FabricKit")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "NVMeMockTarget",
            dependencies: [
                "NVMeKit",
                .product(name: "FabricTestSupport", package: "FabricKit"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Fuzz harness: built normally it's a regression-replay tool;
        // scripts/fuzz.sh rebuilds it with -sanitize=address.
        .executableTarget(
            name: "nvme-pdu-fuzz",
            dependencies: ["NVMeKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NVMeKitTests",
            dependencies: ["NVMeKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NVMeIntegrationTests",
            dependencies: ["NVMeKit", "NVMeMockTarget"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
