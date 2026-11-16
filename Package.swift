// swift-tools-version: 6.0
import PackageDescription

// The protocol engines and the layer under them, each its own package.
let iSCSIKit: Target.Dependency = .product(name: "iSCSIKit", package: "iSCSIKit")
let NVMeKit: Target.Dependency = .product(name: "NVMeKit", package: "NVMeKit")
let iSCSIMockTarget: Target.Dependency = .product(name: "iSCSIMockTarget", package: "iSCSIKit")
let NVMeMockTarget: Target.Dependency = .product(name: "NVMeMockTarget", package: "NVMeKit")

let package = Package(
    name: "iSCSI",
    platforms: [.macOS(.v15)],
    // The Xcode targets (iSCSIFSExtension, and anything else that links shared
    // types) can only consume a target if it is a *product*; as a bare target
    // it resolves to "Missing package product". The protocol engines are
    // products of their own packages, which apps/project.yml names directly.
    products: [
        // This app's own shared code: the XPC contract and models, the error
        // domain, mount and attach helpers, auto-attach, the read cache.
        .library(name: "InitiatorShared", targets: ["InitiatorShared"]),
        // Same reason, for the Xcode `iscsid` target: the daemon executable is
        // built and signed by Xcode now, so that notarization covers it, and an
        // Xcode target can only link a package *product*. Named ...Kit to keep
        // it distinguishable from the `iscsid` executable that consumes it.
        .library(name: "iSCSIDaemonKit", targets: ["iSCSIDaemon"]),
        // The FSKit extension's data path, minus the FSKit. Split out of
        // iSCSIFSExtension.swift so `swift test` can reach it: read-modify-write,
        // the chunk cache wiring, the ioLock and every XPC call the volume makes
        // were 600 lines of shipping code inside an Xcode target, which no test
        // in this package could see.
        .library(name: "iSCSIVolume", targets: ["iSCSIVolume"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        // The protocol engines. Up to the next minor, because before 1.0 a
        // minor release may break API; Package.resolved pins the exact
        // version, and apps/project.yml must name the same one (CLAUDE.md).
        .package(url: "https://github.com/MacFabric/iSCSIKit", .upToNextMinor(from: "0.1.0")),
        .package(url: "https://github.com/MacFabric/NVMeKit", .upToNextMinor(from: "0.1.0")),
    ],
    targets: [
        // Everything the app, the daemon, the FSKit extension and iscsictl
        // share that is not protocol: no FSKit and no XPC connection of its
        // own, so `swift test` reaches all of it.
        .target(
            name: "InitiatorShared",
            dependencies: [iSCSIKit, NVMeKit],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Daemon core as a library so it can be unit-tested; the executable is
        // a thin XPC/launchd launcher on top.
        .target(
            name: "iSCSIDaemon",
            dependencies: ["InitiatorShared", iSCSIKit, NVMeKit],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // No FSKit dependency, deliberately and verifiably: the extension keeps
        // everything that conforms to FSKit and imports this for the rest.
        .target(
            name: "iSCSIVolume",
            dependencies: ["InitiatorShared", iSCSIKit],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "iscsid",
            dependencies: ["InitiatorShared", iSCSIKit, "iSCSIDaemon"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "iscsictl",
            dependencies: [
                "InitiatorShared",
                iSCSIKit,
                NVMeKit,
                // dext-attach drives DaemonCore + DextBridge directly.
                "iSCSIDaemon",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // Here and nowhere else: `swift run` keeps the commands that
                // write to a target directly, and the bundled Xcode build,
                // which does not define this, cannot include them by accident.
                .define("ISCSICTL_DESTRUCTIVE"),
            ]
        ),
        // Local iSCSI and NVMe/TCP target: loopback benchmarking without the
        // transport ceiling, plus faults (drop / corrupt / stall / target
        // power loss) that a real NAS cannot be asked to perform on demand.
        .executableTarget(
            name: "iscsi-target-sim",
            dependencies: [
                iSCSIKit,
                NVMeKit,
                iSCSIMockTarget,
                NVMeMockTarget,
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "iscsictlTests",
            dependencies: ["iscsictl", "InitiatorShared", iSCSIKit],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "InitiatorSharedTests",
            dependencies: ["InitiatorShared"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The daemon, the volume data path and the XPC service against mock
        // targets. The protocol engines' own integration suites live in their
        // packages.
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "InitiatorShared", iSCSIKit, NVMeKit, iSCSIMockTarget, NVMeMockTarget,
                "iSCSIDaemon", "iSCSIVolume",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
