// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenRation",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TokenRation", targets: ["TokenRation"]),
        // Bundled MCP server so agents can read usage directly. Shipped inside the .app and
        // symlinked onto the PATH by the Homebrew cask.
        .executable(name: "tokenration-mcp", targets: ["TokenRationMCP"]),
    ],
    targets: [
        // Shared on-disk state format: written by the app, read by the MCP server.
        .target(
            name: "UsageState",
            path: "Sources/UsageState"
        ),
        .executableTarget(
            name: "TokenRation",
            dependencies: ["UsageState"],
            path: "Sources/TokenRation"
        ),
        .executableTarget(
            name: "TokenRationMCP",
            dependencies: ["UsageState"],
            path: "Sources/TokenRationMCP"
        ),
        .testTarget(
            name: "TokenRationTests",
            dependencies: ["TokenRation", "UsageState"],
            path: "Tests/TokenRationTests"
        ),
    ]
)
