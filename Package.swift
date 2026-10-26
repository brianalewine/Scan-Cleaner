// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ScanTidy", platforms: [.macOS(.v14)], products: [.executable(name: "ScanTidy", targets: ["ScanTidy"])], targets: [.executableTarget(name: "ScanTidy"), .testTarget(name: "ScanTidyTests", dependencies: ["ScanTidy"])], swiftLanguageModes: [.v5])
