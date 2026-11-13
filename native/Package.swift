// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "BriefingCore", platforms: [.macOS(.v14), .iOS(.v17), .watchOS(.v10)],
    products: [.library(name: "BriefingCore", targets: ["BriefingCore"])],
    targets: [
        .target(name: "BriefingCore", path: "DailyBriefing/Core"),
        .target(name: "HistoryPersistence", dependencies: ["BriefingCore"], path: "DailyBriefing/App",
            exclude: ["Settings.swift", "BriefingController.swift", "DailyBriefingApp.swift", "BriefingIntents.swift"], sources: ["Persistence.swift"]),
        .testTarget(name: "BriefingCoreTests", dependencies: ["BriefingCore", "HistoryPersistence"], path: "DailyBriefing/Tests")
    ])
