// swift-tools-version: 5.9
import PackageDescription

// Quota 120: «Stampa o salva» (iPhone e iPad)
let package = Package(
    name: "StampaSalva",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "StampaSalva",
            targets: ["StampaSalvaPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0")
    ],
    targets: [
        .target(
            name: "StampaSalvaPlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm")
            ],
            path: "ios/Sources/StampaSalvaPlugin")
    ]
)
