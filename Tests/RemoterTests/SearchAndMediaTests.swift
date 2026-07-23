import XCTest
@testable import Remoter

/// Поиск по содержимому и определение медиа-файлов.
final class SearchAndMediaTests: XCTestCase {

    // MARK: - Разбор результатов

    /// `git grep -z`: NUL и после пути, и после номера строки (формат снят с живого git 2.50,
    /// а не по памяти — по памяти он был другим, и разбор терял всё).
    func testGitGrepOutputWithNulSeparatorParses() {
        let out = "src/app.py\u{0}12\u{0}retry_count = 3\nдок:стр.md\u{0}42\u{0}про retry_count\n"
        let hits = RemoteSearch.parse(out)

        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].path, "src/app.py")
        XCTAssertEqual(hits[0].line, 12)
        XCTAssertEqual(hits[0].text, "retry_count = 3")
        XCTAssertEqual(hits[1].path, "док:стр.md", "двоеточие в имени файла потеряло путь")
        XCTAssertEqual(hits[1].line, 42)
    }

    /// Обычный grep: `путь:строка:текст`, и `./` от поиска по точке — не часть пути.
    func testPlainGrepOutputParses() {
        let out = "./src/main.go:7:if retries > 0 {\nbroken line without numbers\n"
        let hits = RemoteSearch.parse(out)

        XCTAssertEqual(hits.count, 1, "мусорная строка не должна ломать разбор")
        XCTAssertEqual(hits[0].path, "src/main.go")
        XCTAssertEqual(hits[0].line, 7)
    }

    /// Строки-простыни обрезаются: от минифицированного js в списке один шум.
    func testEndlessLinesAreTruncated() {
        let long = String(repeating: "x", count: 5000)
        let hits = RemoteSearch.parse("a.js:1:\(long)\n")
        XCTAssertLessThanOrEqual(hits[0].text.count, RemoteSearch.maxLineLength + 1)
        XCTAssertTrue(hits[0].text.hasSuffix("…"))
    }

    /// «node_modules, dist» → две папки; разделители — как напишутся.
    func testExcludeListSplitsOnCommasAndSpaces() {
        XCTAssertEqual(RemoteSearch.excludeList("node_modules, dist"), ["node_modules", "dist"])
        XCTAssertEqual(RemoteSearch.excludeList("a b,c"), ["a", "b", "c"])
        XCTAssertEqual(RemoteSearch.excludeList("  "), [])
    }

    // MARK: - Медиа по расширению

    func testMediaKindByExtension() {
        XCTAssertEqual(MediaKind(path: "/a/скриншот.PNG"), .image)
        XCTAssertEqual(MediaKind(path: "видео.mov"), .video)
        XCTAssertEqual(MediaKind(path: "трек.mp3"), .audio)
        XCTAssertNil(MediaKind(path: "код.swift"))
        XCTAssertNil(MediaKind(path: "без-расширения"))
    }

    // MARK: - Живой поиск против стенда

    private static let env = ProcessInfo.processInfo.environment
    private var repo: String { Self.env["REMOTER_TEST_REPO"] ?? "" }

    @MainActor
    private func connected() async throws -> SSHConnection {
        try XCTSkipIf(repo.isEmpty, "нужен ./Tests/local-sshd.sh")
        let conn = SSHConnection(
            host: (Self.env["REMOTER_TEST_HOST"] ?? "127.0.0.1"),
            port: Int(Self.env["REMOTER_TEST_PORT"] ?? "2222"),
            extraArgs: Workspace.splitCommandLine(Self.env["REMOTER_TEST_SSH_OPTS"] ?? "")
        )
        await conn.connect()
        try TestStand.require(conn.state)
        return conn
    }

    /// Поиск на настоящем sshd: находит в репозитории, уважает папку и исключение.
    @MainActor
    func testSearchFindsContentOnRealServer() async throws {
        let conn = try await connected()
        defer { conn.disconnect() }

        // Свои файлы — свой мусор. Метка уникальна на прогон: если прошлый не убрал за собой
        // (упал до уборки), его следы не должны ломать этот. Уборка — await, до disconnect:
        // defer с Task {} — это «может быть, когда-нибудь», а не уборка.
        let token = "ИСКОМОЕ_" + UUID().uuidString.prefix(8)
        let dir = repo + "/поиск-тест"
        _ = try await conn.sh("mkdir -p \(shq(dir + "/внутри")) \(shq(dir + "/мимо"))")

        do {
            _ = try await conn.sh("printf 'здесь \(token) слово\\n' > \(shq(dir + "/внутри/a.txt"))")
            _ = try await conn.sh("printf 'и здесь \(token) тоже\\n' > \(shq(dir + "/мимо/b.txt"))")

            // Весь репозиторий: находятся оба (git grep --untracked видит и незакоммиченное).
            let all = try await RemoteSearch.search(
                conn: conn, root: repo, query: String(token), isRepo: true)
            XCTAssertEqual(all.count, 2, "поиск не нашёл незакоммиченные файлы")

            // Только в папке.
            let scoped = try await RemoteSearch.search(
                conn: conn, root: repo, query: String(token),
                dir: "поиск-тест/внутри", isRepo: true)
            XCTAssertEqual(scoped.map(\.path), ["поиск-тест/внутри/a.txt"])

            // С исключением папки.
            let excluded = try await RemoteSearch.search(
                conn: conn, root: repo, query: String(token),
                exclude: "поиск-тест/мимо", isRepo: true)
            XCTAssertEqual(excluded.map(\.path), ["поиск-тест/внутри/a.txt"],
                           "исключённая папка попала в результаты")
        } catch {
            _ = try? await conn.sh("rm -rf -- \(shq(dir))")
            throw error
        }
        _ = try? await conn.sh("rm -rf -- \(shq(dir))")
    }

    /// Скачивание с настоящего сервера: байты доезжают ровно те, включая бинарные.
    @MainActor
    func testDownloadBringsExactBytes() async throws {
        let conn = try await connected()
        defer { conn.disconnect() }

        let path = repo + "/бинарь-тест.bin"
        // Байты со всем «неудобным»: NUL, перевод строки, не-UTF8.
        _ = try await conn.sh("printf 'A\\000B\\nC\\377' > \(shq(path))")

        // Уборка — await и в обоих исходах: `defer { Task {} }` проигрывает гонку с disconnect,
        // файл выживает — и сосед-тест, считающий файлы в репо, падает на «лишнем».
        let data: Data
        do {
            data = try await RemoteFS.download(conn: conn, path: path)
        } catch {
            _ = try? await conn.sh("rm -f -- \(shq(path))")
            throw error
        }
        _ = try? await conn.sh("rm -f -- \(shq(path))")

        XCTAssertEqual([UInt8](data), [0x41, 0x00, 0x42, 0x0A, 0x43, 0xFF],
                       "скачанное не совпадает с тем, что лежит на сервере")
    }
}
