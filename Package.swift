// swift-tools-version: 6.2
import Foundation
import PackageDescription

let sparkle = Context.packageDirectory + "/vendor/Sparkle"
let testingPlugins = [
    "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing",
    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing",
].filter { FileManager.default.fileExists(atPath: $0) }.flatMap { ["-plugin-path", $0] }

let package = Package(
    name: "Murmur",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
    ],
    targets: [
        .executableTarget(
            name: "Murmur",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-F", sparkle]),
            ],
            linkerSettings: [
                .unsafeFlags(["-F", sparkle, "-framework", "Sparkle",
                              "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                              "-Xlinker", "-rpath", "-Xlinker", sparkle]),
            ]
        ),
        .testTarget(
            name: "MurmurTests",
            dependencies: ["Murmur"],
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-F", sparkle] + testingPlugins)],
            linkerSettings: [
                .unsafeFlags(["-F", sparkle, "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", sparkle]),
            ]
        ),
    ]
)
