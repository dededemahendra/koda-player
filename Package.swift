// swift-tools-version:5.9
import PackageDescription

// Homebrew's libmpv. `build-app.sh` rewrites Sources/CMPV/module.modulemap and this path
// from `brew --prefix`, so an Intel Mac (/usr/local) works too.
let brewPrefix = "/opt/homebrew"

let package = Package(
    name: "KodaPlayer",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(name: "CMPV", path: "Sources/CMPV"),
        .executableTarget(
            name: "KodaPlayer",
            dependencies: ["CMPV"],
            path: "Sources/KodaPlayer",
            // No -rpath here: dev builds resolve libmpv through Homebrew's absolute install
            // name, and build-app.sh lets dylibbundler add the bundle rpath (adding it twice
            // makes dyld refuse to launch the app).
            linkerSettings: [.unsafeFlags(["-L\(brewPrefix)/lib"])]
        )
    ]
)
