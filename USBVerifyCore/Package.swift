// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "USBVerifyCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "USBVerifyCore", targets: ["USBVerifyCore"]),
    ],
    targets: [
        .target(name: "USBVerifyCore"),
        .testTarget(name: "USBVerifyCoreTests", dependencies: ["USBVerifyCore"]),
    ]
)
