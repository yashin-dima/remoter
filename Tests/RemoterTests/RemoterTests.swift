import XCTest
@testable import Remoter

/// Интеграционные тесты: настоящий ssh против настоящего sshd и настоящего git.
///
/// Мокать тут нечего — вся суть Remoter в стыках с внешними инструментами: разбор
/// `--porcelain=v2 -z`, кавычки в путях, атомарная запись через временный файл. Именно там
/// и живут ошибки, и именно их мок бы не поймал.
///
/// Как поднять окружение — см. Tests/local-sshd.sh. Без него тесты пропускаются, а не падают.
final class RemoterTests: XCTestCase {

    private static let env = ProcessInfo.processInfo.environment
    private static let host = env["REMOTER_TEST_HOST"] ?? "127.0.0.1"
    private static let port = Int(env["REMOTER_TEST_PORT"] ?? "2222")
    private static let repo = env["REMOTER_TEST_REPO"] ?? ""

    /// Тестовый ключ и known_hosts берём свои: пользовательский ~/.ssh трогать нельзя,
    /// а ssh раскрывает `~` через passwd, а не через $HOME — подменой HOME его не обмануть.
    private static var sshArgs: [String] {
        env["REMOTER_TEST_SSH_OPTS"]?
            .split(separator: " ")
            .map(String.init) ?? []
    }

    @MainActor
    private func connect() async throws -> SSHConnection {
        let conn = SSHConnection(host: Self.host, port: Self.port, extraArgs: Self.sshArgs)
        await conn.connect()
        // Стенда нет — пропускаем; стенд есть, а связи нет — это провал, а не «пропущено».
        try TestStand.require(conn.state)
        return conn
    }

    // MARK: - Транспорт

    @MainActor
    func testRunsRemoteCommand() async throws {
        let conn = try await connect()
        defer { conn.disconnect() }

        let r = try await conn.shOK("echo hello")
        XCTAssertEqual(r.line, "hello")
    }

    /// Пути с пробелами, кавычками и юникодом — самая частая причина, по которой «всё сломалось».
    @MainActor
    func testQuotingSurvivesNastyPaths() async throws {
        let conn = try await connect()
        defer { conn.disconnect() }

        let nasty = Self.repo + "/docs/файл с пробелом.md"
        let r = try await conn.shOK("cat -- \(shq(nasty))")
        XCTAssertEqual(r.line, "имя с пробелом")

        // Одинарная кавычка в имени — то, на чём ломается наивное экранирование.
        let tricky = Self.repo + "/it's a file.txt"
        try await RemoteFS.write(conn: conn, path: tricky, content: "ok\n")
        let back = try await RemoteFS.read(conn: conn, path: tricky)
        guard case .text(let s) = back else { return XCTFail("ожидался текст, получили \(back)") }
        XCTAssertEqual(s, "ok\n")
        try await conn.shOK("rm -f -- \(shq(tricky))")
    }

    // MARK: - git status

    @MainActor
    func testParsesEveryChangeKind() async throws {
        let conn = try await connect()
        defer { conn.disconnect() }

        let root = await Git.repoRoot(conn: conn, path: Self.repo)
        XCTAssertEqual(root, Self.repo)

        let status = try await Git.status(conn: conn, root: Self.repo)
        XCTAssertEqual(status.branch, "main")

        func change(_ path: String) -> GitChange? {
            status.changes.first { $0.path == path }
        }

        XCTAssertEqual(change("src/main.py")?.kind, .modified)
        XCTAssertEqual(change("docs/gone.md")?.kind, .deleted)
        XCTAssertEqual(change("src/brand_new.py")?.kind, .untracked)
        XCTAssertEqual(change("src/utils/helper.ts")?.kind, .modified)

        // Переименование: важно, что прежнее имя разобралось. Оно приезжает отдельной
        // NUL-записью, и если её не «съесть», разбор всего хвоста уезжает на одну запись.
        let renamed = change("src/new_name.py")
        XCTAssertEqual(renamed?.kind, .renamed)
        XCTAssertEqual(renamed?.origPath, "src/old_name.py")

        // Ровно пять — значит лишних записей от переименования не просочилось.
        XCTAssertEqual(status.changes.count, 5, "разобрано: \(status.changes.map(\.path))")

        // Индекс против рабочей копии: helper.ts подготовлен, main.py — нет.
        XCTAssertEqual(change("src/utils/helper.ts")?.isStaged, true)
        XCTAssertEqual(change("src/main.py")?.isStaged, false)
    }

