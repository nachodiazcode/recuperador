// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "recuperador",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Recuperador", targets: ["Recuperador"]),
        .executable(name: "recuperar", targets: ["recuperar"]),
        .library(name: "RecoveryCore", targets: ["RecoveryCore"]),
    ],
    targets: [
        .target(name: "RecoveryCore"),
        .executableTarget(
            name: "Recuperador",
            dependencies: ["RecoveryCore"],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Para que los avisos del sistema reconozcan la app también con `swift run`.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Recuperador/Info.plist",
                ]),
            ]
        ),
        .executableTarget(name: "recuperar", dependencies: ["RecoveryCore"]),
        .testTarget(name: "RecoveryCoreTests", dependencies: ["RecoveryCore"]),
    ]
)
