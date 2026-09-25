// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "iCordis",
    platforms: [.macOS(.v14), .iOS(.v17), .visionOS(.v1)],
    products: [
        .library(name: "iCordisKernel", targets: ["iCordisKernel"]),
        .library(name: "iCordisAgent", targets: ["iCordisAgent"]),
        .library(name: "iCordisHTTP", targets: ["iCordisHTTP"]),
        .executable(name: "icordis-demo", targets: ["iCordisDemo"])
    ],
    targets: [
        .target(name: "iCordisKernel"),
        .target(name: "iCordisAgent", dependencies: ["iCordisKernel"], resources: [.copy("Prompts")]),
        .target(name: "iCordisHTTP", dependencies: ["iCordisAgent"]),
        .executableTarget(name: "iCordisDemo", dependencies: ["iCordisHTTP"], path: "Examples/AgentCLI"),
        .testTarget(name: "iCordisHTTPTests", dependencies: ["iCordisHTTP"]),
        .testTarget(name: "iCordisKernelTests", dependencies: ["iCordisKernel"]),
        .testTarget(name: "iCordisAgentTests", dependencies: ["iCordisAgent"])
    ],
    swiftLanguageModes: [.v5]
)