    /// У файла два статуса сразу — в индексе и в рабочей копии. Показывать надо существенный:
    /// «RM» — это переименование, а не просто правка, иначе непонятно, куда делся старый файл.
    func testCombinedStatusPicksTheMeaningfulKind() {
        func kind(_ xy: String) -> ChangeKind? {
            let raw = "1 \(xy) N... 100644 100644 100644 aaa bbb file.txt\0"
            return Git.parse(Data(raw.utf8)).changes.first?.kind
        }

        XCTAssertEqual(kind("RM"), .renamed, "переименован и правлен — важно, что переименован")
        XCTAssertEqual(kind("AM"), .added, "в HEAD его не было, значит новый, а не изменённый")
        XCTAssertEqual(kind("AD"), .deleted, "добавили в индекс, потом удалили из копии — файла нет")
        XCTAssertEqual(kind("MM"), .modified)
        XCTAssertEqual(kind(".M"), .modified)
        XCTAssertEqual(kind("M."), .modified)
        XCTAssertEqual(kind("D."), .deleted)
        XCTAssertEqual(kind(".D"), .deleted)
    }

    /// Тот же разбор, но на синтетическом буфере: страховка на случай, если репозиторий
    /// в тестах изменится и перестанет покрывать редкие ветки формата.
    func testParsesUnmergedAndIgnoredRecords() {
        var raw = ""
        raw += "# branch.head feature/x\0"
        raw += "# branch.ab +3 -2\0"
        raw += "1 .M N... 100644 100644 100644 aaa bbb path/one.txt\0"
        raw += "2 R. N... 100644 100644 100644 aaa bbb R100 new dir/two.txt\0old dir/two.txt\0"
        raw += "u UU N... 100644 100644 100644 100644 aaa bbb ccc merge.txt\0"
        raw += "? untracked file.txt\0"
        raw += "! ignored.txt\0"

        let st = Git.parse(Data(raw.utf8))

        XCTAssertEqual(st.branch, "feature/x")
        XCTAssertEqual(st.ahead, 3)
        XCTAssertEqual(st.behind, 2)

        // Игнорируемые не показываем, остальные четыре — да.
        XCTAssertEqual(st.changes.count, 4, "\(st.changes.map(\.path))")
        XCTAssertEqual(st.changes.first { $0.kind == .conflicted }?.path, "merge.txt")
        XCTAssertEqual(st.changes.first { $0.kind == .untracked }?.path, "untracked file.txt")

        // Пробелы в обоих именах при переименовании — путь не должен обрезаться по пробелу.
        let renamed = st.changes.first { $0.kind == .renamed }
        XCTAssertEqual(renamed?.path, "new dir/two.txt")
        XCTAssertEqual(renamed?.origPath, "old dir/two.txt")
    }

    // MARK: - Стороны diff'а

    @MainActor
    func testDiffSidesForModifiedFile() async throws {
        let conn = try await connect()
        defer { conn.disconnect() }

        let head = try await Git.show(conn: conn, root: Self.repo, rev: "HEAD", path: "src/main.py")
        XCTAssertNotNil(head)
        guard case .text(let original) = RemoteFS.decode(head!) else { return XCTFail("не текст") }
        XCTAssertTrue(original.contains("print(\"hi\")"), "в HEAD должна быть старая версия")

        let work = try await RemoteFS.read(conn: conn, path: Self.repo + "/src/main.py")
        guard case .text(let modified) = work else { return XCTFail("не текст") }
        XCTAssertTrue(modified.contains("HELLO WORLD"), "в рабочей копии — новая")
        XCTAssertNotEqual(original, modified)
    }

