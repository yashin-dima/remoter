import Foundation

/// Локальная папка проекта на Mac — рабочий каталог, в котором запускается Claude.
///
/// Claude Code запускается ЗДЕСЬ, на вашей машине: ваши токены, ваша сессия, на сервер ничего
/// ставить не нужно. А с файлами проекта он работает по ssh — ровно так же, как вы это делаете
/// руками в терминале.
///
/// Всё, что для этого нужно, — чтобы он знал: где сервер, где каталог проекта и через какой канал
/// туда ходить. Это и лежит в CLAUDE.md. Плюс один короткий скрипт `remote`, чтобы не набирать
/// длинную команду ssh каждый раз.
///
/// Никаких локальных копий и синхронизаций: Claude читает и правит файлы прямо на сервере,
/// поэтому его правки видны в diff'е сразу, без всяких промежуточных шагов.
@MainActor
enum LocalWorkspace {

    /// Есть ли `claude` на этой машине. Если нет — панель скажет об этом честно,
    /// а не будет слать команду в никуда.
    ///
    /// Результат кэшируется на запуск: медленная часть проверки — логин-шелл, который
    /// прогоняет весь профиль пользователя (nvm и прочие радости), а зовётся она с главного
    /// актора при каждом открытии проекта. Один раз — терпимо, каждый раз — фризы.
    static func isClaudeInstalled() -> Bool {
        if let cached = claudeInstalledCache { return cached }
        let found = findClaude()
        claudeInstalledCache = found
        return found
    }

    private static var claudeInstalledCache: Bool?

    private static func findClaude() -> Bool {
        // Ищем там же, где его нашёл бы логин-шелл: PATH у GUI-приложения обрезанный,
        // и claude из ~/.local/bin через него не виден.
        let candidates = [
            NSHomeDirectory() + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        if candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return true
        }
        // Таймаут короткий и явный: залипший профиль шелла не должен вешать главный поток.
        let r = try? Proc.runSync("/bin/sh", ["-lc", "command -v claude"], timeout: 5)
        return r?.ok ?? false
    }

    /// ~/Remoter/<имя проекта> — рабочий каталог Claude. Сюда же удобно класть свою документацию.
    ///
    /// Корень переопределяется через `REMOTER_HOME`: тесты и отладочные запуски уводят его во
    /// временную папку, чтобы не создавать (и потом не удалять) ничего в настоящем ~/Remoter,
    /// где лежат заметки и документация по живым проектам.
    static func directory(for workspace: Workspace) -> URL {
        let safe = workspace.name.isEmpty
            ? workspace.host
            : workspace.name.replacingOccurrences(of: "/", with: "-")

        return root().appendingPathComponent(safe, isDirectory: true)
    }

    /// Файл-маркер: чей это каталог. Скрытый — в панели локальных файлов его не видно.
    static let ownerMarkerName = ".remoter-id"

