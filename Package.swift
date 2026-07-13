// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lattice",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LatticeCore", targets: ["LatticeCore"]),
        .executable(name: "Lattice", targets: ["Lattice"])
    ],
    targets: [
        .target(name: "LatticeCore"),
        .executableTarget(name: "Lattice", dependencies: ["LatticeCore"], linkerSettings: [.linkedFramework("Security")]),
        .testTarget(name: "LatticeCoreTests", dependencies: ["LatticeCore"])
    ]
)
