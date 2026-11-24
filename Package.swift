// swift-tools-version: 6.1
import PackageDescription
import Foundation

let hotspotDependency: Package.Dependency
if let localPath = ProcessInfo.processInfo.environment["LOCAL_HOTSPOT_PATH"], !localPath.isEmpty {
    hotspotDependency = .package(path: localPath)
} else {
    hotspotDependency = .package(url: "https://github.com/notCorwin/Sequoia-Hotspot.git", revision: "c61dbcbca15696b56f14ac8960cbb5ac585d03af")
}

let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let generatedFiles = ["target", "logs", "ExpectedBehavior.excalidraw"].filter {
    FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent($0).path)
}

let package = Package(
    name: "NetworkAuto",
    platforms: [.macOS(.v15)],
    dependencies: [hotspotDependency],
    targets: [
        .executableTarget(
            name: "NetworkAuto",
            dependencies: [.product(name: "HotspotCore", package: "sequoia-hotspot")],
            path: ".",
            exclude: ["Info.plist", "Assets", "AGENTS.md", "README.md", "build.sh", "install.sh", "下拉菜单.md"] + generatedFiles,
            sources: ["NetworkAutoApp.swift", "ClashConnectivity.swift"]
        )
    ]
)
