import XCTest
@testable import Remoter

/// Локальная папка проекта: доки, заметки, инструкция для Claude, конфиг доступа.
///
/// Главное свойство: она про Mac, а не про сервер. Сервер про Claude ничего не знает и знать
/// не должен, поэтому ни одна операция здесь не имеет права трогать удалённый проект.
@MainActor
final class LocalPanelTests: XCTestCase {

    private static let env = ProcessInfo.processInfo.environment
    private var repo: String { Self.env["REMOTER_TEST_REPO"] ?? "" }

    private func started(readOnly: Bool = false) async throws -> WorkspaceModel {
        try XCTSkipIf(repo.isEmpty, "нужен ./Tests/local-sshd.sh")
        let model = WorkspaceModel(workspace: Workspace(
            name: "test",
            host: Self.env["REMOTER_TEST_HOST"] ?? "127.0.0.1",
            path: repo,
            port: Int(Self.env["REMOTER_TEST_PORT"] ?? "2222"),
            sshOptions: Self.env["REMOTER_TEST_SSH_OPTS"],
            readOnly: readOnly
        ))
        await model.start()
        try TestStand.require(model.conn.state)
        return model
    }

    /// С первого запуска в папке есть всё, ради чего она заведена: инструкция для Claude,
    /// обёртка над ssh и место под документацию.
    func testLocalFolderHasInstructionScriptAndDocs() async throws {
        let model = try await started()
        defer { model.stop() }

        let names = model.localRows.map(\.entry.name)
        XCTAssertTrue(names.contains("CLAUDE.md"), "нет инструкции для Claude: \(names)")
        XCTAssertTrue(names.contains("remote"), "нет обёртки над ssh: \(names)")
        XCTAssertTrue(names.contains("docs"), "нет папки под документацию: \(names)")
    }