    /// Для переименованного файла левую сторону надо брать по СТАРОМУ пути, иначе diff
    /// покажет «файл целиком новый» вместо реальной пары изменённых строк.
    @MainActor
    func testDiffOriginalUsesOldPathForRename() async throws {
        let conn = try await connect()
        defer { conn.disconnect() }

        let byNewName = try await Git.show(conn: conn, root: Self.repo, rev: "HEAD", path: "src/new_name.py")
        XCTAssertNil(byNewName, "по новому имени в HEAD ничего быть не должно")

        let byOldName = try await Git.show(conn: conn, root: Self.repo, rev: "HEAD", path: "src/old_name.py")
        XCTAssertNotNil(byOldName, "а по старому — должна лежать исходная версия")
    }

    // MARK: - Файловая система

    @MainActor
    func testListsDirectoryWithFoldersFirst() async throws {
        let conn = try await connect()
        defer { conn.disconnect() }

        let entries = try await RemoteFS.list(conn: conn, dir: Self.repo)
        let names = entries.map(\.name)

        XCTAssertTrue(names.contains("src"))
        XCTAssertTrue(names.contains("docs"))
        XCTAssertTrue(names.contains(".git"), "скрытые файлы тоже должны попадать в дерево")

        let firstFileIndex = entries.firstIndex { !$0.isDir } ?? entries.count
        let lastDirIndex = entries.lastIndex { $0.isDir } ?? -1
        XCTAssertLessThan(lastDirIndex, firstFileIndex, "папки должны идти раньше файлов")
    }

    @MainActor
    func testDetectsBinaryAndOversizedFiles() async throws {
        let conn = try await connect()
        defer { conn.disconnect() }

        let blob = try await RemoteFS.read(conn: conn, path: Self.repo + "/docs/blob.bin")
        guard case .binary = blob else { return XCTFail("blob.bin должен определиться как бинарник, а не \(blob)") }

        let missing = try await RemoteFS.read(conn: conn, path: Self.repo + "/нет-такого-файла")
        guard case .missing = missing else { return XCTFail("ожидался .missing, получили \(missing)") }
    }

    /// Запись атомарна и сохраняет права: скрипт после сохранения не должен терять +x.
    @MainActor
    func testWritePreservesExecutableBit() async throws {
        let conn = try await connect()
        defer { conn.disconnect() }

        let path = Self.repo + "/run.sh"
        try await conn.shOK("printf '#!/bin/sh\\necho one\\n' > \(shq(path)) && chmod +x \(shq(path))")

        try await RemoteFS.write(conn: conn, path: path, content: "#!/bin/sh\necho two\n")

        let back = try await RemoteFS.read(conn: conn, path: path)
        guard case .text(let s) = back else { return XCTFail("не текст") }
        XCTAssertEqual(s, "#!/bin/sh\necho two\n")

        let exec = try await conn.sh("test -x \(shq(path)) && echo yes || echo no")
        XCTAssertEqual(exec.line, "yes", "после сохранения файл потерял бит +x")

        // И никакого мусора от временного файла рядом не осталось.
        let leftovers = try await conn.shOK("ls -1 \(shq(Self.repo)) | grep -c remoter.tmp || true")
        XCTAssertEqual(leftovers.line, "0")

        try await conn.shOK("rm -f -- \(shq(path))")
    }

    @MainActor
    func testLsFilesFeedsQuickOpen() async throws {
        let conn = try await connect()
        defer { conn.disconnect() }

        let files = try await Git.lsFiles(conn: conn, root: Self.repo)
        XCTAssertTrue(files.contains("src/main.py"))
        XCTAssertTrue(files.contains("src/brand_new.py"), "неотслеживаемые файлы тоже нужны в ⌘P")
        XCTAssertTrue(files.contains("docs/файл с пробелом.md"), "юникод в именах не должен теряться")
    }
}
