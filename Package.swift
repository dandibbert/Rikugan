// swift-tools-version:5.9
// Pure-logic core of Rikugan (URL matching, userscript metadata, extension manifests, filter
// compilation, ZIP/CRX, omnibox). The same sources are compiled into the iOS app target by
// XcodeGen; this package exists so the logic can be unit-tested with `swift test` on macOS.
import PackageDescription

let package = Package(
    name: "RikuganCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "RikuganCore", targets: ["RikuganCore"])],
    targets: [
        .target(name: "RikuganCore", path: "Sources/Rikugan/Core"),
        .testTarget(name: "RikuganCoreTests", dependencies: ["RikuganCore"], path: "CoreTests"),
    ]
)
