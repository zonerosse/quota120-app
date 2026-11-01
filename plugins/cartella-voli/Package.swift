// swift-tools-version: 5.9
import PackageDescription

// Quota 120: cartella dei voli di DJI Fly (solo iPhone e iPad)
let package = Package(
    name: "CartellaVoli",
    platforms: [.iOS(.v15)],
    products: [
        .library(
            name: "CartellaVoli",
            targets: ["CartellaVoliPlugin"])
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0")
    ],
    targets: [
        .target(
            name: "CartellaVoliPlugin",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm")
            ],
            path: "ios/Sources/CartellaVoliPlugin")
    ]
)
