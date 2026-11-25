// swift-tools-version: 6.1
import PackageDescription
import Foundation

let hotspotDependency: Package.Dependency
if let localPath = ProcessInfo.processInfo.environment["LOCAL_HOTSPOT_PATH"], !localPath.isEmpty {
    hotspotDependency = .package(path: localPath)
} else {
    hotspotDependency = .package(url: "https://github.com/notCorwin/Sequoia-Hotspot.git", revision: "c61dbcbca15696b56f14ac8960cbb5ac585d03af")
}

let package = Package(
    name: "NetworkAuto",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NetworkAutoCore", targets: ["NetworkAutoCore"]),
        .executable(name: "NetworkAuto", targets: ["NetworkAuto"])
    ],
    dependencies: [hotspotDependency],
    targets: [
        .target(
            name: "NetworkAutoCore",
            dependencies: [.product(name: "HotspotCore", package: "sequoia-hotspot")]
        ),
        .executableTarget(
            name: "NetworkAuto",
            dependencies: [
                "NetworkAutoCore",
                .product(name: "HotspotCore", package: "sequoia-hotspot")
            ]
        ),
        .testTarget(
            name: "NetworkAutoTests",
            dependencies: [
                "NetworkAutoCore",
                .product(name: "HotspotCore", package: "sequoia-hotspot")
            ]
        )
    ]
)