    /// Каталог, закреплённый именно за ЭТИМ проектом.
    ///
    /// Имя каталога собирается из названия проекта, но названия не уникальны: два проекта
    /// «api» на разных серверах делили бы одну папку, и каждый `provision` переписывал бы
    /// `remote` и CLAUDE.md данными последнего открытого — Claude второго проекта молча ходил
    /// бы на чужой сервер. Поэтому каталог помечается маркером с id проекта:
    ///
    /// - каталога нет — создаём и помечаем;
    /// - маркер наш — каталог наш;
    /// - маркера нет — каталог из времён до маркеров, усыновляем (иначе после обновления
    ///   у всех «отвязались» бы истории сессий Claude, привязанные к пути);
    /// - маркер чужой — берём следующее имя: «имя (хост)», дальше «имя (кусок id)».
    static func claimDirectory(for workspace: Workspace) throws -> URL {
        let fm = FileManager.default
        let base = directory(for: workspace)
        let parent = base.deletingLastPathComponent()
        let name = base.lastPathComponent
        let hostSafe = workspace.host.replacingOccurrences(of: "/", with: "-")

        let candidates = [
            base,
            parent.appendingPathComponent("\(name) (\(hostSafe))", isDirectory: true),
            parent.appendingPathComponent("\(name) (\(workspace.id.uuidString.prefix(8)))",
                                          isDirectory: true),
        ]

        for dir in candidates {
            let marker = dir.appendingPathComponent(ownerMarkerName)
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try workspace.id.uuidString.write(to: marker, atomically: true, encoding: .utf8)
                return dir
            }
            let owner = (try? String(contentsOf: marker, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if owner == workspace.id.uuidString { return dir }
            if owner == nil || owner?.isEmpty == true {
                try workspace.id.uuidString.write(to: marker, atomically: true, encoding: .utf8)
                return dir
            }
            // Занято другим проектом — пробуем следующее имя.
        }

        // Все три кандидата заняты чужими маркерами — теоретический случай (совпал даже кусок
        // id), но и он не должен приводить к дележу папки: последняя соломинка — полный id.
        let last = parent.appendingPathComponent("\(name) (\(workspace.id.uuidString))",
                                                 isDirectory: true)
        try fm.createDirectory(at: last, withIntermediateDirectories: true)
        try workspace.id.uuidString.write(
            to: last.appendingPathComponent(ownerMarkerName), atomically: true, encoding: .utf8)
        return last
    }

    /// Где живут рабочие каталоги проектов.
    ///
    /// Приложение раньше звалось SSHDiff, и корень назывался так же. Переименовать папку задним
    /// числом нельзя — и дело не в лени: Claude Code хранит журналы разговоров в каталоге, имя
    /// которого собрано ИЗ ПУТИ рабочей папки. Переехали бы — и вся история сессий по живым
    /// проектам отвязалась бы разом. Поэтому старый корень, если он есть, остаётся рабочим,
    /// а новое имя достаётся тем, у кого прошлого нет.
    static func root() -> URL {
        if let custom = ProcessInfo.processInfo.environment["REMOTER_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }

        // Тест без REMOTER_HOME уходит в песочницу, а не в папку пользователя: см. TestIsolation.
        // Без этого прогон заводил проекты прямо в живом ~/Remoter — с именами вроде «только чтение».
        return TestIsolation.path("home") {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let new = home.appendingPathComponent("Remoter", isDirectory: true)
            let old = home.appendingPathComponent("SSHDiff", isDirectory: true)

            let fm = FileManager.default
            if !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path) {
                return old
            }
            return new
        }
    }

    /// Создаёт папку и обновляет CLAUDE.md со скриптом. Вызывается при каждом открытии проекта:
    /// сокет мультиплексора и путь могли поменяться.
    ///
    /// Ваши файлы в этой папке не трогаются. Перезаписывается только `remote`, а в CLAUDE.md —
    /// только наш блок между маркерами: всё, что вы дописали вне блока, остаётся.
    @discardableResult
    static func provision(
        workspace: Workspace,
        conn: Connection,
        remoteRoot: String,
        notifyURL: String
    ) throws -> URL {
        if workspace.isLocal { return try provisionLocal(workspace: workspace, notifyURL: notifyURL) }
        guard let conn = conn as? SSHConnection else {
            throw ProvisionError.wrongTransport
        }
        let dir = try claimDirectory(for: workspace)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // docs/ заводим сразу: пусть будет очевидное место под документацию, а не пустая папка,
        // в которой непонятно, что делать.
        let docs = dir.appendingPathComponent("docs", isDirectory: true)
        if !fm.fileExists(atPath: docs.path) {
            try fm.createDirectory(at: docs, withIntermediateDirectories: true)
            try starterDoc(workspace: workspace, remoteRoot: remoteRoot)
                .write(to: docs.appendingPathComponent("О проекте.md"),
                       atomically: true, encoding: .utf8)
        }

        let ssh = (["-S", conn.controlSocket, "-o", "ControlMaster=no"] + conn.connectArgs)
            .map(shq).joined(separator: " ")

        let script = dir.appendingPathComponent("remote")
        try remoteScript(ssh: ssh, host: workspace.host, root: remoteRoot)
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        // Обновляем только свой блок между маркерами: CLAUDE.md — ровно то место, куда
        // пользователь дописывает свои инструкции, и терять их при каждом открытии нельзя.
        let claudeURL = dir.appendingPathComponent("CLAUDE.md")
        let existing = try? String(contentsOf: claudeURL, encoding: .utf8)
        try mergedClaudeMD(existing: existing,
                           generated: claudeMD(workspace: workspace, remoteRoot: remoteRoot))
            .write(to: claudeURL, atomically: true, encoding: .utf8)

        try installNotificationHooks(
            settingsDir: dir,
            project: workspace.name,
            id: workspace.id,
            notifyURL: notifyURL
        )

        return dir
    }

    enum ProvisionError: LocalizedError {
        case missingFolder(String)
        case wrongTransport

        var errorDescription: String? {
            switch self {
            case .missingFolder(let path):
                return "Папки \(path) больше нет — проект переехал или его удалили."
            case .wrongTransport:
                return "Внутренняя ошибка: проекту на сервере нужен ssh-канал."
            }
        }
    }

    /// Проект на этом же Mac. Рабочая папка Claude — САМ проект, и это меняет главное правило:
    /// папка **чужая**.
    ///
    /// Поэтому здесь нет ничего из того, что делается для серверного проекта: ни своего CLAUDE.md
    /// (у проекта уже может быть свой — как у самого Remoter), ни скрипта `remote` (ходить некуда,
    /// файлы вот они), ни `docs/`. Класть такое в чужой репозиторий — значит менять его содержимое
    /// без спроса и мусорить в чьём-то `git status`.
    ///
    /// Единственное, что мы всё-таки пишем, — хуки уведомлений в `.claude/settings.local.json`:
    /// без них приложение не узнает, что Claude закончил или ждёт ответа. Это машинный файл самого
    /// Claude Code (он и так его заводит), чужие настройки в нём не трогаются, а САМ скрипт хука
    /// живёт вне проекта — в Application Support, — чтобы в репозитории не появлялось наших файлов.
    private static func provisionLocal(workspace: Workspace, notifyURL: String) throws -> URL {
        let dir = URL(fileURLWithPath: workspace.path, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw ProvisionError.missingFolder(dir.path)
        }

        try installNotificationHooks(
            settingsDir: dir,
            scriptDir: privateDirectory(for: workspace),
            project: workspace.name,
            id: workspace.id,
            notifyURL: notifyURL
        )
        return dir
    }

    /// Наш собственный каталог для этого проекта — вне его папки. Здесь лежит то, что нужно
    /// приложению, но не имеет отношения к коду пользователя: скрипт хука, вложения из буфера.
    static func privateDirectory(for workspace: Workspace) -> URL {
        let base = TestIsolation.path("support") {
            FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Remoter", isDirectory: true)
        }
        .appendingPathComponent("projects", isDirectory: true)
        .appendingPathComponent(workspace.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Куда складывать скриншоты из буфера. У серверного проекта — в его локальную папку
    /// (она наша), у локального — в наш каталог рядом: сыпать `.attachments` в чужой репозиторий
    /// и пачкать человеку `git status` мы не будем.
    static func attachmentsDirectory(for workspace: Workspace, localPath: String) -> URL {
        workspace.isLocal
            ? privateDirectory(for: workspace).appendingPathComponent("attachments", isDirectory: true)
            : URL(fileURLWithPath: localPath).appendingPathComponent(".attachments", isDirectory: true)
    }

    // MARK: - Уведомления

    /// Клод сообщает о себе сам — через свои же хуки.
    ///
    /// `Stop` срабатывает, когда он закончил отвечать; `Notification` с matcher'ом
    /// `permission_prompt` — когда просит разрешение. Оба зовут наш скрипт, а тот стучится
    /// в локальный сервер приложения, и оно показывает уведомление macOS.
    ///
    /// Пишем в `settings.local.json`, а не в `settings.json`: первый по смыслу и есть файл для
    /// машинных настроек, второй остаётся целиком вашим. И даже в нём чужие хуки не трогаются —
    /// свои мы находим по имени скрипта и заменяем, остальное оставляем как есть.
    /// `settingsDir` — папка проекта, в чей `.claude/settings.local.json` прописываются хуки.
    /// `scriptDir` — где лежит сам скрипт хука. У серверного проекта это одно и то же место
    /// (папка наша), у локального скрипт уводится наружу: в чужом репозитории наших файлов
    /// быть не должно.
    static func installNotificationHooks(
        settingsDir: URL,
        scriptDir: URL? = nil,
        project: String,
        id: UUID,
        notifyURL: String
    ) throws {
        let claude = settingsDir.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)

        let scriptHome = scriptDir ?? claude
        try FileManager.default.createDirectory(at: scriptHome, withIntermediateDirectories: true)
        let script = scriptHome.appendingPathComponent(hookScriptName)
        try hookScript(project: project, id: id, notifyURL: notifyURL)
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        // Скрипт под старым именем (приложение звалось SSHDiff) убираем. Оставь его — и в проектах,
        // заведённых до переименования, остались бы ДВА хука на одно событие: каждое «Claude
        // закончил» приходило бы дважды.
        try? FileManager.default.removeItem(at: claude.appendingPathComponent(legacyHookScriptName))

        let file = claude.appendingPathComponent("settings.local.json")

        // Файл есть, но не разбирается — НЕ перезаписываем: там могут лежать чужие настройки
        // (permissions и прочее), и «починить» их пустым словарём значило бы их уничтожить.
        // Пусть пользователь сначала поправит JSON — ошибка скажет, где и что.
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: file), !data.isEmpty {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw NSError(domain: "Remoter", code: 1, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Не удалось разобрать \(file.path) — файл не тронут. Поправьте JSON, и хуки уведомлений установятся при следующем открытии проекта.",
                ])
            }
            root = parsed
        }

        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        hooks["Stop"] = entries(hooks["Stop"], matcher: nil, command: shq(script.path) + " Stop")
        hooks["Notification"] = entries(hooks["Notification"], matcher: "permission_prompt",
                                        command: shq(script.path) + " Notification")
        // Claude взялся за работу. Уведомления по этому событию нет — оно нужно, чтобы приложение
        // знало, что сессия занята: только тогда имеет смысл показывать кнопку «Стоп».
        hooks["UserPromptSubmit"] = entries(hooks["UserPromptSubmit"], matcher: nil,
                                            command: shq(script.path) + " Prompt")
        root["hooks"] = hooks

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: file, options: .atomic)
    }

    private static let hookScriptName = "remoter-notify.sh"
    /// Имя из времён, когда приложение звалось SSHDiff. Записи с ним — тоже наши, и их надо
    /// вычищать, а не считать чужими и бережно сохранять рядом со своими.
    private static let legacyHookScriptName = "sshdiff-notify.sh"

    /// Свои записи опознаём по имени скрипта и переписываем; чужие не трогаем.
    private static func entries(_ existing: Any?, matcher: String?, command: String) -> [[String: Any]] {
        var list = (existing as? [[String: Any]])?.filter { entry in
            let hooks = entry["hooks"] as? [[String: Any]] ?? []
            return !hooks.contains { hook in
                let command = (hook["command"] as? String) ?? ""
                return command.contains(hookScriptName) || command.contains(legacyHookScriptName)
            }
        } ?? []

        var entry: [String: Any] = [
            "hooks": [["type": "command", "command": command]],
        ]
        if let matcher { entry["matcher"] = matcher }

        list.append(entry)
        return list
    }

    private static func hookScript(project: String, id: UUID, notifyURL: String) -> String {
        """
        #!/bin/sh
        # Сообщает приложению, что Claude закончил работу или ждёт ответа.
        # Ставится автоматически, зовётся хуками Claude Code (см. .claude/settings.local.json).
        #
        # Событие приходит на stdin как JSON и уходит в приложение как есть, телом POST.
        #
        # Стучимся прямо в локальный сервер приложения, а не через `open remoter://…`, как раньше.
        # Причина: `open` идёт через Launch Services, а те на каждую доставку «переоткрывают»
        # приложение — и оно послушно распахивало окно со списком проектов поверх работы.
        # Здесь этого нет: приложение даже не шевелится, просто показывает уведомление.
        #
        # Приложение закрыто — curl молча не достучится, и это правильно: показывать уведомление
        # некому.
        event="$1"
        project=$(printf '%s' \(shq(project)) | base64 | tr '+/' '-_' | tr -d '=\\n')
        # URL — в одинарных кавычках через shq: окажись в нём когда-нибудь `$` или кавычка,
        # прямая подстановка в двойные кавычки сломала бы скрипт молча.
        url=\(shq(notifyURL))

        curl -s -m 5 -X POST --data-binary @- \\
          -H 'Content-Type: application/json' \\
          "$url?event=$event&project=$project&id=\(id.uuidString)" >/dev/null 2>&1 || true
        """
    }

    /// Переменные окружения для локального терминала: с ними и Claude, и вы можете дотянуться
    /// до сервера, не подглядывая в настройки.
    static func environment(workspace: Workspace, conn: Connection, remoteRoot: String) -> [String] {
        // У локального проекта сервера нет: ни хоста, ни сокета — подставлять пустые переменные
        // значило бы врать Claude, что до чего-то можно достучаться.
        guard let ssh = conn as? SSHConnection, !workspace.isLocal else {
            return ["REMOTER_PATH=\(remoteRoot)"]
        }
        return [
            "REMOTER_HOST=\(workspace.host)",
            "REMOTER_PATH=\(remoteRoot)",
            "REMOTER_SOCKET=\(ssh.controlSocket)",
        ]
    }

    /// Первая заметка в docs/ — чтобы папка не встречала пустотой и было видно, куда писать.
    private static func starterDoc(workspace: Workspace, remoteRoot: String) -> String {
        """
        # \(workspace.name)

        Проект живёт на сервере `\(workspace.host)`, каталог `\(remoteRoot)`.

        Эта папка — локальная, на вашем Mac. Сервер про неё ничего не знает.
        Здесь удобно держать документацию, заметки, договорённости — всё, что нужно вам
        и Claude, но не нужно серверу.

        Claude читает `CLAUDE.md` в корне этой папки при каждом запуске: там написано,
        где проект и как с ним работать. Что дописать сюда, в docs/, — решаете вы.
        """
    }

    // MARK: - Скрипт доступа

    /// Короткая обёртка над ssh. Нужна ровно для одного: не набирать длинную строку с сокетом
    /// и опциями при каждой команде. Под ней — обычный ssh, ничего больше.
    private static func remoteScript(ssh: String, host: String, root: String) -> String {
        """
        #!/bin/sh
        # Выполняет команду на сервере, сразу в каталоге проекта.
        #
        #   ./remote git status
        #   ./remote cat src/main.py
        #   ./remote grep -rn "TODO" src/
        #
        # Под капотом обычный ssh, просто через уже открытый канал Remoter — поэтому без
        # рукопожатия, без пароля и за десятки миллисекунд.
        #
        # Без аргументов — обычная интерактивная сессия на сервере.
        set -e

        ROOT=\(shq(root))

        # Экранируем каждый аргумент по отдельности: строку целиком разбирает УДАЛЁННЫЙ шелл,
        # и простое склеивание через $* потеряло бы кавычки — `./remote grep -rn "два слова"`
        # искал бы два отдельных слова.
        esc() {
          printf '%s' "$1" | sed "s/'/'\\\\\\\\''/g"
        }

        # Опции ssh подставлены прямо сюда, а не через переменную: в переменной кавычки стали бы
        # частью самих аргументов, и ssh увидел бы хост с кавычками вместо хоста.
        if [ $# -eq 0 ]; then
          exec ssh -t \(ssh) \(shq(host)) "cd '$(esc "$ROOT")' && exec \\"\\$SHELL\\" -l"
        fi

        cmd=""
        for a in "$@"; do
          cmd="$cmd '$(esc "$a")'"
        done

        exec ssh \(ssh) -T \(shq(host)) "cd '$(esc "$ROOT")' &&$cmd"
        """
    }

    // MARK: - Инструкция для Claude

    static let claudeMDBegin = "<!-- remoter:begin — блок обновляется приложением, свои заметки пишите вне его -->"
    static let claudeMDEnd = "<!-- remoter:end -->"

    /// Вписывает наш блок в существующий CLAUDE.md, не трогая пользовательский текст.
    ///
    /// - Файла нет — просто наш блок.
    /// - Маркеры есть — заменяется только содержимое между ними.
    /// - Файл без маркеров — из времён, когда CLAUDE.md целиком генерировали мы; заменяем
    ///   его блоком (раньше он и так перезаписывался при каждом открытии), и дальше правки
    ///   вне маркеров уже переживают provision.
    static func mergedClaudeMD(existing: String?, generated: String) -> String {
        let block = claudeMDBegin + "\n\n" + generated + "\n\n" + claudeMDEnd
        guard let existing, !existing.isEmpty else { return block + "\n" }

        if let b = existing.range(of: claudeMDBegin),
           let e = existing.range(of: claudeMDEnd),
           b.lowerBound <= e.lowerBound {
            return existing.replacingCharacters(in: b.lowerBound..<e.upperBound, with: block)
        }
        return block + "\n"
    }

    private static func claudeMD(workspace: Workspace, remoteRoot: String) -> String {
        """
        # Проект «\(workspace.name)»

        Ты запущен на Mac, а файлы проекта лежат на сервере:

        - сервер: `\(workspace.host)`
        - каталог проекта: `\(remoteRoot)`

        Работай с ними по ssh. Рядом лежит короткая обёртка — она выполняет команду сразу
        в каталоге проекта, через уже открытый канал (без пароля, за десятки миллисекунд):

        ```sh
        ./remote git status
        ./remote ls -la src/
        ./remote cat src/main.py
        ./remote grep -rn "TODO" src/
        ./remote python -m pytest
        ```

        Это обычный ssh, ничего больше. Если удобнее — можешь звать `ssh` напрямую, хост и путь
        лежат в переменных `$REMOTER_HOST` и `$REMOTER_PATH`.

        ## Как править файлы

        Твои Read/Edit/Grep работают только с локальными файлами, а проект — на сервере,
        поэтому правь его через `./remote`:

        ```sh
        # посмотреть
        ./remote cat src/main.py

        # переписать файл целиком (работает везде)
        ./remote 'cat > src/main.py' <<'EOF'
        новое содержимое
        EOF

        # точечная замена
        ./remote perl -i -pe 's/старое/новое/' src/main.py
        ```

        Для точечной замены бери `perl -i -pe`, а не `sed -i`: у `sed -i` разный синтаксис в GNU
        и BSD, и на части серверов он молча сделает не то (или создаст файл с суффиксом).

        ## Важно

        - **Правки сразу попадают на сервер.** Никаких локальных копий и синхронизаций нет —
          что записал, то и лежит на сервере. Пользователь видит это в diff'е сразу.
        - Прежде чем переписывать файл целиком, прочитай его — иначе затрёшь чужую работу.
        - Локальные файлы в этой папке (`docs/` и прочее) — документация пользователя.
          К проекту на сервере они отношения не имеют.

        ## Проверить, что связь есть

        ```sh
        ./remote git status --short
        ```
        """
    }
}
