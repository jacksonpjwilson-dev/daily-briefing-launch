// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "BriefingCore", products: [.library(name: "BriefingCore", targets: ["BriefingCore"])],
    targets: [.target(name: "BriefingCore", path: "DailyBriefing/Core"),
              .testTarget(name: "BriefingCoreTests", dependencies: ["BriefingCore"], path: "DailyBriefing/Tests")])