    /// Терминал нельзя поднимать раньше, чем готова локальная папка проекта.
    ///
    /// Регрессия, которая ломала весь замысел: соединение поднимается РАНЬШЕ папки, а терминал
    /// создаётся один раз и навсегда. Стартовав до появления папки, локальный шелл оставался
    /// в домашнем каталоге — Claude не находил там CLAUDE.md и работал, не подозревая ни про
    /// сервер, ни про проект. Внешне при этом всё выглядело правильно: панель показывала нужную
    /// папку, а терминал сидел совсем в другой.
    func testTerminalIsNotReadyUntilLocalFolderExists() async throws {
        try XCTSkipIf(repo.isEmpty, "нужен ./Tests/local-sshd.sh")

        let model = WorkspaceModel(workspace: Workspace(
            name: "test",
            host: Self.env["REMOTER_TEST_HOST"] ?? "127.0.0.1",
            path: repo,
            port: Int(Self.env["REMOTER_TEST_PORT"] ?? "2222"),
            sshOptions: Self.env["REMOTER_TEST_SSH_OPTS"]
        ))
        defer { model.stop() }

        // До start() папки нет — и терминал поднимать нельзя, даже если соединение появится.
        XCTAssertTrue(model.localPath.isEmpty)
        XCTAssertFalse(model.isTerminalReady)

        await model.start()
        try TestStand.require(model.conn.state)

        XCTAssertTrue(model.isTerminalReady, "терминал так и не разрешён к запуску")
        XCTAssertFalse(model.localPath.isEmpty)

        // И в этой папке действительно лежит то, ради чего Claude туда и сажают.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: model.localPath + "/CLAUDE.md"),
            "терминал разрешён, а инструкции для Claude в рабочем каталоге нет"
        )
    }

    /// Проекты открываются в разных окнах и не должны пересекаться ничем: у каждого свой
    /// ssh-канал, своя папка и свой терминал — то есть своя сессия Claude. Иначе Claude во втором
    /// окне читал бы инструкцию от первого проекта и правил бы файлы не на том сервере.
    func testTwoProjectsAreFullyIndependent() async throws {
        try XCTSkipIf(repo.isEmpty, "нужен ./Tests/local-sshd.sh")

        func make(_ name: String) -> WorkspaceModel {
            WorkspaceModel(workspace: Workspace(
                name: name,
                host: Self.env["REMOTER_TEST_HOST"] ?? "127.0.0.1",
                path: repo,
                port: Int(Self.env["REMOTER_TEST_PORT"] ?? "2222"),
                sshOptions: Self.env["REMOTER_TEST_SSH_OPTS"]
            ))
        }

        let first = make("первый")
        let second = make("второй")
        defer { second.stop() }

        await first.start()
        await second.start()
        try TestStand.require(first.conn.state)

        XCTAssertNotEqual((first.conn as! SSHConnection).controlSocket, (second.conn as! SSHConnection).controlSocket,
                          "проекты делят один ssh-канал")
        XCTAssertNotEqual(first.localPath, second.localPath,
                          "проекты делят одну локальную папку — Claude прочтёт чужую инструкцию")
        XCTAssertFalse(first.terminal === second.terminal, "проекты делят один терминал")

        // И у каждого своя инструкция, в которой написано его собственное имя.
        let firstMD = try String(contentsOfFile: first.localPath + "/CLAUDE.md", encoding: .utf8)
        let secondMD = try String(contentsOfFile: second.localPath + "/CLAUDE.md", encoding: .utf8)
        XCTAssertTrue(firstMD.contains("первый"))
        XCTAssertTrue(secondMD.contains("второй"))

        // Главное: закрыли одно окно — второе продолжает работать. Пока канал зависел только
        // от хоста, закрытие первого проекта уносило с собой сокет второго, и оно молча слепло.
        first.stop()
        let alive = try await second.conn.sh("echo жив")
        XCTAssertEqual(alive.line, "жив", "закрытие одного проекта оборвало связь у другого")
    }

    /// Открыли проект — продолжается последний разговор, а не начинается новый.
    ///
    /// Работа над проектом идёт неделями и не заканчивается вместе с окном. Вернувшись, хочется
    /// оказаться там же, где остановился, а не вспоминать, какая из десяти сессий «та самая».
    func testOpeningProjectResumesTheLatestSession() async throws {
        try XCTSkipIf(repo.isEmpty, "нужен ./Tests/local-sshd.sh")
        try XCTSkipIf(Self.env["CLAUDE_CONFIG_DIR"] == nil,
                      "нужен CLAUDE_CONFIG_DIR — иначе тест полез бы в настоящий ~/.claude")

        // Своё имя проекта и свой журнал: иначе подложенные разговоры увидели бы соседние тесты,
        // у которых папка проекта та же самая.
        let model = WorkspaceModel(workspace: Workspace(
            name: "автозапуск",
            host: Self.env["REMOTER_TEST_HOST"] ?? "127.0.0.1",
            path: repo,
            port: Int(Self.env["REMOTER_TEST_PORT"] ?? "2222"),
            sshOptions: Self.env["REMOTER_TEST_SSH_OPTS"]
        ))
        // Разговоры кладём ДО открытия проекта: именно так они и выглядят в жизни — вчерашние.
        // Путь к папке проекта известен заранее, он не зависит от подключения.
        let localPath = LocalWorkspace.directory(for: model.workspace).path
        let journals = try makeJournalDir(for: localPath)
        defer {
            model.stop()
            try? FileManager.default.removeItem(at: journals)
            try? FileManager.default.removeItem(atPath: localPath)
        }
        try write(journals, id: "старая", title: "Прошлая неделя", at: Date(timeIntervalSinceNow: -86400))
        try write(journals, id: "свежая", title: "Вчерашний деплой", at: Date(timeIntervalSinceNow: -60))

        await model.start()
        try TestStand.require(model.conn.state)
        try XCTSkipIf(!model.claudeInstalled, "claude не установлен")

        XCTAssertEqual(model.sessions.first?.id, "свежая", "список сессий отсортирован не по свежести")

        let tab = try XCTUnwrap(model.claudeTabs.first, "при открытии проекта Claude не запустился")
        XCTAssertEqual(tab.title, "Вчерашний деплой", "вкладка названа не по продолженному разговору")

        // Терминала в тестовом процессе нет, поэтому команда ждёт своей очереди — её и проверяем.
        let command = try XCTUnwrap(model.terminal.pendingCommand(for: tab.terminal),
                                    "команда запуска никуда не ушла")
        // id уходит через shq — как всё, что попадает в шелл.
        XCTAssertTrue(command.contains("--resume 'свежая'"),
                      "продолжается не последняя сессия: \(command)")
        XCTAssertFalse(command.contains("--resume 'старая'"))
        XCTAssertTrue(command.contains("cd "), "Claude запускается не в папке проекта")
    }

    private func makeJournalDir(for cwd: String) throws -> URL {
        let dir = ClaudeSessions.configDirectory
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(String(cwd.map { ($0 == "/" || $0 == ".") ? "-" : $0 }))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ dir: URL, id: String, title: String, at date: Date) throws {
        let file = dir.appendingPathComponent("\(id).jsonl")
        try [
            #"{"type":"user","sessionId":"\#(id)"}"#,
            #"{"type":"assistant","sessionId":"\#(id)"}"#,
            #"{"type":"ai-title","aiTitle":"\#(title)","sessionId":"\#(id)"}"#,
        ].joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    /// Клик по уведомлению должен вести в ТОТ проект, из которого оно пришло, и на ТУ вкладку,
    /// где работает Claude. Открыто несколько окон — «просто вывести приложение вперёд» значит
    /// попасть не туда.
    func testNotificationLeadsBackToItsOwnProjectAndClaudeTab() async throws {
        try XCTSkipIf(repo.isEmpty, "нужен ./Tests/local-sshd.sh")

        func make(_ name: String) -> WorkspaceModel {
            WorkspaceModel(workspace: Workspace(
                name: name,
                host: Self.env["REMOTER_TEST_HOST"] ?? "127.0.0.1",
                path: repo,
                port: Int(Self.env["REMOTER_TEST_PORT"] ?? "2222"),
                sshOptions: Self.env["REMOTER_TEST_SSH_OPTS"]
            ))
        }

        let first = make("первый")
        let second = make("второй")
        defer { first.stop(); second.stop() }

        await first.start()
        await second.start()
        try TestStand.require(first.conn.state)
        try XCTSkipIf(!first.claudeInstalled, "claude не установлен")

        // У каждого своя сессия, и оба смотрят в файл, а не на Claude.
        let firstTab = try XCTUnwrap(first.openSession())
        let secondTab = try XCTUnwrap(second.openSession())
        first.pane = .file
        second.pane = .file

        XCTAssertTrue(WorkspaceModel.reveal(second.workspace.id),
                      "проект не нашёлся по id — уведомлению некуда вести")

        XCTAssertEqual(second.pane, .claude(secondTab.id), "уведомление не открыло вкладку Claude")
        XCTAssertEqual(first.pane, .file, "уведомление дёрнуло чужой проект")
        XCTAssertNotEqual(firstTab.id, secondTab.id)

        // Проект закрыли, пока уведомление висело, — вести некуда, и это не ошибка.
        XCTAssertFalse(WorkspaceModel.reveal(UUID()))
    }

    /// Новая сессия открывается РЯДОМ с текущей и не трогает её.
    ///
    /// Регрессия, которая и породила эту переделку: «новая сессия» просто печатала команду запуска
    /// в терминал, где Claude уже работал. Он читал её как обычное сообщение и вежливо отвечал,
    /// что запускать себя изнутри себя смысла нет. Никакой новой сессии при этом не появлялось.
    func testNewSessionOpensAlongsideTheRunningOneAndDoesNotDisturbIt() async throws {
        let model = try await started()
        defer { model.stop() }
        try XCTSkipIf(!model.claudeInstalled, "claude не установлен")

        // Одна сессия уже открыта — её поднял сам проект при старте.
        let before = model.claudeTabs.count

        model.claudeModel = .opus           // модель выбрана явно, а не «как в Claude»
        let first = try XCTUnwrap(model.openSession())
        model.claudeModel = .haiku          // следующая — с другими настройками
        let second = try XCTUnwrap(model.openSession())

        XCTAssertEqual(model.claudeTabs.count, before + 2, "новая сессия не появилась рядом")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(model.pane, .claude(second.id), "не переключились на новую сессию")

        // Терминалы разные — то есть это два процесса, а не один.
        XCTAssertNotEqual(first.terminal, second.terminal, "сессии делят один терминал")

        let cmd1 = try XCTUnwrap(model.terminal.pendingCommand(for: first.terminal))
        let cmd2 = try XCTUnwrap(model.terminal.pendingCommand(for: second.terminal))
        XCTAssertTrue(cmd1.contains("--model 'opus[1m]'"))
        XCTAssertTrue(cmd2.contains("--model 'haiku'"),
                      "новая сессия запустилась не с теми настройками, что выбрали")
        XCTAssertEqual(first.model, .opus, "настройки открытой сессии переписались задним числом")

        // Закрыли новую — старая на месте, и мы вернулись именно к ней.
        model.closeSession(second.id)
        XCTAssertEqual(model.claudeTabs.count, before + 1)
        XCTAssertTrue(model.claudeTabs.contains { $0.id == first.id }, "закрыли не ту сессию")
        XCTAssertEqual(model.pane, .claude(first.id))
        XCTAssertNil(model.terminal.pendingCommand(for: second.terminal),
                     "терминал закрытой сессии остался висеть")
    }

    /// Терминал на сервере — вкладка, которую открывают, а не постоянный жилец в ряду.
    ///
    /// Раньше вкладка «Сервер» висела всегда, даже когда в терминал не заходили неделями,
    /// и была ровно одна. Теперь их открывают из раздела Terminal — столько, сколько нужно:
    /// пока в одном крутится хвост лога, во втором работают руками.
    func testTerminalsOpenAsSeparateTabsAndCloseIndependently() async throws {
        let model = try await started()
        defer { model.stop() }

        XCTAssertTrue(model.shells.isEmpty, "терминал открылся сам, хотя его не просили")

        let first = model.openShell()
        let second = model.openShell()

        XCTAssertEqual(model.shells.count, 2, "второй терминал не открылся рядом с первым")
        XCTAssertNotEqual(first.terminal, second.terminal, "терминалы делят один ssh")
        XCTAssertEqual(model.pane, .remote(second.id), "не переключились на открытый терминал")

        // Открытые терминалы видны вкладками — к ним и возвращаются кликом по вкладке.
        // Отдельного «показать последний» больше нет: кнопка в тулбаре всегда открывает новый,
        // как плюс для сессий, и это одно понятное правило вместо двух.
        model.pane = .file
        model.pane = .remote(second.id)
        XCTAssertEqual(model.shells.count, 2, "переключение на вкладку открыло ещё один терминал")

        // Закрыли один — второй на месте, и мы вернулись именно к нему.
        model.closeShell(second.id)
        XCTAssertEqual(model.shells.map(\.id), [first.id], "закрыли не тот терминал")
        XCTAssertEqual(model.pane, .remote(first.id))

        // Закрыли последний — уходим в редактор, а не в пустую вкладку.
        model.closeShell(first.id)
        XCTAssertTrue(model.shells.isEmpty)
        XCTAssertEqual(model.pane, .file)
    }

    /// Локальный файл открывается вкладкой, правится и сохраняется НА ДИСК — не на сервер.
    func testEditingLocalFileWritesToDiskNotToServer() async throws {
        let model = try await started()
        defer { model.stop() }

        let path = model.localPath + "/docs/заметка.md"
        try LocalFS.write(path, content: "было\n")
        model.reloadLocalTree()

        model.openLocalFile(path)
        let doc = try XCTUnwrap(model.doc)
        XCTAssertTrue(doc.isLocal)
        XCTAssertTrue(doc.editable)
        XCTAssertEqual(doc.baseline, "было\n")

        await model.save(path: path, content: "стало\n")

        XCTAssertEqual(LocalFS.read(path).displayText, "стало\n", "правка не легла на диск")
        XCTAssertFalse(try XCTUnwrap(model.doc).isDirty)
        XCTAssertNil(model.errorMessage)

        // И на сервере ничего подобного не появилось.
        let onServer = await RemoteFS.exists(conn: model.conn, path: repo + "/docs/заметка.md")
        XCTAssertFalse(onServer, "локальная заметка уехала на сервер — этого быть не должно")

        try? FileManager.default.removeItem(atPath: path)
    }

    /// Режим «только чтение» защищает СЕРВЕР. Свои заметки на Mac он запрещать не должен —
    /// иначе в самом осторожном режиме нельзя было бы даже записать, что ты там осторожничаешь.
    func testReadOnlyWorkspaceStillAllowsLocalNotes() async throws {
        let model = try await started(readOnly: true)
        defer { model.stop() }

        XCTAssertFalse(model.canWrite)

        let path = model.localPath + "/docs/можно.md"
        try LocalFS.write(path, content: "черновик\n")
        model.reloadLocalTree()
        model.openLocalFile(path)

        await model.save(path: path, content: "правка в режиме только чтение\n")

        XCTAssertEqual(LocalFS.read(path).displayText, "правка в режиме только чтение\n",
                       "локальная заметка не сохранилась в режиме «только чтение»")
        XCTAssertNil(model.errorMessage)

        try? FileManager.default.removeItem(atPath: path)
    }

    /// Поллинг ходит на сервер. Открытый локальный файл он трогать не должен: там ему нечего
    /// сверять, а «обновление» затёрло бы содержимое пустотой.
    func testPollingLeavesOpenLocalFileAlone() async throws {
        let model = try await started()
        defer { model.stop() }

        let path = model.localPath + "/docs/стабильная.md"
        try LocalFS.write(path, content: "содержимое\n")
        model.reloadLocalTree()
        model.openLocalFile(path)

        await model.refresh(force: true)
        await model.refresh(force: false)

        let doc = try XCTUnwrap(model.doc)
        XCTAssertEqual(doc.absPath, path, "поллинг подменил открытую вкладку")
        XCTAssertEqual(doc.baseline, "содержимое\n", "поллинг испортил локальный файл")

        try? FileManager.default.removeItem(atPath: path)
    }

    /// Инструкция для Claude лежит на Mac и содержит всё, что ему нужно знать о сервере.
    func testInstructionIsLocalAndComplete() async throws {
        let model = try await started()
        defer { model.stop() }

        let claudeMD = model.localPath + "/CLAUDE.md"
        model.openLocalFile(claudeMD)

        let doc = try XCTUnwrap(model.doc)
        XCTAssertTrue(doc.isLocal)
        XCTAssertTrue(doc.baseline.contains(repo), "в инструкции нет каталога проекта")
        XCTAssertTrue(doc.baseline.contains("./remote"), "в инструкции нет способа дотянуться до сервера")

        // На сервере никакой CLAUDE.md не появился: он про Claude ничего не знает.
        let onServer = await RemoteFS.exists(conn: model.conn, path: repo + "/CLAUDE.md")
        XCTAssertFalse(onServer, "инструкция для Claude оказалась на сервере")
    }
}
