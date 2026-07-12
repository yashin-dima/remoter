import XCTest
@testable import Remoter

@MainActor
final class TabsAndUploadTests: XCTestCase {

    private static let env = ProcessInfo.processInfo.environment
    private var repo: String { Self.env["REMOTER_TEST_REPO"] ?? "" }

    private func makeModel(readOnly: Bool = false) throws -> WorkspaceModel {
        try XCTSkipIf(repo.isEmpty, "нужен ./Tests/local-sshd.sh")
        return WorkspaceModel(workspace: Workspace(
            name: "test",
            host: Self.env["REMOTER_TEST_HOST"] ?? "127.0.0.1",
            path: repo,
            port: Int(Self.env["REMOTER_TEST_PORT"] ?? "2222"),
            sshOptions: Self.env["REMOTER_TEST_SSH_OPTS"],
            readOnly: readOnly
        ))
    }

    // MARK: - Вкладки

    /// Открытие второго файла не должно закрывать первый — в этом весь смысл вкладок.
    func testOpeningFilesAccumulatesTabs() async throws {
        let model = try makeModel()
        await model.start()
        defer { model.stop() }
        try TestStand.require(model.conn.state)

        await model.openFile(repo + "/src/main.py")
        await model.openFile(repo + "/docs/readme.md")

        XCTAssertEqual(model.tabs.count, 2)
        XCTAssertEqual(model.activePath, repo + "/docs/readme.md")

        // Первая вкладка жива и помнит своё содержимое.
        let first = try XCTUnwrap(model.tabs.first { $0.absPath == repo + "/src/main.py" })
        XCTAssertTrue(first.baseline.contains("HELLO WORLD"))
        XCTAssertEqual(first.kind, .modified, "изменённый файл должен быть помечен и во вкладке")
    }

    /// Повторное открытие того же файла переключает на вкладку, а не плодит дубликаты.
    func testReopeningSameFileJustSwitchesToItsTab() async throws {
        let model = try makeModel()
        await model.start()
        defer { model.stop() }
        try TestStand.require(model.conn.state)

        await model.openFile(repo + "/src/main.py")
        await model.openFile(repo + "/docs/readme.md")
        await model.openFile(repo + "/src/main.py")

        XCTAssertEqual(model.tabs.count, 2, "вкладка продублировалась")
        XCTAssertEqual(model.activePath, repo + "/src/main.py")
    }

    /// Закрыли активную — активной становится соседняя, а не «ничего».
    func testClosingActiveTabActivatesNeighbour() async throws {
        let model = try makeModel()
        await model.start()
        defer { model.stop() }
        try TestStand.require(model.conn.state)

        await model.openFile(repo + "/src/main.py")
        await model.openFile(repo + "/docs/readme.md")

        model.closeTab(path: repo + "/docs/readme.md")

        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertEqual(model.activePath, repo + "/src/main.py")

        model.closeTab(path: repo + "/src/main.py")
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertNil(model.activePath)
    }

    // MARK: - Загрузка перетаскиванием

