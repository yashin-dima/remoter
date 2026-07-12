import XCTest
@testable import Remoter

/// Тесты на сохранность данных. Каждый закрывает конкретный способ испортить файл на сервере.
///
/// Это не про «удобно», это про «не потерять чужую работу»: приложение ходит в живые проекты,
/// в которых прямо сейчас может работать агент.
@MainActor
final class SafetyTests: XCTestCase {

    private static let env = ProcessInfo.processInfo.environment
    private var repo: String { Self.env["REMOTER_TEST_REPO"] ?? "" }

    private func connect() async throws -> SSHConnection {
        try XCTSkipIf(repo.isEmpty, "нужен ./Tests/local-sshd.sh")
        let conn = SSHConnection(
            host: Self.env["REMOTER_TEST_HOST"] ?? "127.0.0.1",
            port: Int(Self.env["REMOTER_TEST_PORT"] ?? "2222"),
            extraArgs: Self.env["REMOTER_TEST_SSH_OPTS"]?.split(separator: " ").map(String.init) ?? []
        )
        await conn.connect()
        try TestStand.require(conn.state)
        return conn
    }

    // MARK: - Запись

    /// Симлинк должен остаться симлинком. Голый `mv` временного файла на место заменил бы
    /// саму ссылку обычным файлом — а в проектах на симлинках держат конфиги и общие модули.
    func testWriteFollowsSymlinkInsteadOfReplacingIt() async throws {
        let conn = try await connect()
        defer { conn.disconnect() }

        let target = repo + "/real.txt"
        let link = repo + "/link.txt"
        try await conn.shOK("printf 'было\\n' > \(shq(target)) && ln -sf real.txt \(shq(link))")

        try await RemoteFS.write(conn: conn, path: link, content: "стало\n")

        let stillLink = try await conn.sh("test -L \(shq(link)) && echo да || echo нет")
        XCTAssertEqual(stillLink.line, "да", "симлинк заменён обычным файлом — связь с оригиналом потеряна")

        let onTarget = try await RemoteFS.read(conn: conn, path: target)
        XCTAssertEqual(onTarget.displayText, "стало\n", "запись не дошла до настоящего файла")

        try await conn.shOK("rm -f \(shq(target)) \(shq(link))")
    }

    /// Оборванная передача не должна оставлять на месте файла обрубок.
    ///
    /// Проверяем сам предохранитель: скармливаем скрипту записи на один байт меньше, чем он
    /// ожидает, — ровно то, что случилось бы при обрыве связи (`cat` увидел бы EOF и завершился
    /// УСПЕШНО). Файл обязан остаться прежним.
    func testTruncatedTransferLeavesOriginalIntact() async throws {
        let conn = try await connect()
        defer { conn.disconnect() }

        let path = repo + "/precious.txt"
        let original = "очень важные данные\n"
        try await conn.shOK("printf '%s' \(shq(original)) > \(shq(path))")

        // БОЕВОЙ скрипт записи — не копия. Просто говорим ему, что байт будет на один больше,
        // чем на самом деле пришлём: ровно так выглядит обрыв связи с точки зрения сервера.
        let sent = "обрубок"
        let script = RemoteFS.writeScript(path: path, expectedBytes: sent.utf8.count + 1)

        let r = try await conn.sh(script, stdin: Data(sent.utf8))
        XCTAssertEqual(r.code, RemoteFS.truncatedExitCode,
                       "предохранитель не сработал — недоехавший файл был бы поставлен на место")

        let after = try await RemoteFS.read(conn: conn, path: path)
        XCTAssertEqual(after.displayText, original, "файл на сервере испорчен обрубком")

        let leftovers = try await conn.shOK("ls -1a \(shq(repo)) | grep -c remoter.tmp || true")
        XCTAssertEqual(leftovers.line, "0", "временный файл остался мусором на сервере")

        try await conn.shOK("rm -f \(shq(path))")
    }

    /// Файл не в UTF-8 показываем, но править не даём: обратно мы пишем UTF-8, и «сохранение»
    /// даже без единой правки молча перекодировало бы весь файл.
    func testNonUTF8FileIsReadOnly() async throws {
        let conn = try await connect()
        defer { conn.disconnect() }

        // «Привет» в windows-1251 — валидные байты, но не UTF-8.
        let path = repo + "/cp1251.txt"
        try await conn.shOK("printf '\\317\\360\\350\\342\\345\\362\\n' > \(shq(path))")

        let file = try await RemoteFS.read(conn: conn, path: path)
        guard case .foreignEncoding = file else {
            return XCTFail("файл не в UTF-8 должен распознаваться как таковой, а не как \(file)")
        }
        XCTAssertFalse(file.isEditable, "такой файл нельзя открывать на запись — сохранение испортит его")
        XCTAssertNotNil(file.displayText, "но показать его всё равно нужно")

        try await conn.shOK("rm -f \(shq(path))")
    }

    /// Права файла переживают сохранение: скрипт не должен терять +x.
    func testWriteKeepsFileMode() async throws {
        let conn = try await connect()
        defer { conn.disconnect() }

        let path = repo + "/deploy.sh"
        try await conn.shOK("printf '#!/bin/sh\\necho v1\\n' > \(shq(path)) && chmod 755 \(shq(path))")

        try await RemoteFS.write(conn: conn, path: path, content: "#!/bin/sh\necho v2\n")

        let mode = try await conn.shOK("ls -l \(shq(path)) | cut -c1-10")
        XCTAssertTrue(mode.line.contains("rwx"), "после сохранения файл потерял право на исполнение: \(mode.line)")

        try await conn.shOK("rm -f \(shq(path))")
    }

