// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TestMiserExample",
    products: [.library(name: "Classifier", targets: ["Classifier"])],
    targets: [
        .target(name: "Classifier"),
        .testTarget(name: "ClassifierTests", dependencies: ["Classifier"]),
    ]
)
