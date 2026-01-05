// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IncrementalComputation",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(
            name: "IncrementalComputation",
            targets: ["IncrementalComputation"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-collections",
            .upToNextMinor(from: "1.3.0")
        )
    ],
    targets: [
        .target(
            name: "IncrementalComputation",
            dependencies: [
                .product(name: "HashTreeCollections", package: "swift-collections")
            ],
            path: "Sources/IncrementalComputation"
        ),
        .testTarget(
            name: "IncrementalComputationTests",
            dependencies: ["IncrementalComputation"],
            path: "Tests/IncrementalComputationTests"
        ),
        .executableTarget(
            name: "SpreadsheetExample",
            dependencies: ["IncrementalComputation"],
            path: "Examples/Spreadsheet"
        ),
    ]
)
