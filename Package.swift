// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Petalo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Petalo", targets: ["PetaloApp"]),
        .executable(name: "petalo-tests", targets: ["PetaloTests"]),
    ],
    targets: [
        .target(
            name: "PetaloCore"
        ),
        .executableTarget(
            name: "PetaloApp",
            dependencies: ["PetaloCore"],
            // swift build does not compile Metal sources, so the shader ships
            // as a prebuilt default.metallib; regenerate it from Ripple.metal
            // with scripts/compile-shaders.sh after editing the source.
            exclude: ["Ripple.metal"],
            resources: [.copy("Resources/default.metallib")]
        ),
        .executableTarget(
            name: "PetaloTests",
            dependencies: ["PetaloCore"],
            path: "Tests/PetaloCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
