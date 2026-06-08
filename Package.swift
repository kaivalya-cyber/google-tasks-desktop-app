// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GoogleTasks",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "GoogleTasks", targets: ["GoogleTasks"])
    ],
    dependencies: [
        .package(url: "https://github.com/soffes/HotKey", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "GoogleTasks",
            dependencies: ["HotKey"],
            path: "GoogleTasks",
            resources: [
                .process("Info.plist")
            ]
        )
    ]
)
