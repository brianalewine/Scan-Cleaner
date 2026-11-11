// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ScanCleaner", platforms: [.macOS(.v14)], products: [.executable(name: "ScanCleaner", targets: ["ScanCleaner"])], targets: [.executableTarget(name: "ScanCleaner"), .testTarget(name: "ScanCleanerTests", dependencies: ["ScanCleaner"])], swiftLanguageModes: [.v5])
