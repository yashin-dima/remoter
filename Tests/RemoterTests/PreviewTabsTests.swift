import XCTest
@testable import Remoter

/// Вкладки-предпросмотр и управление работающей сессией.
@MainActor
final class PreviewTabsTests: XCTestCase {

    private static let env = ProcessInfo.processInfo.environment
    private var repo: String { Self.env["REMOTER_TEST_REPO"] ?? "" }

    private func started() async throws -> WorkspaceModel {
        try XCTSkipIf(repo.isEmpty, "REMOTER_TEST_REPO не задан — нужен ./Tests/local-sshd.sh")

        let model = WorkspaceModel(workspace: Workspace(
            name: "предпросмотр-\(UUID().uuidString.prefix(8))",
            host: Self.env["REMOTER_TEST_HOST"] ?? "127.0.0.1",
            path: repo,
            port: Int(Self.env["REMOTER_TEST_PORT"] ?? "2222"),
            sshOptions: Self.env["REMOTER_TEST_SSH_OPTS"]
        ))
        await model.start()
        return model
    }

    // MARK: - Предпросмотр

    /// Одиночный клик открывает файл на предпросмотр, и следующий такой же клик ЗАМЕНЯЕТ вкладку,
    /// а не открывает вторую. Иначе, прощёлкивая diff, за минуту набираешь двадцать вкладок.
    func testSingleClickReplacesThePreviewTabInsteadOfPilingThemUp() async throws {
        let model = try await started()
        defer { model.stop() }

        await model.openFile(repo + "/docs/readme.md", preview: true)
        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertTrue(model.tabs[0].isPreview, "вкладка не помечена предпросмотром")

        await model.openFile(repo + "/src/main.py", preview: true)
        XCTAssertEqual(model.tabs.count, 1, "предпросмотр не заменился — вкладки копятся")
        XCTAssertEqual(model.tabs[0].title, "main.py")
        XCTAssertEqual(model.activePath, repo + "/src/main.py")
    }

    /// Двойной клик оставляет файл в ряду. Следующий предпросмотр встаёт рядом, а не вместо него.
    func testDoubleClickKeepsTheTabAndPreviewGoesNextToIt() async throws {
        let model = try await started()
        defer { model.stop() }

        await model.openFile(repo + "/docs/readme.md", preview: false)
        XCTAssertFalse(model.tabs[0].isPreview, "постоянная вкладка помечена предпросмотром")

        await model.openFile(repo + "/src/main.py", preview: true)
        XCTAssertEqual(model.tabs.count, 2, "постоянную вкладку заменили предпросмотром")

        // А вот следующий предпросмотр заменит именно предпросмотр — постоянная останется.
        await model.openFile(repo + "/src/utils/helper.ts", preview: true)
        XCTAssertEqual(model.tabs.count, 2)
        XCTAssertEqual(model.tabs.map(\.title), ["readme.md", "helper.ts"])
    }

    /// Предпросмотр встаёт на место прежнего, а не в конец ряда: прощёлкивая файлы, вы смотрите
    /// в одну и ту же точку — пусть вкладка не убегает из-под глаз.
    func testPreviewKeepsItsPlaceInTheRow() async throws {
        let model = try await started()
        defer { model.stop() }

        await model.openFile(repo + "/src/main.py", preview: true)   // станет предпросмотром
        model.pinTab(path: repo + "/src/main.py")                    // и закрепится
        await model.openFile(repo + "/docs/readme.md", preview: true)     // предпросмотр — второй
        await model.openFile(repo + "/src/utils/helper.ts", preview: false)  // постоянная — третья

        XCTAssertEqual(model.tabs.map(\.title), ["main.py", "readme.md", "helper.ts"])

        // Новый предпросмотр заменяет старый ровно на его месте — посередине.
        await model.openFile(repo + "/docs/readme.md", preview: true)
        await model.openFile(repo + "/docs/файл с пробелом.md", preview: true)
        XCTAssertEqual(model.tabs.map(\.title), ["main.py", "файл с пробелом.md", "helper.ts"],
                       "предпросмотр убежал в конец ряда")
    }

    /// Двойной клик по уже открытому предпросмотру закрепляет его — не открывая второй вкладки.
    func testOpeningTheSameFileWithoutPreviewPinsIt() async throws {
        let model = try await started()
        defer { model.stop() }

        await model.openFile(repo + "/docs/readme.md", preview: true)
        await model.openFile(repo + "/docs/readme.md", preview: false)

        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertFalse(model.tabs[0].isPreview, "двойной клик не закрепил вкладку")
    }

