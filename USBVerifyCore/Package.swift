// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "USBVerifyCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "USBVerifyCore", targets: ["USBVerifyCore"]),
        .library(name: "USBVerifySystem", targets: ["USBVerifySystem"]),
    ],
    targets: [
        .target(name: "USBVerifyCore"),
        // Real macOS adapters for the ports in USBVerifyCore: DiskArbitration, IOKit, diskutil, notifications, power.
        .target(
            name: "USBVerifySystem",
            dependencies: ["USBVerifyCore"],
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(name: "USBVerifyCoreTests", dependencies: ["USBVerifyCore"]),
        .testTarget(name: "USBVerifySystemTests", dependencies: ["USBVerifySystem", "USBVerifyCore"]),
    ]
)
