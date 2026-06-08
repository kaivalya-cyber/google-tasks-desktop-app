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
    targets: [
        .executableTarget(
            name: "GoogleTasks",
            path: "GoogleTasks",
            resources: [
                .process("Info.plist")
            ]
        )
    ]
)
