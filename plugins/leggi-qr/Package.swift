// swift-tools-version: 5.9
import PackageDescription

// Quota 120: «Leggi QR» (iPhone e iPad)
let package = Package(
    name: "LeggiQr",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "LeggiQr",
            targets: ["LeggiQRPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0")
    ],
    targets: [
        .target(
            name: "LeggiQRPlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm")
            ],
            path: "ios/Sources/LeggiQRPlugin")
    ]
)
