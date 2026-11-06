// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "USBVerifyCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "USBVerifyCore", targets: ["USBVerifyCore"]),
        .library(name: "USBVerifySystem", targets: ["USBVerifySystem"]),
        .executable(name: "usbverify", targets: ["usbverify"]),
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
        // Command-line front end for the same engine the app uses.
        .target(name: "USBVerifyCLI", dependencies: ["USBVerifyCore", "USBVerifySystem"]),
        .executableTarget(name: "usbverify", dependencies: ["USBVerifyCLI"]),
        .testTarget(name: "USBVerifyCLITests", dependencies: ["USBVerifyCLI", "USBVerifyCore"]),
        .testTarget(name: "USBVerifyCoreTests", dependencies: ["USBVerifyCore", "USBVerifySystem"]),
        .testTarget(name: "USBVerifySystemTests", dependencies: ["USBVerifySystem", "USBVerifyCore"]),
    ]
)
