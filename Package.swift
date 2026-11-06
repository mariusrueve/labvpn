// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LabVPN",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LabVPNCore", targets: ["LabVPNCore"]),
        .executable(name: "labvpn", targets: ["labvpn"]),
        .executable(name: "labvpn-helper", targets: ["labvpn-helper"]),
        .executable(name: "LabVPNApp", targets: ["LabVPNApp"]),
    ],
    targets: [
        .target(name: "LabVPNCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "labvpn", dependencies: ["LabVPNCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "labvpn-helper", dependencies: ["LabVPNCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "LabVPNApp", dependencies: ["LabVPNCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "LabVPNCoreTests", dependencies: ["LabVPNCore"]),
    ]
)
