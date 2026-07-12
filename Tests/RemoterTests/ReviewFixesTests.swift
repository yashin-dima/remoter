import XCTest
@testable import Remoter

/// Юнит-тесты на исправления код-ревью: разбор ssh-опций, строгий UTF-8 в выводе git,
/// защита корня от «хвостатых» путей, managed-блок в CLAUDE.md, закрепление локальной папки.
/// Всё — чистые функции, ssh не нужен.
@MainActor
final class ReviewFixesTests: XCTestCase {

    // MARK: - Разбор sshOptions (мини-shlex)

    /// Главный сценарий: путь к ключу с пробелом. Наивный split по пробелам разломал бы его,
    /// и ssh получил бы половину пути вместо ключа.
    func testSSHOptionsKeepQuotedPathWithSpacesIntact() {
        let ws = Workspace(name: "т", host: "h", path: "/p",
                           sshOptions: "-i '/Users/me/My Keys/id_ed25519' -J bastion")
        XCTAssertEqual(ws.extraSSHArgs,
                       ["-i", "/Users/me/My Keys/id_ed25519", "-J", "bastion"])
    }

    func testSSHOptionsDoubleQuotesAndEscapes() {
        XCTAssertEqual(Workspace.splitCommandLine(#"-i "/tmp/a b" -o ProxyCommand="ssh -W %h:%p j""#),
                       ["-i", "/tmp/a b", "-o", "ProxyCommand=ssh -W %h:%p j"])
        XCTAssertEqual(Workspace.splitCommandLine(#"-i /tmp/a\ b"#), ["-i", "/tmp/a b"])
    }

    func testSSHOptionsPlainSplitStillWorks() {
        XCTAssertEqual(Workspace.splitCommandLine("  -p 2222   -4 "), ["-p", "2222", "-4"])
        XCTAssertEqual(Workspace.splitCommandLine(""), [])
        XCTAssertEqual(Workspace.splitCommandLine("   "), [])
    }

    /// Пустой аргумент в кавычках — это всё же аргумент, а незакрытая кавычка не должна
    /// молча съедать хвост строки.
    func testSSHOptionsEdgeCases() {
        XCTAssertEqual(Workspace.splitCommandLine("-o ''"), ["-o", ""])
        XCTAssertEqual(Workspace.splitCommandLine("-i '/tmp/незакрытая"), ["-i", "/tmp/незакрытая"])
    }

    // MARK: - Строгий UTF-8 в разборе git status

    private func porcelain(_ records: [String]) -> Data {
        Data(records.joined(separator: "\u{0}").utf8)
    }

    /// Запись с именем не в UTF-8 пропускается ЦЕЛИКОМ — испорченный заменами путь ушёл бы
    /// потом в rm/git add и указывал бы не на тот файл. Соседние записи при этом живы.
    func testParseSkipsRecordWithInvalidUTF8PathButKeepsTheRest() {
        var data = Data("1 .M N... 100644 100644 100644 0000 0000 до.txt".utf8)
        data.append(0)
        data.append(contentsOf: Data("1 .M N... 100644 100644 100644 0000 0000 ".utf8))
        data.append(contentsOf: [0xC3, 0x28]) // невалидный UTF-8 в имени
        data.append(0)
        data.append(contentsOf: Data("1 .M N... 100644 100644 100644 0000 0000 после.txt".utf8))

        let st = Git.parse(data)
        XCTAssertEqual(st.changes.map(\.path), ["до.txt", "после.txt"],
                       "битая запись должна пропускаться, не ломая соседние")
    }

    /// У переименования прежнее имя лежит в СЛЕДУЮЩЕЙ NUL-записи. Даже если сама запись
    /// не декодируется, её вторую запись надо съесть — иначе прежнее имя уедет в разбор
    /// как отдельная запись, и всё поедет.
    func testParseRenameConsumesOrigEvenWhenRecordIsInvalid() {
        var data = Data()
        data.append(contentsOf: Data("2 R. N... 100644 100644 100644 0000 0000 R100 ".utf8))
        data.append(contentsOf: [0xC3, 0x28]) // невалидное новое имя
        data.append(0)
        // Прежнее имя нарочно похоже на запись «?»: не съешь его — оно распарсится
        // как отдельный untracked-файл.
        data.append(contentsOf: Data("? фальшивый.txt".utf8))
        data.append(0)
        data.append(contentsOf: Data("? новый.txt".utf8))

        let st = Git.parse(data)
        XCTAssertEqual(st.changes.map(\.path), ["новый.txt"],
                       "прежнее имя переименования просочилось в разбор как отдельная запись")
    }

    func testParseRenameStillCarriesOrigPath() {
        let data = porcelain([
            "2 R. N... 100644 100644 100644 0000 0000 R100 новое.txt",
            "старое.txt",
            "? мимо.txt",
        ])
        let st = Git.parse(data)
        let rename = st.changes.first { $0.kind == .renamed }
        XCTAssertEqual(rename?.path, "новое.txt")
        XCTAssertEqual(rename?.origPath, "старое.txt")
        XCTAssertTrue(st.changes.contains { $0.path == "мимо.txt" })
    }

    // MARK: - Защита корня проекта

    /// `/srv/app/` — это тот же корень, что и `/srv/app`: косая черта не пропуск.
    func testRootProtectionSurvivesTrailingSlashes() {
        XCTAssertThrowsError(try RemoteFS.check(["/srv/app/"], root: "/srv/app"))
        XCTAssertThrowsError(try RemoteFS.check(["/srv/app/."], root: "/srv/app"))
        XCTAssertThrowsError(try RemoteFS.check(["/srv/app"], root: "/srv/app/"))
        XCTAssertThrowsError(try RemoteFS.check(["/"], root: "/srv/app"))
        XCTAssertThrowsError(try RemoteFS.check([""], root: "/srv/app"))
        XCTAssertNoThrow(try RemoteFS.check(["/srv/app/file.txt"], root: "/srv/app"))
    }

    // MARK: - Тильда в путях

    /// Пользователь вводит путь как в терминале, а внутри одинарных кавычек тильду
    /// не развернул бы уже никто — поэтому `~/…` уходит как `"$HOME"/…`.
    func testShqPathExpandsTilde() {
        XCTAssertEqual(shqPath("~"), "\"$HOME\"")
        XCTAssertEqual(shqPath("~/мой проект"), "\"$HOME\"/'мой проект'")
        XCTAssertEqual(shqPath("/srv/app"), "'/srv/app'")
        // Тильда в середине — обычный символ.
        XCTAssertEqual(shqPath("/srv/~app"), "'/srv/~app'")
    }

    // MARK: - CLAUDE.md: managed-блок

    func testClaudeMDCreatedWithMarkers() {
        let out = LocalWorkspace.mergedClaudeMD(existing: nil, generated: "тело")
        XCTAssertTrue(out.contains(LocalWorkspace.claudeMDBegin))
        XCTAssertTrue(out.contains("тело"))
        XCTAssertTrue(out.contains(LocalWorkspace.claudeMDEnd))
    }

    /// Главное свойство: пользовательский текст ВНЕ маркеров переживает provision.
    func testClaudeMDKeepsUserTextOutsideMarkers() {
        let existing = """
        Мои важные заметки сверху.

        \(LocalWorkspace.claudeMDBegin)
        старый сгенерированный текст
        \(LocalWorkspace.claudeMDEnd)

        И снизу тоже мои.
        """
        let out = LocalWorkspace.mergedClaudeMD(existing: existing, generated: "новый текст")

        XCTAssertTrue(out.contains("Мои важные заметки сверху."), "текст до блока потерян")
        XCTAssertTrue(out.contains("И снизу тоже мои."), "текст после блока потерян")
        XCTAssertTrue(out.contains("новый текст"))
        XCTAssertFalse(out.contains("старый сгенерированный текст"), "наш блок не обновился")
    }

    func testClaudeMDUpdateIsIdempotent() {
        let once = LocalWorkspace.mergedClaudeMD(existing: nil, generated: "тело")
        let twice = LocalWorkspace.mergedClaudeMD(existing: once, generated: "тело")
        XCTAssertEqual(once, twice, "повторный provision без изменений не должен менять файл")
    }

    // MARK: - Локальная папка: одноимённые проекты не делят каталог

    func testSameNamedWorkspacesGetSeparateLocalDirectories() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remoter-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("REMOTER_HOME", home.path, 1)
        defer {
            unsetenv("REMOTER_HOME")
            try? FileManager.default.removeItem(at: home)
        }

        let a = Workspace(name: "api", host: "alpha.example.com", path: "/srv/api")
        let b = Workspace(name: "api", host: "beta.example.com", path: "/srv/api")

        let dirA = try LocalWorkspace.claimDirectory(for: a)
        let dirB = try LocalWorkspace.claimDirectory(for: b)

        XCTAssertNotEqual(dirA.path, dirB.path,
                          "одноимённые проекты делят папку — remote и CLAUDE.md затирают друг друга")

        // Повторное открытие возвращает ту же папку, а не плодит новые.
        XCTAssertEqual(try LocalWorkspace.claimDirectory(for: a).path, dirA.path)
        XCTAssertEqual(try LocalWorkspace.claimDirectory(for: b).path, dirB.path)
    }

    /// Папка из времён до маркеров усыновляется, а не бросается: к её ПУТИ привязана
    /// история сессий Claude, терять её при обновлении нельзя.
    func testLegacyDirectoryWithoutMarkerIsAdopted() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remoter-home-\(UUID().uuidString)")
        setenv("REMOTER_HOME", home.path, 1)
        defer {
            unsetenv("REMOTER_HOME")
            try? FileManager.default.removeItem(at: home)
        }

        let ws = Workspace(name: "старый", host: "h", path: "/srv/старый")
        let legacy = LocalWorkspace.directory(for: ws)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)

        let claimed = try LocalWorkspace.claimDirectory(for: ws)
        XCTAssertEqual(claimed.path, legacy.path, "папка без маркера должна усыновляться")

        let marker = legacy.appendingPathComponent(LocalWorkspace.ownerMarkerName)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8)
                           .trimmingCharacters(in: .whitespacesAndNewlines),
                       ws.id.uuidString)
    }
}
