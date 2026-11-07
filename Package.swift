// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TymeClone",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TymeClone",
            path: "Sources/TymeClone"
        ),
        .testTarget(name: "TymeCloneTests", dependencies: ["TymeClone"])
    ]
)