    func testUploadPutsFileOnServer() async throws {
        let model = try makeModel()
        await model.start()
        defer { model.stop() }
        try TestStand.require(model.conn.state)

        // «Картинка» с нулевыми байтами — проверяем заодно, что бинарь доезжает целым.
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("логотип.png")
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])
        try bytes.write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        await model.upload(urls: [local], to: repo + "/docs")

        let onServer = try await model.conn.shOK("wc -c < \(shq(repo + "/docs/логотип.png")) | tr -d ' '")
        XCTAssertEqual(onServer.line, String(bytes.count), "файл доехал не целиком")
        XCTAssertTrue(model.uploads.isEmpty, "полоска прогресса осталась висеть")
        XCTAssertEqual(model.toasts.count, 1, "не показано уведомление о загрузке: \(model.toasts.map(\.text))")

        try await model.conn.shOK("rm -f \(shq(repo + "/docs/логотип.png"))")
    }

    /// Перетаскивание — жест беглый. Затереть одноимённый файл на сервере молча недопустимо.
    func testUploadNeverOverwritesExistingFile() async throws {
        let model = try makeModel()
        await model.start()
        defer { model.stop() }
        try TestStand.require(model.conn.state)

        try await model.conn.shOK("printf 'важное\\n' > \(shq(repo + "/docs/файл.txt"))")

        let local = FileManager.default.temporaryDirectory.appendingPathComponent("файл.txt")
        try Data("новое\n".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        await model.upload(urls: [local], to: repo + "/docs")

        let original = try await RemoteFS.read(conn: model.conn, path: repo + "/docs/файл.txt")
        XCTAssertEqual(original.displayText, "важное\n", "существующий файл был затёрт")

        let copy = try await RemoteFS.read(conn: model.conn, path: repo + "/docs/файл 2.txt")
        XCTAssertEqual(copy.displayText, "новое\n", "новый файл должен лечь рядом под свободным именем")

        try await model.conn.shOK("rm -f \(shq(repo + "/docs/файл.txt")) \(shq(repo + "/docs/файл 2.txt"))")
    }

    func testUploadRefusedInReadOnlyWorkspace() async throws {
        let model = try makeModel(readOnly: true)
        await model.start()
        defer { model.stop() }
        try TestStand.require(model.conn.state)

        let local = FileManager.default.temporaryDirectory.appendingPathComponent("нельзя.txt")
        try Data("x".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        await model.upload(urls: [local], to: repo + "/docs")

        let landed = await RemoteFS.exists(conn: model.conn, path: repo + "/docs/нельзя.txt")
        XCTAssertFalse(landed, "в режиме «только чтение» файл всё-таки загрузился")
        XCTAssertNotNil(model.errorMessage)
    }

    // MARK: - Команда запуска Claude

    /// Команда собирается из флагов, которые у claude действительно есть.
    ///
    /// Главное здесь — то, чего в команде НЕТ. По умолчанию мы не подставляем ни модель, ни
    /// effort, ни режим разрешений: у Claude они свои, в его же настройках, и наши флаги
    /// перекрывали их молча. Ровно так приложение и обрезало контекст с миллиона до двухсот тысяч,
    /// подставляя `--model opus` поверх пользовательского `opus[1m]`; и ровно так навязывался
    /// `--permission-mode bypassPermissions` — полный доступ из коробки.
    func testClaudeCommandDoesNotOverrideClaudesOwnSettingsByDefault() throws {
        let model = try makeModel()

        XCTAssertEqual(
            model.claudeCommand,
            "claude",
            "приложение снова навязывает Claude свои модель, effort или режим разрешений"
        )
    }

    /// Явно выбранная модель уезжает в команду — и обязательно в кавычках.
    ///
    /// `opus[1m]` — валидный алиас, но для шелла квадратные скобки это шаблон имени файла.
    /// Без кавычек zsh отвечал «no matches found: opus[1m]», и сессия не запускалась вовсе.
    func testModelAliasIsQuotedBecauseBracketsAreAGlobForTheShell() throws {
        let model = try makeModel()

        model.claudeModel = .fable
        model.claudeEffort = .xhigh
        model.claudePermissions = .acceptEdits
        XCTAssertEqual(
            model.claudeCommand,
            "claude --model 'fable[1m]' --effort xhigh --permission-mode acceptEdits"
        )

        // Проверяем не строкой-эталоном, а делом: пусть команду разберёт настоящий шелл.
        let r = try? Proc.runSync("/bin/zsh", ["-c", "for a in \(model.claudeCommand); do printf '%s\\n' \"$a\"; done"])
        XCTAssertEqual(r?.text.contains("fable[1m]"), true,
                       "шелл не смог разобрать команду — алиас потерялся по дороге")

        // Короткое окно просят явно — и тогда никаких [1m] в команде быть не должно.
        model.claudeLongContext = false
        XCTAssertEqual(
            model.claudeCommand,
            "claude --model 'fable' --effort xhigh --permission-mode acceptEdits"
        )
        model.claudeLongContext = true
    }
}