    /// Перевод строки Windows не должен молча превращаться в Unix: иначе одно сохранение
    /// показало бы весь файл как изменённый целиком.
    func testCRLFSurvivesRoundTrip() async throws {
        let conn = try await connect()
        defer { conn.disconnect() }

        let path = repo + "/crlf.txt"
        let content = "первая\r\nвторая\r\n"
        try await RemoteFS.write(conn: conn, path: path, content: content)

        let back = try await RemoteFS.read(conn: conn, path: path)
        XCTAssertEqual(back.displayText, content, "перевод строки изменился при записи")

        try await conn.shOK("rm -f \(shq(path))")
    }

    // MARK: - Разрушающие git-операции

    /// Пустой путь в разрушающей команде — это `rm -f <корень>/` и стёртые файлы.
    /// Git такого не отдаёт, но защита должна стоять раньше, чем shell.
    func testDestructiveOpsRefuseEmptyPath() async throws {
        let conn = try await connect()
        defer { conn.disconnect() }

        let empty = GitChange(path: "", origPath: nil, x: "?", y: "?", kind: .untracked)

        for op in ["discard", "stage", "unstage"] {
            do {
                switch op {
                case "discard": try await Git.discard(conn: conn, root: repo, change: empty)
                case "stage":   try await Git.stage(conn: conn, root: repo, change: empty)
                default:        try await Git.unstage(conn: conn, root: repo, change: empty)
                }
                XCTFail("\(op) с пустым путём должен быть отвергнут")
            } catch Git.GitError.emptyPath {
                // так и надо
            }
        }

        // И репозиторий на месте.
        let alive = try await conn.sh("test -f \(shq(repo + "/src/main.py")) && echo да || echo нет")
        XCTAssertEqual(alive.line, "да")
    }

    // MARK: - Режим «только чтение»

    /// Главная гарантия: в этом режиме приложение не выполняет НИ ОДНОЙ изменяющей команды.
    /// Проверяем не то, что кнопки спрятаны, а то, что операции действительно ничего не делают.
    func testReadOnlyWorkspaceNeverWrites() async throws {
        try XCTSkipIf(repo.isEmpty, "нужен ./Tests/local-sshd.sh")

        let ws = Workspace(
            name: "только чтение",
            host: Self.env["REMOTER_TEST_HOST"] ?? "127.0.0.1",
            path: repo,
            port: Int(Self.env["REMOTER_TEST_PORT"] ?? "2222"),
            sshOptions: Self.env["REMOTER_TEST_SSH_OPTS"],
            readOnly: true
        )
        let model = WorkspaceModel(workspace: ws)
        await model.start()
        defer { model.stop() }
        try TestStand.require(model.conn.state)

        XCTAssertFalse(model.canWrite)

        let before = try await RemoteFS.read(conn: model.conn, path: repo + "/src/main.py")
        let statusBefore = model.status.changes.count

        let change = try XCTUnwrap(model.status.changes.first { $0.path == "src/main.py" })
        await model.openChange(change)

        // Файл открыт, но только на чтение — и причина названа.
        let doc = try XCTUnwrap(model.doc)
        XCTAssertFalse(doc.editable)
        XCTAssertEqual(doc.readOnlyReason, "Проект открыт только для чтения")

        // Каждая изменяющая операция — мимо.
        await model.save(path: repo + "/src/main.py", content: "ЭТО НЕ ДОЛЖНО ПОПАСТЬ НА СЕРВЕР")
        await model.stage(change)
        await model.stageAll()
        await model.commit(message: "не должно случиться")

        let after = try await RemoteFS.read(conn: model.conn, path: repo + "/src/main.py")
        XCTAssertEqual(after.displayText, before.displayText, "файл изменился в режиме «только чтение»")

        await model.refresh(force: true)
        XCTAssertEqual(model.status.changes.count, statusBefore, "состояние git изменилось в режиме «только чтение»")
    }

    // MARK: - Ничего не пишем без спроса

    /// Поллинг и открытие файлов не должны менять на сервере ровно ничего. Приложение пишет
    /// только по явному действию пользователя — это и есть главное свойство безопасности.
    func testBrowsingAndPollingNeverModifyAnything() async throws {
        let conn = try await connect()
        defer { conn.disconnect() }

        // Слепок: полный список файлов с размерами и правами + состояние git.
        let snapshot = """
        cd \(shq(repo)) && find . -not -path './.git/*' | LC_ALL=C sort | while read -r f; do
          printf '%s %s\\n' "$f" "$(wc -c < "$f" 2>/dev/null || echo dir)"
        done
        git -C \(shq(repo)) status --porcelain=v2 -z -uall | od -c | tail -5
        """
        let before = try await conn.shOK(snapshot).text

        let ws = Workspace(
            name: "просмотр",
            host: Self.env["REMOTER_TEST_HOST"] ?? "127.0.0.1",
            path: repo,
            port: Int(Self.env["REMOTER_TEST_PORT"] ?? "2222"),
            sshOptions: Self.env["REMOTER_TEST_SSH_OPTS"]
        )
        let model = WorkspaceModel(workspace: ws)
        await model.start()
        defer { model.stop() }
        try TestStand.require(model.conn.state)

        // Ходим по всему, что умеет приложение, кроме явных изменяющих действий.
        for change in model.status.changes {
            await model.openChange(change)
        }
        await model.openFile(repo + "/docs/readme.md")
        await model.openFile(repo + "/docs/blob.bin")
        for row in model.rows where row.entry.isDir {
            model.toggle(row.entry)
        }
        model.diffBase = .index
        await model.refresh(force: true)
        await model.refresh(force: true)

        let after = try await conn.shOK(snapshot).text
        XCTAssertEqual(after, before, "просмотр проекта изменил что-то на сервере")
    }
}
