// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IPAInstaller",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "InstallerCore", targets: ["InstallerCore"])],
    targets: [
        .target(name: "CZipSupport", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "InstallerCore", dependencies: ["CZipSupport"]),
        .testTarget(name: "InstallerCoreTests", dependencies: ["InstallerCore", "CZipSupport"])
    ]
)
