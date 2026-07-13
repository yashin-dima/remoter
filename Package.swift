// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Remoter",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "Remoter",
            dependencies: ["SwiftTerm"],
            path: "Sources/Remoter"
        ),
        // Тесты гоняют настоящий ssh против локального sshd — то, что нельзя проверить
        // моками: разбор porcelain-вывода git, кавычки в путях, атомарная запись.
        // SwiftTerm нужен и тестам: терминал у нас с подменённым делегатом (через него идёт ввод
        // в процесс), и это надо проверять на настоящем SwiftTerm, а не на словах.
        .testTarget(
            name: "RemoterTests",
            dependencies: ["Remoter", "SwiftTerm"],
            path: "Tests/RemoterTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
