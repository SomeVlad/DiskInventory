// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DiskInventory",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "DiskInventory", targets: ["DiskInventory"])],
    targets: [
        .target(name: "InventoryCore"),
        .executableTarget(name: "DiskInventory", dependencies: ["InventoryCore"]),
        .testTarget(name: "InventoryCoreTests", dependencies: ["InventoryCore"])
    ]
)
