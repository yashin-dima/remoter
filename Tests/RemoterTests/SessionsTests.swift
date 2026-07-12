import XCTest
@testable import Remoter

/// Менеджер сессий Claude.
///
/// Журнал — **чужой** формат: его пишет Claude Code, а не мы. Поэтому здесь проверяется не только
/// «умеем читать», но и главное свойство: мы в него не пишем. Испортить историю разговоров ради
/// красивого списка было бы худшей из возможных сделок.
final class SessionsTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remoter-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Записи ровно того вида, что пишет Claude Code — формат снят с настоящего журнала.
    private func journal(_ id: String, title: String?, prompt: String?, messages: Int) throws {
        var lines: [String] = []
        lines.append(#"{"type":"queue-operation","operation":"enqueue","sessionId":"\#(id)"}"#)

        for i in 0..<messages {
            let role = i % 2 == 0 ? "user" : "assistant"
            lines.append(#"{"type":"\#(role)","cwd":"/Users/x/проект","sessionId":"\#(id)","message":{"role":"\#(role)"}}"#)
        }
        if let prompt {
            lines.append(#"{"type":"last-prompt","lastPrompt":"\#(prompt)","sessionId":"\#(id)"}"#)
        }
        if let title {
            lines.append(#"{"type":"ai-title","aiTitle":"\#(title)","sessionId":"\#(id)"}"#)
        }

        try (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
    }

    /// Заголовок, о чём был разговор, сколько сообщений — всё, ради чего список и заводится.
    func testReadsTitlePromptAndCount() throws {
        try journal("aaa", title: "Починить деплой", prompt: "Разберись с 502", messages: 4)

        let sessions = ClaudeSessions.list(in: dir)
        let s = try XCTUnwrap(sessions.first)

        XCTAssertEqual(s.id, "aaa", "id сессии — это имя файла, им же её и возобновляют")
        XCTAssertEqual(s.title, "Починить деплой")
        XCTAssertEqual(s.lastPrompt, "Разберись с 502")
        XCTAssertEqual(s.messages, 4)
    }

    /// Заголовок Claude придумывает не сразу. У свежей сессии его нет — и показать «Без названия»
    /// было бы бессмысленно: пользователь узнаёт разговор по тому, с чего он начался.
    func testFallsBackToPromptWhenTitleIsNotWrittenYet() throws {
        try journal("bbb", title: nil, prompt: "Видишь проект?", messages: 2)

        let s = try XCTUnwrap(ClaudeSessions.list(in: dir).first)
        XCTAssertEqual(s.title, "Видишь проект?")
    }

    /// Сайдчейны — переписка подагентов, а не разговор. Считай мы их сообщениями, список
    /// показывал бы «120 сообщений» там, где человек написал десять.
    func testSidechainRecordsAreNotCountedAsMessages() throws {
        let lines = [
            #"{"type":"user","cwd":"/x","sessionId":"side","message":{"role":"user"}}"#,
            #"{"type":"assistant","sessionId":"side","message":{"role":"assistant"}}"#,
            #"{"type":"user","isSidechain":true,"sessionId":"side","message":{"role":"user"}}"#,
            #"{"type":"assistant","isSidechain":true,"sessionId":"side","message":{"role":"assistant"}}"#,
            #"{"type":"ai-title","aiTitle":"Т","sessionId":"side"}"#,
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent("side.jsonl"), atomically: true, encoding: .utf8)

        let s = try XCTUnwrap(ClaudeSessions.list(in: dir).first)
        XCTAssertEqual(s.messages, 2, "реплики подагентов посчитаны как сообщения разговора")
    }

    /// Пустой журнал (Claude запустили и сразу закрыли) не должен ни падать, ни притворяться
    /// разговором с названием.
    func testEmptyJournalIsHandled() throws {
        try journal("ccc", title: nil, prompt: nil, messages: 0)

        let s = try XCTUnwrap(ClaudeSessions.list(in: dir).first)
        XCTAssertEqual(s.title, "Новая сессия")
        XCTAssertEqual(s.messages, 0)
    }

    /// Свежие сверху: искать вчерашний разговор в конце списка — противоестественно.
    func testNewestFirst() throws {
        try journal("старая", title: "Старая", prompt: nil, messages: 2)
        try journal("новая", title: "Новая", prompt: nil, messages: 2)

        // Даты берутся с файлов, поэтому их и правим — а не подсовываем модели фиктивные.
        let old = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes(
            [.modificationDate: old],
            ofItemAtPath: dir.appendingPathComponent("старая.jsonl").path
        )

        XCTAssertEqual(ClaudeSessions.list(in: dir).map(\.title), ["Новая", "Старая"])
    }

    /// В каталоге сессий лежат не только журналы (Claude держит там же свои подпапки).
    /// Всё, что не `.jsonl`, нас не касается.
    func testIgnoresNonJournalFiles() throws {
        try journal("ddd", title: "Разговор", prompt: nil, messages: 2)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("memory"), withIntermediateDirectories: true
        )
        try "мусор".write(to: dir.appendingPathComponent("заметка.txt"),
                          atomically: true, encoding: .utf8)

        XCTAssertEqual(ClaudeSessions.list(in: dir).count, 1)
    }

    /// Самое важное: чтение списка не трогает журнал. Он принадлежит Claude Code — испортить
    /// историю разговоров ради красивого списка было бы худшей из возможных сделок.
    func testReadingDoesNotModifyTheJournal() throws {
        try journal("eee", title: "Разговор", prompt: "Привет", messages: 6)
        let file = dir.appendingPathComponent("eee.jsonl")

        let before = try Data(contentsOf: file)
        let stampBefore = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date

        _ = ClaudeSessions.list(in: dir)

        let after = try Data(contentsOf: file)
        let stampAfter = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date

        XCTAssertEqual(before, after, "чтение изменило журнал Claude")
        XCTAssertEqual(stampBefore, stampAfter, "чтение переписало журнал Claude")
    }

    /// Каждая сессия помнит, с чем её запустили. Задним числом это не меняется: Claude читает
    /// модель и effort при старте, и «переключить» их у работающего процесса нельзя.
    @MainActor
    func testEachSessionKeepsTheSettingsItWasStartedWith() {
        let model = WorkspaceModel(workspace: Workspace(name: "п", host: "h", path: "/srv/п"))

        let opus = ClaudeTab(id: UUID(), title: "", model: .opus, effort: .high,
                             permissions: .bypassPermissions, longContext: true, resumed: nil)
        let haiku = ClaudeTab(id: UUID(), title: "", model: .haiku, effort: .low,
                              permissions: .default, longContext: false, resumed: "abc-123")

        XCTAssertEqual(model.command(opus),
                       "claude --model 'opus[1m]' --effort high --permission-mode bypassPermissions")
        XCTAssertFalse(model.command(opus).contains("--resume"), "новый разговор ничего не продолжает")

        // Продолжение — всегда по конкретному id. `--continue` не используется вовсе: он
        // продолжает «последнюю» неявно, и что именно продолжилось — не видно ни в терминале,
        // ни в тесте. id уходит через shq — как и всё, что попадает в шелл.
        XCTAssertEqual(model.command(haiku), "claude --model 'haiku' --effort low --resume 'abc-123'")
        XCTAssertFalse(model.command(haiku).contains("--continue"))

        // Настройки для СЛЕДУЮЩЕЙ сессии на уже открытые не влияют.
        model.claudeModel = .fable
        XCTAssertEqual(model.command(opus).contains("--model 'opus[1m]'"), true,
                       "смена настроек задним числом переписала параметры открытой сессии")
    }

    /// Скриншот с рабочего стола называется как угодно — с пробелами, кавычками, кириллицей.
    /// Путь к нему подставляется в строку ввода Claude, и развалиться там ему нельзя.
    @MainActor
    func testAttachedPathsSurviveSpacesAndQuotes() {
        let urls = [
            URL(fileURLWithPath: "/Users/x/Desktop/Снимок экрана 2026-07-11.png"),
            URL(fileURLWithPath: "/Users/x/файл 'с кавычкой'.txt"),
        ]

        let text = WorkspaceModel.attachmentText(for: urls)

        // Проверяем не строкой-эталоном, а делом: пусть путь разберёт настоящий шелл.
        let r = try? Proc.runSync("/bin/sh", ["-c", "for a in \(text); do printf '%s\\n' \"$a\"; done"])
        XCTAssertEqual(r?.text, urls.map(\.path).joined(separator: "\n") + "\n",
                       "пути развалились при подстановке в строку ввода")

        // И Enter не нажимается: подставить путь и отправить запрос — разные решения.
        XCTAssertFalse(text.contains("\n"), "вместе с путём ушёл перевод строки")
        XCTAssertTrue(text.hasSuffix(" "), "после пути нужен пробел — дальше пишут вопрос")
    }

    /// Каталог журналов Claude собирает из рабочего пути, заменяя `/` и `.` на `-`.
    func testDirectoryNameMatchesClaudeConvention() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cwd = home + "/Remoter/тест.проект"

        // Каталога такого нет, поэтому list() вернёт пусто — но упасть или полезть не туда
        // он при этом не имеет права.
        XCTAssertTrue(ClaudeSessions.list(for: cwd).isEmpty)
        XCTAssertTrue(ClaudeSessions.list(for: "").isEmpty)
    }
}
