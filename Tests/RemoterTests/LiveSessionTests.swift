import XCTest
@testable import Remoter

/// Плашка над терминалом должна показывать, что у сессии ПРОИСХОДИТ, а не с чем её запустили.
///
/// Разница не теоретическая: модель меняют `/model`, уровень reasoning — `/effort`, режим
/// разрешений — shift+tab. Всё это — уже внутри работающего Claude, и флаги запуска после этого
/// врут. Единственный источник правды — журнал, который Claude ведёт сам. Формат журнала чужой,
/// поэтому здесь он воспроизведён ровно так, как выглядит на диске.
final class LiveSessionTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remoter-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Дописывает строки в журнал — так же, как это делает сам Claude: по строке JSON за раз.
    private func append(_ lines: [String], to session: String) throws {
        let file = dir.appendingPathComponent("\(session).jsonl")
        let text = lines.joined(separator: "\n") + "\n"

        if let handle = try? FileHandle(forWritingTo: file) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } else {
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private func probe(resuming id: String? = nil) -> SessionProbe {
        SessionProbe(id: UUID(), startedAt: Date().addingTimeInterval(-1), resumed: id)
    }

    // MARK: -

    /// Главное: `/effort xhigh`, набранный в терминале, доезжает до плашки.
    ///
    /// Effort — единственный параметр, который Claude не записывает отдельным полем: в журнале
    /// он виден только как набранная пользователем команда. Не разбирай мы её — плашка так и
    /// показывала бы `high`, с которым сессию запустили час назад.
    func testEffortTypedInsideTheSessionReachesTheBar() throws {
        try append([
            #"{"type":"permission-mode","permissionMode":"bypassPermissions","sessionId":"s"}"#,
            #"{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-8"}}"#,
        ], to: "s")

        var p = probe(resuming: "s")
        p = ClaudeJournal.follow(in: dir, probes: [p])[0]

        XCTAssertEqual(p.live.effort, nil, "effort взялся из ниоткуда — в журнале его ещё нет")
        XCTAssertEqual(p.live.model, "Opus 4.8")
        XCTAssertEqual(p.live.permissions, .bypassPermissions)

        // Пользователь набирает /effort xhigh. Claude пишет это в журнал как обычную реплику.
        try append([
            #"{"type":"user","message":{"role":"user","content":"<command-name>/effort</command-name>\n<command-args>xhigh</command-args>"}}"#,
        ], to: "s")

        p = ClaudeJournal.follow(in: dir, probes: [p])[0]
        XCTAssertEqual(p.live.effort, .xhigh, "смена effort не доехала до плашки")
    }

    /// Режим работы (Спрашивать / Правки без спроса / Только план / Полный доступ) переключают
    /// внутри сессии по shift+tab. Плашка обязана переключиться вместе с ним.
    func testPermissionModeSwitchedInsideTheSessionIsPickedUp() throws {
        try append([
            #"{"type":"permission-mode","permissionMode":"default","sessionId":"s"}"#,
        ], to: "s")

        var p = probe(resuming: "s")
        p = ClaudeJournal.follow(in: dir, probes: [p])[0]
        XCTAssertEqual(p.live.permissions, .default)

        try append([
            #"{"type":"permission-mode","permissionMode":"plan","sessionId":"s"}"#,
        ], to: "s")

        p = ClaudeJournal.follow(in: dir, probes: [p])[0]
        XCTAssertEqual(p.live.permissions, .plan, "режим сменился, а плашка осталась прежней")
    }

    /// Модель берётся из ОТВЕТА Claude, а не из флага запуска: `/model` меняет её на ходу.
    func testModelComesFromWhatClaudeActuallyAnswersWith() throws {
        try append([
            #"{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-8"}}"#,
        ], to: "s")

        var p = probe(resuming: "s")
        p = ClaudeJournal.follow(in: dir, probes: [p])[0]
        XCTAssertEqual(p.live.model, "Opus 4.8")

        try append([
            #"{"type":"assistant","message":{"role":"assistant","model":"claude-haiku-4-5-20251001"}}"#,
        ], to: "s")

        p = ClaudeJournal.follow(in: dir, probes: [p])[0]
        XCTAssertEqual(p.live.model, "Haiku 4.5", "модель сменили, а плашка показывает прежнюю")
    }

    /// `/model opus[1m]` и `/model claude-fable-5` — не повод промолчать: суффикс окна
    /// отрезается, имя собирается из id. Раньше плашка просто игнорировала такие команды
    /// и врала до следующего ответа модели.
    func testModelCommandWithWindowSuffixOrFullIDIsUnderstood() throws {
        try append([
            #"{"type":"user","message":{"role":"user","content":"<command-name>/model</command-name><command-args>opus[1m]</command-args>"}}"#,
        ], to: "s")

        var p = probe(resuming: "s")
        p = ClaudeJournal.follow(in: dir, probes: [p])[0]
        XCTAssertEqual(p.live.model, "Opus 4.8", "алиас с [1m] не распознан")

        try append([
            #"{"type":"user","message":{"role":"user","content":"<command-name>/model</command-name><command-args>claude-fable-5</command-args>"}}"#,
        ], to: "s")

        p = ClaudeJournal.follow(in: dir, probes: [p])[0]
        XCTAssertEqual(p.live.model, "Fable 5", "полный id модели не распознан")
    }

    /// Кольцо контекста делится на РЕАЛЬНОЕ окно сессии, а оно меняется на ходу.
    ///
    /// Запустили с `opus[1m]` — окно миллион. Набрали внутри `/model sonnet` — стало 200k, и
    /// те же 120k занятого превращаются из 12% в 60%. Пока окно бралось только из флага запуска,
    /// кольцо в этот момент начинало врать — и молчало о том, что контекст подходит к концу.
    func testContextWindowFollowsTheModelSwitchedInsideTheSession() throws {
        let tab = ClaudeTab(id: UUID(), title: "Claude", model: .opus, effort: .inherit,
                            permissions: .default, longContext: true, resumed: nil)
        XCTAssertEqual(tab.contextWindow, ClaudeConfig.longWindow, "старт с opus[1m] — окно миллион")

        try append([
            #"{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":120000}}}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/model</command-name><command-args>sonnet</command-args>"}}"#,
        ], to: "s")
        let live = ClaudeJournal.follow(in: dir, probes: [probe(resuming: "s")])[0].live

        var switched = tab
        switched.live = live
        XCTAssertEqual(switched.live.modelAlias, "sonnet")
        XCTAssertEqual(switched.contextWindow, ClaudeConfig.standardWindow,
                       "после /model sonnet окно всё ещё считается миллионом")
        XCTAssertEqual(switched.contextFill ?? 0, 0.6, accuracy: 0.01,
                       "120k из 200k — это 60%, а не 12%")

        // И обратно: сессия начиналась с короткого окна, внутри попросили длинное.
        var long = ClaudeTab(id: UUID(), title: "Claude", model: .sonnet, effort: .inherit,
                             permissions: .default, longContext: false, resumed: nil)
        long.live.modelAlias = "opus" + ClaudeConfig.longContextSuffix
        XCTAssertEqual(long.contextWindow, ClaudeConfig.longWindow,
                       "/model opus[1m] внутри сессии не расширил окно")
    }

    /// Записи подагентов помечены isSidechain: у них своя модель и свой контекст, и к сессии
    /// они отношения не имеют. Возьми мы usage оттуда — кольцо контекста прыгало бы на цифры
    /// субагента, а плашка — на его модель.
    func testSidechainRecordsDoNotTouchTheLiveState() throws {
        try append([
            #"{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":8800}}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"role":"assistant","model":"claude-haiku-4-5","usage":{"input_tokens":30000,"output_tokens":500}}}"#,
        ], to: "s")

        let p = ClaudeJournal.follow(in: dir, probes: [probe(resuming: "s")])[0]

        XCTAssertEqual(p.live.model, "Opus 4.8", "модель взялась из реплики подагента")
        XCTAssertEqual(p.live.contextTokens, 10_000, "контекст посчитан по подагенту")
    }

    /// Имя модели собирается из её id, а не сверяется со списком известных: список устареет
    /// с первой же новой моделью — и приложение станет уверенно показывать «Opus 4.8» там,
    /// где работает Opus 4.9.
    func testModelNameIsBuiltFromTheIDAndSurvivesUnknownModels() {
        XCTAssertEqual(ClaudeJournal.modelName(fromID: "claude-opus-4-8"), "Opus 4.8")
        XCTAssertEqual(ClaudeJournal.modelName(fromID: "claude-haiku-4-5-20251001"), "Haiku 4.5")
        XCTAssertEqual(ClaudeJournal.modelName(fromID: "claude-fable-5"), "Fable 5")
        XCTAssertEqual(ClaudeJournal.modelName(fromID: "claude-opus-5-1"), "Opus 5.1")
    }

    /// Заголовок разговора Claude придумывает сам — им и подписывается вкладка вместо
    /// безымянной «Новой сессии».
    func testTitleFromTheJournalNamesTheTab() throws {
        try append([
            #"{"type":"ai-title","aiTitle":"Починить деплой","sessionId":"s"}"#,
        ], to: "s")

        let p = ClaudeJournal.follow(in: dir, probes: [probe(resuming: "s")])[0]
        XCTAssertEqual(p.live.title, "Починить деплой")
    }

    /// Журнал читается по кусочкам: каждый опрос дочитывает только новые байты. Иначе раз
    /// в полторы секунды перечитывался бы десяток мегабайт — на ровном месте.
    func testOnlyTheNewBytesAreReadOnEachPoll() throws {
        try append([#"{"type":"ai-title","aiTitle":"Начало","sessionId":"s"}"#], to: "s")

        var p = ClaudeJournal.follow(in: dir, probes: [probe(resuming: "s")])[0]
        let afterFirst = p.offset
        XCTAssertGreaterThan(afterFirst, 0)

        // Ничего не дописали — смещение не сдвинулось, состояние прежнее.
        p = ClaudeJournal.follow(in: dir, probes: [p])[0]
        XCTAssertEqual(p.offset, afterFirst, "перечитали то, что уже прочли")
        XCTAssertEqual(p.live.title, "Начало")

        try append([#"{"type":"ai-title","aiTitle":"Продолжение","sessionId":"s"}"#], to: "s")
        p = ClaudeJournal.follow(in: dir, probes: [p])[0]
        XCTAssertGreaterThan(p.offset, afterFirst)
        XCTAssertEqual(p.live.title, "Продолжение")
    }

    /// Claude пишет журнал прямо сейчас, и последняя строка вполне может быть недописана.
    /// Разбирать половину строки нельзя — её надо дождаться.
    func testAHalfWrittenLineIsNotParsedUntilItIsFinished() throws {
        try append([#"{"type":"ai-title","aiTitle":"Целая","sessionId":"s"}"#], to: "s")

        let file = dir.appendingPathComponent("s.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"ai-title","aiTitle":"Обор"#.utf8))
        try handle.close()

        var p = ClaudeJournal.follow(in: dir, probes: [probe(resuming: "s")])[0]
        XCTAssertEqual(p.live.title, "Целая", "разобрали недописанную строку")

        // Claude дописал строку до конца — теперь она читается.
        try append([#"вана","sessionId":"s"}"#], to: "s")
        p = ClaudeJournal.follow(in: dir, probes: [p])[0]
        XCTAssertEqual(p.live.title, "Оборвана")
    }

    /// Свой id новая сессия придумывает сама и нам его не сообщает. Опознаётся её журнал по
    /// времени: он появился ПОСЛЕ запуска — и он не занят другой вкладкой.
    func testANewSessionFindsItsOwnJournalAmongTheOthers() throws {
        try append([#"{"type":"ai-title","aiTitle":"Старый разговор","sessionId":"old"}"#], to: "old")

        // Журнал старой сессии создан раньше, чем запустили новую.
        let old = dir.appendingPathComponent("old.jsonl")
        try FileManager.default.setAttributes(
            [.creationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: old.path
        )

        let started = Date()
        var fresh = SessionProbe(id: UUID(), startedAt: started, resumed: nil)

        // Claude ещё не создал журнал — и приписывать себе чужой мы не имеем права.
        fresh = ClaudeJournal.follow(in: dir, probes: [fresh])[0]
        XCTAssertNil(fresh.journal, "новая сессия присвоила себе чужой журнал")

        try append([#"{"type":"ai-title","aiTitle":"Новый разговор","sessionId":"new"}"#], to: "new")

        fresh = ClaudeJournal.follow(in: dir, probes: [fresh])[0]
        XCTAssertEqual(fresh.journal?.lastPathComponent, "new.jsonl")
        XCTAssertEqual(fresh.live.title, "Новый разговор")
    }

    /// Журнал, созданный ДО запуска сессии — пусть даже на секунду, — не наш. Прежний «запас
    /// на расхождение часов» в пару секунд позволял присвоить себе журнал сессии, запущенной
    /// параллельно в обычном терминале.
    func testJournalCreatedBeforeLaunchIsNeverClaimed() throws {
        try append([#"{"type":"ai-title","aiTitle":"Чужая","sessionId":"alien"}"#], to: "alien")
        try FileManager.default.setAttributes(
            [.creationDate: Date().addingTimeInterval(-1)],
            ofItemAtPath: dir.appendingPathComponent("alien.jsonl").path
        )

        let fresh = SessionProbe(id: UUID(), startedAt: Date(), resumed: nil)
        let p = ClaudeJournal.follow(in: dir, probes: [fresh])[0]
        XCTAssertNil(p.journal, "присвоен журнал, созданный до запуска сессии")
    }

    /// `--resume <id>` не дописывает старый `<id>.jsonl` — Claude Code заводит новую сессию
    /// с новым id и новым файлом. Пока его нет, вкладка показывает состояние из старого журнала
    /// (в нём вся история), но как только новый появился — переходит на него: иначе плашка
    /// застыла бы, а хуки busy искали бы вкладку по мёртвому id.
    func testResumedSessionMovesToTheJournalClaudeActuallyWrites() throws {
        try append([#"{"type":"permission-mode","permissionMode":"plan","sessionId":"old"}"#], to: "old")
        try FileManager.default.setAttributes(
            [.creationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: dir.appendingPathComponent("old.jsonl").path
        )

        var p = SessionProbe(id: UUID(), startedAt: Date(), resumed: "old")
        p = ClaudeJournal.follow(in: dir, probes: [p])[0]
        XCTAssertEqual(p.live.sessionID, "old", "до появления нового журнала показываем старый")
        XCTAssertEqual(p.live.permissions, .plan)

        // Claude создал журнал возобновлённой сессии: новый файл, новый id.
        try append([
            #"{"type":"permission-mode","permissionMode":"acceptEdits","sessionId":"forked"}"#,
        ], to: "forked")

        p = ClaudeJournal.follow(in: dir, probes: [p])[0]
        XCTAssertEqual(p.live.sessionID, "forked", "вкладка не перешла на настоящий журнал")
        XCTAssertEqual(p.live.permissions, .acceptEdits, "состояние не перечитано с нового журнала")
    }

    /// Две сессии рядом не должны разъезжаться по журналам: продолженная держится своего,
    /// новая берёт свой, и состояние у них разное.
    func testTwoSessionsKeepTheirOwnJournals() throws {
        try append([
            #"{"type":"permission-mode","permissionMode":"plan","sessionId":"старая"}"#,
            #"{"type":"assistant","message":{"role":"assistant","model":"claude-haiku-4-5"}}"#,
        ], to: "старая")

        let old = dir.appendingPathComponent("старая.jsonl")
        try FileManager.default.setAttributes(
            [.creationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: old.path
        )

        try append([
            #"{"type":"permission-mode","permissionMode":"bypassPermissions","sessionId":"новая"}"#,
            #"{"type":"assistant","message":{"role":"assistant","model":"claude-opus-4-8"}}"#,
        ], to: "новая")

        let resumed = SessionProbe(id: UUID(), startedAt: Date(), resumed: "старая")
        let fresh = SessionProbe(id: UUID(), startedAt: Date().addingTimeInterval(-1), resumed: nil)

        let result = ClaudeJournal.follow(in: dir, probes: [resumed, fresh])

        XCTAssertEqual(result[0].live.permissions, .plan)
        XCTAssertEqual(result[0].live.model, "Haiku 4.5")
        XCTAssertEqual(result[1].live.permissions, .bypassPermissions)
        XCTAssertEqual(result[1].live.model, "Opus 4.8")
        XCTAssertNotEqual(result[0].journal, result[1].journal, "сессии читают один журнал")
    }
}