    // MARK: - Управление сессией

    /// Смена модели уходит в терминал КОМАНДОЙ — той же, что набрали бы руками. Никакой скрытой
    /// подмены состояния: команду видно, её можно прервать, а плашка переключится, только когда
    /// смена реально произойдёт.
    func testSwitchingModelSendsTheSameCommandYouWouldTypeYourself() async throws {
        let model = try await started()
        defer { model.stop() }
        try XCTSkipIf(!model.claudeInstalled, "claude не установлен")

        let tab = try XCTUnwrap(model.openSession())

        model.switchModel(tab, to: .sonnet)
        XCTAssertEqual(model.terminal.pendingCommand(for: tab.terminal), "/model sonnet[1m]",
                       "в терминал ушла не та команда")

        model.switchEffort(tab, to: .xhigh)
        XCTAssertEqual(model.terminal.pendingCommand(for: tab.terminal), "/effort xhigh")
    }

    /// Пишет журнал так же, как это делает Claude Code: каталог собран из рабочего пути,
    /// имя файла — id сессии.
    private func journal(_ id: String, for model: WorkspaceModel) throws {
        let dir = ClaudeSessions.configDirectory
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(String(model.localPath.map { ($0 == "/" || $0 == ".") ? "-" : $0 }),
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let line = #"{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-8"}}"# + "\n"
        try line.write(to: dir.appendingPathComponent("\(id).jsonl"),
                       atomically: true, encoding: .utf8)
    }

    /// Занятость приходит от хуков Claude и должна попасть в СВОЮ вкладку: сессий открыто
    /// несколько, и «работает» у чужой — это кнопка «Стоп», которая остановит не то.
    ///
    /// Свою вкладку событие находит по id сессии, а тот приложение узнаёт из имени файла журнала.
    /// Поэтому и проверяем через настоящий журнал, а не подсовывая модели готовое состояние.
    func testBusyStateFindsItsOwnTabBySessionID() async throws {
        let model = try await started()
        defer { model.stop() }
        try XCTSkipIf(!model.claudeInstalled, "claude не установлен")

        // Проект при открытии сам поднимает сессию — она бы разобрала наши журналы первой.
        for tab in model.claudeTabs { model.closeSession(tab.id) }

        try journal("сессия-1", for: model)
        try journal("сессия-2", for: model)

        let first = try XCTUnwrap(model.openSession(
            resuming: ClaudeSession(id: "сессия-1", title: "п", lastPrompt: "", updated: Date(), messages: 1)
        ))
        let second = try XCTUnwrap(model.openSession(
            resuming: ClaudeSession(id: "сессия-2", title: "в", lastPrompt: "", updated: Date(), messages: 1)
        ))

        await model.followSessions()
        XCTAssertEqual(model.claudeTabs.first { $0.id == first.id }?.live.sessionID, "сессия-1")
        XCTAssertEqual(model.claudeTabs.first { $0.id == second.id }?.live.sessionID, "сессия-2")

        model.setBusy(true, session: "сессия-2")
        XCTAssertFalse(model.claudeTabs.first { $0.id == first.id }?.isBusy ?? true,
                       "занялась не та сессия")
        XCTAssertTrue(model.claudeTabs.first { $0.id == second.id }?.isBusy ?? false)

        // Событие от неизвестной сессии (хук опоздал, вкладку уже закрыли) не трогает никого.
        model.setBusy(false, session: "сессия-2")
        model.setBusy(true, session: "неизвестная")
        XCTAssertFalse(model.claudeTabs.contains { $0.isBusy })
    }

    /// «Стоп» — это Escape, а не Ctrl+C. Ctrl+C, нажатый дважды, выходит из Claude: кнопка,
    /// которая иногда закрывает разговор, никуда не годится.
    func testStopInterruptsTheAnswerAndDoesNotKillTheSession() async throws {
        let model = try await started()
        defer { model.stop() }
        try XCTSkipIf(!model.claudeInstalled, "claude не установлен")

        for tab in model.claudeTabs { model.closeSession(tab.id) }   // автозапуск нам тут мешает

        try journal("s", for: model)
        let tab = try XCTUnwrap(model.openSession(
            resuming: ClaudeSession(id: "s", title: "п", lastPrompt: "", updated: Date(), messages: 1)
        ))
        await model.followSessions()
        model.setBusy(true, session: "s")
        XCTAssertTrue(model.claudeTabs.contains { $0.id == tab.id && $0.isBusy })

        model.stopSession(tab)

        XCTAssertFalse(model.claudeTabs.contains { $0.id == tab.id && $0.isBusy },
                       "после остановки сессия всё ещё «работает»")
        XCTAssertTrue(model.claudeTabs.contains { $0.id == tab.id }, "остановка закрыла сессию")
    }

    /// Сессия с явно выбранной моделью и длинным контекстом запускается как `--model 'opus[1m]'`.
    func testLongContextSessionAsksForTheMillionTokenWindow() throws {
        let model = WorkspaceModel(workspace: Workspace(name: "п", host: "h", path: "/srv/п"))

        let long = ClaudeTab(id: UUID(), title: "", model: .opus, effort: .high,
                             permissions: .bypassPermissions, longContext: true, resumed: nil)
        XCTAssertTrue(model.command(long).contains("--model 'opus[1m]'"))
        XCTAssertEqual(long.contextWindow, 1_000_000)

        let short = ClaudeTab(id: UUID(), title: "", model: .opus, effort: .high,
                              permissions: .bypassPermissions, longContext: false, resumed: nil)
        XCTAssertTrue(short.contextWindow == 200_000)
        XCTAssertFalse(model.command(short).contains("[1m]"))

        // У Haiku длинного контекста нет вовсе — просить его бессмысленно.
        let haiku = ClaudeTab(id: UUID(), title: "", model: .haiku, effort: .low,
                              permissions: .default, longContext: true, resumed: nil)
        XCTAssertFalse(model.command(haiku).contains("[1m]"), "у Haiku попросили несуществующее окно")
        XCTAssertEqual(haiku.contextWindow, 200_000)
    }

    /// Сессия, которая ничего не навязывает, берёт модель Claude — и окно вместе с ней.
    ///
    /// Размер окна нельзя ни спросить у Claude Code (команды нет: `/context` рисует картинку
    /// в терминале и наружу ничего не отдаёт), ни вычитать из журнала. Единственный честный
    /// источник — алиас, с которым сессия работает: `[1m]` означает миллион, иначе 200k.
    func testInheritedSessionTakesTheWindowFromClaudesOwnSettings() throws {
        let model = WorkspaceModel(workspace: Workspace(name: "п", host: "h", path: "/srv/п"))

        let tab = ClaudeTab(id: UUID(), title: "", model: .inherit, effort: .inherit,
                            permissions: .bypassPermissions, longContext: true, resumed: nil)

        let command = model.command(tab)
        XCTAssertFalse(command.contains("--model"), "модель навязана поверх настроек Claude")
        XCTAssertFalse(command.contains("--effort"), "effort навязан поверх настроек Claude")

        // Окно — из алиаса в настройках Claude. Их пишет он сам, мы только читаем.
        XCTAssertEqual(ClaudeConfig.window(alias: "opus[1m]"), 1_000_000)
        XCTAssertEqual(ClaudeConfig.window(alias: "opus"), 200_000)
        XCTAssertEqual(tab.contextWindow, ClaudeConfig.window(alias: ClaudeConfig.model))
    }

    /// Кольцо контекста считает по последнему ответу Claude. И оно не имеет права показывать
    /// «переполнено», если окно на самом деле длинное: наблюдение важнее нашего предположения.
    func testContextRingCorrectsItselfWhenTheWindowTurnsOutToBeLonger() {
        var tab = ClaudeTab(id: UUID(), title: "", model: .opus, effort: .high,
                            permissions: .default, longContext: false, resumed: nil)

        XCTAssertNil(tab.contextFill, "Claude ещё не отвечал — считать нечего")

        tab.live.contextTokens = 100_000
        XCTAssertEqual(tab.contextFill ?? 0, 0.5, accuracy: 0.001)

        // Занято больше, чем мы считали пределом, — значит сессия идёт в миллионном окне.
        tab.live.contextTokens = 600_000
        XCTAssertEqual(tab.contextWindow, 1_000_000, "окно не пересчиталось по наблюдению")
        XCTAssertEqual(tab.contextFill ?? 0, 0.6, accuracy: 0.001)
    }
}
