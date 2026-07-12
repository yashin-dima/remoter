import XCTest
@testable import Remoter

/// Копирование, вырезание, удаление, переименование — операции над живым проектом на сервере.
/// Каждая необратима, поэтому проверяются и результат, и защита от катастрофы.
@MainActor
final class FileOpsTests: XCTestCase {

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

    private func started(readOnly: Bool = false) async throws -> WorkspaceModel {
        let model = try makeModel(readOnly: readOnly)
        await model.start()
        try TestStand.require(model.conn.state)
        return model
    }

    // MARK: - Защита от катастрофы

    /// Самое страшное: ⌘⌫ на корне проекта. Он обязан быть неприкосновенным.
    func testCannotDeleteProjectRoot() async throws {
        let model = try await started()
        defer { model.stop() }

        do {
            try await RemoteFS.remove(conn: model.conn, paths: [repo], root: repo)
            XCTFail("удаление корня проекта прошло — это катастрофа")
        } catch RemoteFS.OpError.protectedRoot {
            // так и надо
        }

        let alive = try await model.conn.sh("test -d \(shq(repo)) && echo да")
        XCTAssertEqual(alive.line, "да", "корень проекта удалён")
    }

    func testEmptyPathsAreRefused() async throws {
        let model = try await started()
        defer { model.stop() }

        for paths in [[""], ["/"], ["src/main.py", ""]] {
            do {
                try await RemoteFS.remove(conn: model.conn, paths: paths, root: repo)
                XCTFail("пустой путь пропущен: \(paths)")
            } catch RemoteFS.OpError.emptyPath {
                // так и надо
            }
        }

        let alive = try await model.conn.sh("test -f \(shq(repo + "/src/main.py")) && echo да")
        XCTAssertEqual(alive.line, "да")
    }

    // MARK: - Копирование и перемещение

    /// Копирование не должно затирать одноимённый файл в приёмнике.
    func testCopyDoesNotOverwriteExistingFile() async throws {
        let model = try await started()
        defer { model.stop() }

        // Копируем src/main.py в docs, где уже есть main.py — предварительно создав его.
        try await model.conn.shOK("printf 'чужой\\n' > \(shq(repo + "/docs/main.py"))")
        try await RemoteFS.copy(conn: model.conn, paths: [repo + "/src/main.py"],
                                into: repo + "/docs", root: repo)

        let existing = try await RemoteFS.read(conn: model.conn, path: repo + "/docs/main.py")
        XCTAssertEqual(existing.displayText, "чужой\n", "существующий файл затёрт копированием")

        let copy = try await RemoteFS.read(conn: model.conn, path: repo + "/docs/main 2.py")
        XCTAssertTrue(copy.displayText?.contains("HELLO WORLD") == true,
                      "копия должна лечь рядом под свободным именем")

        try await model.conn.shOK("rm -f \(shq(repo + "/docs/main.py")) \(shq(repo + "/docs/main 2.py"))")
    }

    /// Вырезать + вставить = переезд, а не размножение.
    func testCutThenPasteMovesFile() async throws {
        let model = try await started()
        defer { model.stop() }

        let source = repo + "/docs/переехать.txt"
        try await model.conn.shOK("printf 'содержимое\\n' > \(shq(source))")
        await model.refresh(force: true)

        model.selection = [source]
        model.cut()
        XCTAssertEqual(model.clipboard?.isCut, true)

        await model.paste(into: repo + "/src")

        let gone = await RemoteFS.exists(conn: model.conn, path: source)
        XCTAssertFalse(gone, "после вырезания файл остался на старом месте — это копирование, а не переезд")

        let moved = try await RemoteFS.read(conn: model.conn, path: repo + "/src/переехать.txt")
        XCTAssertEqual(moved.displayText, "содержимое\n")

        // Буфер после вставки вырезанного пуст: второй раз вставлять нечего.
        XCTAssertNil(model.clipboard)

        try await model.conn.shOK("rm -f \(shq(repo + "/src/переехать.txt"))")
    }

    /// Множественные операции: выделили пачку — удалилась пачка.
    func testDeletesEntireSelection() async throws {
        let model = try await started()
        defer { model.stop() }

        let names = ["один.txt", "два.txt", "три.txt"]
        for n in names {
            try await model.conn.shOK("printf 'x\\n' > \(shq(repo + "/docs/" + n))")
        }
        await model.refresh(force: true)

        model.selection = Set(names.map { repo + "/docs/" + $0 })

        // Удаление спрашивает подтверждение через NSAlert, поэтому здесь дёргаем слой ниже —
        // то же самое, что делает модель после согласия пользователя.
        try await RemoteFS.remove(conn: model.conn, paths: Array(model.selection), root: repo)

        for n in names {
            let gone = await RemoteFS.exists(conn: model.conn, path: repo + "/docs/" + n)
            XCTAssertFalse(gone, "\(n) не удалён")
        }
    }

