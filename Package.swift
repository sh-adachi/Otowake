// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Otowake",
    platforms: [.macOS("14.4")],
    products: [.executable(name: "Otowake", targets: ["Otowake"])],
    targets: [
        .target(name: "AudioRealtime", linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "OtowakeCore", dependencies: ["AudioRealtime"]),
        .executableTarget(name: "Otowake", dependencies: ["OtowakeCore"]),
        .testTarget(name: "OtowakeCoreTests", dependencies: ["OtowakeCore", "AudioRealtime"])
    ],
    swiftLanguageModes: [.v6]
)
