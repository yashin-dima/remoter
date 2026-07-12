import XCTest
@testable import Remoter

/// Весь конвейер разом: подключиться, разобрать статус, собрать дерево, открыть diff,
/// сохранить и — главное — увидеть правку, которую сделали на сервере, пока мы смотрим на файл.
///
/// Здесь не проверяется картинка (это делает `Remoter.app --selfcheck`), но проверяется всё,
/// что до неё: какие именно строки уедут в редактор.
@MainActor
final class WorkspaceModelTests: XCTestCase {

    private static let env = ProcessInfo.processInfo.environment
    private var repo: String { Self.env["REMOTER_TEST_REPO"] ?? "" }

    private func makeModel() throws -> WorkspaceModel {
        try XCTSkipIf(repo.isEmpty, "REMOTER_TEST_REPO не задан — нужен ./Tests/local-sshd.sh")
        let ws = Workspace(
            name: "test",
            host: Self.env["REMOTER_TEST_HOST"] ?? "127.0.0.1",
            path: repo,
            port: Int(Self.env["REMOTER_TEST_PORT"] ?? "2222"),
            sshOptions: Self.env["REMOTER_TEST_SSH_OPTS"]
        )
        return WorkspaceModel(workspace: ws)
    }

    /// Путь проекта может вести через симлинк (`/srv/app` → `/mnt/data/app`), а git всегда отдаёт
    /// разрешённый путь. Если их не привести к одному виду, ни один файл дерева не сопоставится
    /// со списком изменений: бейджей не будет, а клик по файлу не откроет diff.
    func testResolvesSymlinkedProjectPath() async throws {
        try XCTSkipIf(repo.isEmpty, "нужен ./Tests/local-sshd.sh")

        // Кладём симлинк на репозиторий и открываем проект ЧЕРЕЗ него.
        let probe = SSHConnection(
            host: Self.env["REMOTER_TEST_HOST"] ?? "127.0.0.1",
            port: Int(Self.env["REMOTER_TEST_PORT"] ?? "2222"),
            extraArgs: Self.env["REMOTER_TEST_SSH_OPTS"]?.split(separator: " ").map(String.init) ?? []
        )
        await probe.connect()
        try TestStand.require(probe.state)

        let link = (repo as NSString).deletingLastPathComponent + "/repo-link"
        try await probe.shOK("rm -f \(shq(link)) && ln -s \(shq(repo)) \(shq(link))")
        probe.disconnect()

        let ws = Workspace(
            name: "через симлинк",
            host: Self.env["REMOTER_TEST_HOST"] ?? "127.0.0.1",
            path: link,
            port: Int(Self.env["REMOTER_TEST_PORT"] ?? "2222"),
            sshOptions: Self.env["REMOTER_TEST_SSH_OPTS"]
        )
        let model = WorkspaceModel(workspace: ws)
        await model.start()
        defer { model.stop() }
        try TestStand.require(model.conn.state)

        XCTAssertEqual(model.basePath, repo, "путь проекта должен разрешиться до настоящего")
        XCTAssertEqual(model.repoRoot, repo)

        // Главное: файл из дерева сопоставился с записью git и получил бейдж.
        let mainPy = model.rows.first { $0.entry.name == "src" }
        XCTAssertNotNil(mainPy)
        XCTAssertEqual(model.relPath(repo + "/src/main.py"), "src/main.py")
        XCTAssertTrue(model.changedDirs.contains("src"), "папка с правками не помечена — пути разъехались")
    }

    func testStartLoadsRepoStatusAndTree() async throws {
        let model = try makeModel()
        await model.start()
        defer { model.stop() }

        try TestStand.require(model.conn.state)

        XCTAssertEqual(model.repoRoot, repo)
        XCTAssertEqual(model.status.branch, "main")
        XCTAssertEqual(model.status.changes.count, 5)

        // Дерево верхнего уровня уже загружено.
        let names = model.rows.map(\.entry.name)
        XCTAssertTrue(names.contains("src"))
        XCTAssertTrue(names.contains("docs"))

        // Бейджи git разложены по путям, и папка с правками помечена.
        XCTAssertEqual(model.kindByPath["src/main.py"], .modified)
        XCTAssertTrue(model.changedDirs.contains("src"))
    }