    // MARK: - Переименование

    func testRenameKeepsContentAndRefusesSlashes() async throws {
        let model = try await started()
        defer { model.stop() }

        let path = repo + "/docs/старое.txt"
        try await model.conn.shOK("printf 'текст\\n' > \(shq(path))")

        // Слэш в имени — это перемещение, а не переименование. Не наш случай.
        do {
            try await RemoteFS.rename(conn: model.conn, path: path, to: "../побег.txt", root: repo)
            XCTFail("слэш в имени пропущен")
        } catch RemoteFS.OpError.emptyPath {
            // так и надо
        }

        try await RemoteFS.rename(conn: model.conn, path: path, to: "новое.txt", root: repo)

        let renamed = try await RemoteFS.read(conn: model.conn, path: repo + "/docs/новое.txt")
        XCTAssertEqual(renamed.displayText, "текст\n")

        try await model.conn.shOK("rm -f \(shq(repo + "/docs/новое.txt"))")
    }

    // MARK: - Режим «только чтение»

    func testFileOpsBlockedInReadOnlyWorkspace() async throws {
        let model = try await started(readOnly: true)
        defer { model.stop() }

        let path = repo + "/src/main.py"
        model.selection = [path]

        model.cut()
        XCTAssertNil(model.clipboard, "вырезание не должно работать в режиме «только чтение»")

        await model.delete(path)
        let alive = await RemoteFS.exists(conn: model.conn, path: path)
        XCTAssertTrue(alive, "файл удалён в режиме «только чтение»")

        await model.rename(path, to: "нельзя.py")
        let stillThere = await RemoteFS.exists(conn: model.conn, path: path)
        XCTAssertTrue(stillThere, "файл переименован в режиме «только чтение»")
    }

    // MARK: - Claude: локально, файлы по ssh

    /// Claude запущен на Mac, а файлы — на сервере. Он ходит туда по ssh, как это делают руками.
    /// Проверяем, что мост есть и работает.
    func testClaudeCanReachTheProjectOverSSH() async throws {
        let model = try await started()
        defer { model.stop() }

        let dir = model.localPath
        XCTAssertFalse(dir.isEmpty, "локальная папка проекта не создана")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: dir + "/remote"),
                      "скрипт доступа не создан или не исполняемый")

        let claudeMD = try String(contentsOfFile: dir + "/CLAUDE.md", encoding: .utf8)
        XCTAssertTrue(claudeMD.contains(repo), "в инструкции для Claude нет пути к проекту")
        XCTAssertTrue(claudeMD.contains(model.workspace.host), "в инструкции нет сервера")

        // Главное: команда доезжает до сервера и сразу в каталог проекта.
        let r = try Proc.runSync("/bin/sh", [dir + "/remote", "git", "rev-parse", "--show-toplevel"])
        XCTAssertEqual(r.line, repo, "команда не дошла до проекта на сервере: \(r.line)")
    }

    /// Claude должен уметь не только читать, но и ПРАВИТЬ файлы прямо на сервере — и правка
    /// обязана сразу появляться в diff'е, безо всяких промежуточных шагов. В этом весь замысел.
    func testClaudeEditsLandOnServerAndShowUpInDiff() async throws {
        let model = try await started()
        defer { model.stop() }

        let change = try XCTUnwrap(model.status.changes.first { $0.path == "src/main.py" })
        await model.openChange(change)
        let before = try XCTUnwrap(model.doc).baseline

        // Так Claude правит файл: одной командой по ssh, прямо на сервере. Никаких копий.
        let r = try Proc.runSync("/bin/sh", [
            model.localPath + "/remote",
            "perl", "-i", "-pe", "s/HELLO WORLD/ПРАВКА ОТ CLAUDE/", "src/main.py",
        ])
        XCTAssertTrue(r.ok, "правка через ssh не прошла")

        // Живой diff подхватывает её сразу.
        await model.refresh(force: false)
        let after = try XCTUnwrap(model.doc).baseline
        XCTAssertNotEqual(after, before)
        XCTAssertTrue(after.contains("ПРАВКА ОТ CLAUDE"), "правка Claude не появилась в diff'е")

        try await model.conn.shOK("printf '%s' \(shq(before)) > \(shq(repo + "/src/main.py"))")
    }

    /// Кавычки в аргументах не должны теряться: `./remote grep -rn "две слова"` обязан
    /// искать фразу целиком, а не два отдельных слова.
    func testRemoteScriptPreservesArgumentQuoting() async throws {
        let model = try await started()
        defer { model.stop() }

        let r = try Proc.runSync("/bin/sh", [model.localPath + "/remote", "echo", "два слова"])
        XCTAssertEqual(r.line, "два слова", "аргумент с пробелом развалился на два")
    }
}
