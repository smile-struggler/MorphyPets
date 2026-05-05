// swift-tools-version: 5.9
import PackageDescription

let infoPlistPath = "MorphyPets/Support/Info.plist"

let package = Package(
    name: "MorphyPetsWorkspace",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MorphyPets", targets: ["MorphyPets"]),
        .library(name: "PetEngine", targets: ["PetEngine"]),
        .library(name: "CalendarBridge", targets: ["CalendarBridge"]),
        .library(name: "FocusMonitor", targets: ["FocusMonitor"]),
        .library(name: "InterventionKit", targets: ["InterventionKit"]),
        .library(name: "PersonaLLM", targets: ["PersonaLLM"]),
        .library(name: "SessionStore", targets: ["SessionStore"]),
    ],
    targets: [
        .executableTarget(
            name: "MorphyPets",
            dependencies: [
                "PetEngine", "CalendarBridge", "FocusMonitor",
                "InterventionKit", "PersonaLLM", "SessionStore",
            ],
            path: "MorphyPets",
            exclude: [
                "Support/MorphyPets.entitlements",
                "Support/Info.plist",
            ],
            resources: [
                .copy("Resources/Pets"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlistPath,
                ])
            ]
        ),
        .target(
            name: "PetEngine",
            path: "Packages/PetEngine/Sources/PetEngine"
        ),
        .testTarget(
            name: "PetEngineTests",
            dependencies: ["PetEngine"],
            path: "Packages/PetEngine/Tests/PetEngineTests"
        ),
        .target(
            name: "CalendarBridge",
            dependencies: ["PersonaLLM"],
            path: "Packages/CalendarBridge/Sources/CalendarBridge"
        ),
        .target(
            name: "FocusMonitor",
            path: "Packages/FocusMonitor/Sources/FocusMonitor",
            resources: [
                .process("Resources"),
            ]
        ),
        .target(
            name: "InterventionKit",
            dependencies: ["PetEngine", "PersonaLLM"],
            path: "Packages/InterventionKit/Sources/InterventionKit"
        ),
        .target(
            name: "PersonaLLM",
            path: "Packages/PersonaLLM/Sources/PersonaLLM"
        ),
        .target(
            name: "SessionStore",
            path: "Packages/SessionStore/Sources/SessionStore"
        ),
    ]
)
