// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IncrementalComputation",
    products: [
        .library(
            name: "IncrementalComputation",
            targets: ["IncrementalComputation"]),
    ],
    targets: [
        .target(
            name: "IncrementalComputation",
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
