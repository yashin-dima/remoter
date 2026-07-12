import XCTest
@testable import Remoter

/// Уведомления: Claude закончил работу или ждёт ответа.
///
/// Цепочка длинная — хук Claude Code → скрипт → POST в локальный сервер приложения, — и каждое
/// звено здесь проверяется отдельно. Само всплывающее окно тест увидеть не может, но всё,
/// что до него, — может.
@MainActor
final class NotificationsTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remoter-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Адрес локального сервера приложения — туда скрипт-хук и стучится.
    private let endpoint = "http://127.0.0.1:12345/токен/notify"
    private let workspaceID = UUID()

    private var settings: URL { dir.appendingPathComponent(".claude/settings.local.json") }
    private var script: URL { dir.appendingPathComponent(".claude/remoter-notify.sh") }

    private func hooks() throws -> [String: Any] {
        let data = try Data(contentsOf: settings)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["hooks"] as? [String: Any])
    }

    private func commands(_ event: String) throws -> [String] {
        let list = try XCTUnwrap(try hooks()[event] as? [[String: Any]])
        return list.flatMap { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    /// Оба события на месте: закончил работу и просит разрешение. Скрипт — исполняемый,
    /// иначе Claude просто ничего не вызовет.
    func testInstallsBothHooksAndAnExecutableScript() throws {
        try LocalWorkspace.installNotificationHooks(
            settingsDir: dir, project: "мой проект", id: workspaceID, notifyURL: endpoint
        )

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script.path),
                      "скрипт-хук не исполняемый — Claude его не вызовет")

        XCTAssertEqual(try commands("Stop").count, 1)
        XCTAssertTrue(try commands("Stop")[0].hasSuffix(" Stop"))
        XCTAssertTrue(try commands("Notification")[0].hasSuffix(" Notification"))

        // Разрешение спрашивают не всегда, поэтому у Notification есть matcher.
        let notif = try XCTUnwrap(try hooks()["Notification"] as? [[String: Any]])
        XCTAssertEqual(notif.first?["matcher"] as? String, "permission_prompt")
    }

    /// Кнопка «Стоп» должна появляться, только когда Claude действительно работает. Узнать это
    /// можно от него же: он зовёт хук, когда берётся за работу (UserPromptSubmit) и когда
    /// заканчивает (Stop). Уведомления по первому событию нет — оно нужно только для состояния.
    func testWorkStartHookIsInstalledSoTheStopButtonKnowsWhenToAppear() throws {
        try LocalWorkspace.installNotificationHooks(
            settingsDir: dir, project: "проект", id: workspaceID, notifyURL: endpoint
        )

        let prompt = try commands("UserPromptSubmit")
        XCTAssertEqual(prompt.count, 1, "Claude не сообщит, что взялся за работу")
        XCTAssertTrue(prompt[0].hasSuffix(" Prompt"))
    }

    /// Событие «взялся за работу» — это состояние, а не уведомление: показывать баннер на каждый
    /// свой же вопрос Claude было бы издевательством.
    func testWorkStartDoesNotProduceANotification() {
        let payload = Data(#"{"session_id":"s1"}"#.utf8)
        XCTAssertNil(
            Notifications.parse(event: "Prompt", project64: "", id: workspaceID.uuidString,
                                payload: payload),
            "начало работы Claude показалось уведомлением"
        )
    }

    /// Проект открывают снова и снова, и каждый раз хуки ставятся заново. Плодить их при этом
    /// нельзя — иначе на пятый запуск придёт пять одинаковых уведомлений.
    func testInstallingTwiceDoesNotDuplicateHooks() throws {
        for _ in 1...3 {
            try LocalWorkspace.installNotificationHooks(
                settingsDir: dir, project: "проект", id: workspaceID, notifyURL: endpoint
            )
        }

        XCTAssertEqual(try commands("Stop").count, 1, "хуки размножились")
        XCTAssertEqual(try commands("Notification").count, 1, "хуки размножились")
    }

    /// Приложение звалось SSHDiff, и в проектах, заведённых до переименования, лежит хук с тем
    /// именем. Он наш — и его надо заменить, а не бережно сохранить рядом как чужой: иначе на
    /// каждое «Claude закончил» приходило бы ДВА уведомления.
    func testHookFromThePreviousNameIsReplacedNotKeptAlongside() throws {
        let claude = dir.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)

        let old = claude.appendingPathComponent("sshdiff-notify.sh")
        try "#!/bin/sh\n".write(to: old, atomically: true, encoding: .utf8)

        let existing: [String: Any] = [
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "'\(old.path)' Stop"]]]],
                "Notification": [[
                    "matcher": "permission_prompt",
                    "hooks": [["type": "command", "command": "'\(old.path)' Notification"]],
                ]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: settings)

        try LocalWorkspace.installNotificationHooks(
            settingsDir: dir, project: "проект", id: workspaceID, notifyURL: endpoint
        )

        XCTAssertEqual(try commands("Stop").count, 1, "уведомление придёт дважды")
        XCTAssertEqual(try commands("Notification").count, 1, "уведомление придёт дважды")
        XCTAssertTrue(try commands("Stop")[0].contains("remoter-notify.sh"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path),
                       "скрипт под старым именем остался лежать")
    }

    /// В том же файле могут лежать чужие настройки и чужие хуки. Мы ставим свой хук рядом,
    /// а не вместо: затереть чужую конфигурацию ради своего уведомления — недопустимо.
    func testKeepsForeignSettingsAndForeignHooks() throws {
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".claude"), withIntermediateDirectories: true
        )
        let existing: [String: Any] = [
            "permissions": ["allow": ["Bash(ls:*)"]],
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "/usr/bin/say готово"]]]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: settings)

        try LocalWorkspace.installNotificationHooks(
            settingsDir: dir, project: "проект", id: workspaceID, notifyURL: endpoint
        )

        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
        )
        XCTAssertNotNil(root["permissions"], "чужие настройки затёрты")

        let stop = try commands("Stop")
        XCTAssertEqual(stop.count, 2, "чужой хук пропал")
        XCTAssertTrue(stop.contains("/usr/bin/say готово"))
        XCTAssertTrue(stop.contains { $0.contains("remoter-notify.sh") })
    }

    /// Прогон настоящего скрипта-хука с настоящим JSON от Claude.
    ///
    /// В имени проекта и в тексте вопроса бывает что угодно: кавычки, амперсанды, кириллица,
    /// переводы строк. Имя проекта поэтому едет в base64, а сам JSON — телом POST, как есть:
    /// так его нечем испортить по дороге.
    func testScriptDeliversTheJournalIntactWithAwkwardNames() throws {
        let project = "проект «мой» & «твой»"
        try LocalWorkspace.installNotificationHooks(
            settingsDir: dir, project: project, id: workspaceID, notifyURL: endpoint
        )

        let payload = #"{"last_assistant_message":"Готово: rm -rf \"старое\"\nи ещё строка"}"#

        // Подменяем curl заглушкой. Писать она должна в файлы: настоящий скрипт глушит вывод
        // curl'а в /dev/null — уведомление не повод сорить в терминал Claude.
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let sent = dir.appendingPathComponent("sent")
        let fakeCurl = bin.appendingPathComponent("curl")
        try """
        #!/bin/sh
        for a in "$@"; do case "$a" in http*) printf '%s' "$a" > \(shq(sent.path)).url ;; esac; done
        cat > \(shq(sent.path)).body
        """.write(to: fakeCurl, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCurl.path)

        let r = try Proc.runSync("/bin/sh", [
            "-c", "printf '%s' \(shq(payload)) | PATH=\(shq(bin.path)):$PATH \(shq(script.path)) Stop",
        ])
        XCTAssertTrue(r.ok, "скрипт-хук завершился с ошибкой")

        let url = try XCTUnwrap(URLComponents(
            string: try String(contentsOf: URL(fileURLWithPath: sent.path + ".url"), encoding: .utf8)
        ))
        let body = try String(contentsOf: URL(fileURLWithPath: sent.path + ".body"), encoding: .utf8)

        XCTAssertEqual(url.path, "/токен/notify", "скрипт стучится не туда")
        XCTAssertEqual(body, payload, "JSON от Claude доехал испорченным")

        let items = url.queryItems ?? []
        let event = try XCTUnwrap(items.first { $0.name == "event" }?.value)
        let project64 = try XCTUnwrap(items.first { $0.name == "project" }?.value)

        let id = try XCTUnwrap(items.first { $0.name == "id" }?.value)

        let note = try XCTUnwrap(
            Notifications.parse(event: event, project64: project64, id: id,
                                payload: Data(body.utf8)),
            "приложение не разобрало то, что прислал его же скрипт"
        )
        XCTAssertEqual(note.title, project, "имя проекта не доехало целым")
        XCTAssertEqual(note.workspace, workspaceID,
                       "уведомление не знает, из какого оно проекта — по клику вести некуда")
        XCTAssertEqual(note.body, "Готово: rm -rf \"старое\" и ещё строка")
    }

    /// Что видно в уведомлении: проект, НАЗВАНИЕ СЕССИИ и по делу — что именно произошло.
    ///
    /// Название сессии здесь не украшение: «Claude закончил работу» без указания, в каком
    /// разговоре, бесполезно, когда открыто несколько проектов и в каждом свой Claude.
    func testNotificationNamesTheProjectTheSessionAndWhatHappened() throws {
        // Настоящий журнал Claude — из него берётся название разговора.
        let journal = dir.appendingPathComponent("сессия.jsonl")
        try [
            #"{"type":"user","cwd":"/x","sessionId":"s1"}"#,
            #"{"type":"ai-title","aiTitle":"Починить деплой","sessionId":"s1"}"#,
        ].joined(separator: "\n").write(to: journal, atomically: true, encoding: .utf8)

        func note(_ event: String, _ fields: [String: String]) -> Notifications.Note? {
            var payload = fields
            payload["transcript_path"] = journal.path
            let json = try! JSONSerialization.data(withJSONObject: payload)
            return Notifications.parse(event: event, project64: b64("Acme"),
                                       id: workspaceID.uuidString, payload: json)
        }

        // Закончил: показываем ПОСЛЕДНЮЮ РЕПЛИКУ — она полезнее, чем сухое «закончил».
        let done = try XCTUnwrap(note("Stop", [
            "last_assistant_message": "Готово, тесты зелёные.\nОсталось закоммитить.",
        ]))
        XCTAssertEqual(done.title, "Acme")
        XCTAssertEqual(done.subtitle, "Починить деплой", "в уведомлении нет названия сессии")
        XCTAssertEqual(done.body, "Готово, тесты зелёные. Осталось закоммитить.",
                       "многострочная реплика должна схлопнуться в одну строку")

        // Реплики может не быть — молчать нельзя.
        XCTAssertEqual(note("Stop", [:])?.body, "Claude закончил работу")

        // Спрашивает — словами самого Claude.
        let asks = try XCTUnwrap(note("Notification", [
            "notification_message": "Разрешить запись в файл?",
        ]))
        XCTAssertEqual(asks.body, "Разрешить запись в файл?")
        XCTAssertEqual(asks.subtitle, "Починить деплой")
        XCTAssertEqual(note("Notification", [:])?.body, "Claude ждёт вашего ответа")

        // Чужое событие — не наше дело.
        XCTAssertNil(note("SomethingElse", [:]))
    }

    private func b64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }

    /// Настоящий сервер, настоящий curl: хук стучится — сервер отвечает.
    ///
    /// Это последнее звено цепочки, и оно же самое хрупкое: адрес и токен приложение выдаёт само,
    /// а тело POST может не поместиться в один пакет — последняя реплика Claude бывает длинной.
    func testAppServerAcceptsWhatTheHookSends() async throws {
        let url = await MonacoServer.shared.notifyURL()

        // Реплика на пару килобайт — ровно тот случай, когда тело приезжает не за один раз.
        let long = String(repeating: "всё готово, тесты зелёные. ", count: 200)
        let payload = try JSONSerialization.data(withJSONObject: ["last_assistant_message": long])

        let file = dir.appendingPathComponent("payload.json")
        try payload.write(to: file)

        let r = try Proc.runSync("/usr/bin/curl", [
            "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "5",
            "-X", "POST", "--data-binary", "@" + file.path,
            "-H", "Content-Type: application/json",
            url + "?event=Stop&project=" + b64("проект") + "&id=" + workspaceID.uuidString,
        ])
        XCTAssertEqual(r.line, "204", "сервер не принял то, что шлёт хук")

        // А запрос по чужому адресу (без верного токена) он по-прежнему не обслуживает.
        let bad = try Proc.runSync("/usr/bin/curl", [
            "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "5",
            "-X", "POST", "--data-binary", "{}",
            url.replacingOccurrences(of: "/notify", with: "-чужой/notify"),
        ])
        XCTAssertNotEqual(bad.line, "204", "сервер принял запрос по чужому адресу")
    }
}