    func testOpeningChangeGivesBothSidesOfDiff() async throws {
        let model = try makeModel()
        await model.start()
        defer { model.stop() }
        try TestStand.require(model.conn.state)

        let change = try XCTUnwrap(model.status.changes.first { $0.path == "src/main.py" })
        await model.openChange(change)

        let doc = try XCTUnwrap(model.doc)
        XCTAssertEqual(doc.mode, .diff)
        XCTAssertEqual(doc.relPath, "src/main.py")
        XCTAssertEqual(doc.kind, .modified)
        XCTAssertTrue(doc.editable)
        XCTAssertFalse(doc.isDirty)

        // baseline — это то, что реально лежит на сервере: по нему ловятся чужие правки.
        XCTAssertTrue(doc.baseline.contains("HELLO WORLD"))
    }

    /// Ради этого всё и затевалось: Claude правит файл на сервере, а открытый diff обновляется сам.
    ///
    /// Тонкость, которую легко не заметить: файл уже был «изменён» с точки зрения git, поэтому
    /// вывод `git status` после правки НЕ меняется — по нему обновление не поймать. Ловим по
    /// контрольной сумме открытого файла.
    func testPollingPicksUpEditsMadeOnTheServer() async throws {
        let model = try makeModel()
        await model.start()
        defer { model.stop() }
        try TestStand.require(model.conn.state)

        let change = try XCTUnwrap(model.status.changes.first { $0.path == "src/main.py" })
        await model.openChange(change)

        let before = try XCTUnwrap(model.doc).baseline
        let statusBefore = model.status.fingerprint

        // Правку делает кто-то другой прямо на сервере.
        let marker = "# правка, пришедшая с сервера"
        try await model.conn.shOK("printf '%s\\n' \(shq(marker)) >> \(shq(repo + "/src/main.py"))")

        await model.refresh(force: false)

        let after = try XCTUnwrap(model.doc).baseline
        XCTAssertNotEqual(after, before, "правка на сервере не подхватилась")
        XCTAssertTrue(after.contains(marker))
        XCTAssertEqual(model.status.fingerprint, statusBefore,
                       "git status не изменился — значит обновление поймано именно контрольной суммой, а не им")

        // Возвращаем файл как было, чтобы тесты не зависели от порядка.
        try await model.conn.shOK("printf '%s' \(shq(before)) > \(shq(repo + "/src/main.py"))")
    }

    func testSaveWritesThroughToServer() async throws {
        let model = try makeModel()
        await model.start()
        defer { model.stop() }
        try TestStand.require(model.conn.state)

        let change = try XCTUnwrap(model.status.changes.first { $0.path == "src/main.py" })
        await model.openChange(change)
        let original = try XCTUnwrap(model.doc).baseline

        let edited = original + "\n# сохранено из Remoter\n"
        await model.save(path: repo + "/src/main.py", content: edited)

        XCTAssertFalse(try XCTUnwrap(model.doc).isDirty)
        XCTAssertNil(model.errorMessage)

        let onServer = try await RemoteFS.read(conn: model.conn, path: repo + "/src/main.py")
        guard case .text(let text) = onServer else { return XCTFail("файл не читается") }
        XCTAssertEqual(text, edited, "на сервер записалось не то, что было в редакторе")

        try await model.conn.shOK("printf '%s' \(shq(original)) > \(shq(repo + "/src/main.py"))")
    }

    /// Новый файл: слева пусто, справа — весь файл. Иначе git падал бы на `show HEAD:путь`,
    /// которого в HEAD нет.
    func testUntrackedFileDiffsAgainstEmptyLeftSide() async throws {
        let model = try makeModel()
        await model.start()
        defer { model.stop() }
        try TestStand.require(model.conn.state)

        let change = try XCTUnwrap(model.status.changes.first { $0.path == "src/brand_new.py" })
        XCTAssertEqual(change.kind, .untracked)

        await model.openChange(change)
        let doc = try XCTUnwrap(model.doc)
        XCTAssertEqual(doc.mode, .diff)
        XCTAssertTrue(doc.baseline.contains("brand new"))
    }
}
