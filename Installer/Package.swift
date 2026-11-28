// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IPAInstaller",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "InstallerCore", targets: ["InstallerCore"]),
               .library(name: "ConnectionNativeABI", targets: ["CConnectionABI"]),
               .library(name: "ConnectionExperimentCore", targets: ["ConnectionExperimentCore"])],
    targets: [
        .systemLibrary(name: "CConnectionABI"),
        .target(name: "ConnectionExperimentCore"),
        .testTarget(name: "ConnectionExperimentTests", dependencies: ["ConnectionExperimentCore"]),
        .target(name: "CZipSupport", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "InstallerCore", dependencies: ["CZipSupport"]),
        .testTarget(name: "InstallerCoreTests", dependencies: ["InstallerCore", "CZipSupport"])
    ]
)
