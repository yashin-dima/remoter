import AppKit

// Сессии Claude и терминалы на сервере: запуск и закрытие вкладок, слежение за журналами
// (см. ClaudeJournal), управление работающей сессией, хуки busy, список прошлых разговоров.

extension WorkspaceModel {

    // MARK: - Запуск

    /// Открыли проект — продолжаем последний разговор, а не начинаем с чистого листа.
    ///
    /// Работа над проектом идёт неделями и не заканчивается вместе с окном: возвращаясь, вы
    /// возвращаетесь к тому же, на чём остановились. Разговоров ещё нет — просто начинаем новый.
    func autostartClaude() {
        guard claudeInstalled, !localPath.isEmpty, claudeTabs.isEmpty else { return }
        // Список отсортирован, свежие сверху. Кому-то удобнее всегда начинать с чистого листа —
        // это настройка, а не наше решение за него.
        openSession(resuming: AppSettings.shared.resumeLastSession ? sessions.first : nil)
    }

    /// Что запустится, если открыть новую сессию прямо сейчас. Показывается в окне запуска —
    /// чтобы было видно, что именно уйдёт в терминал, без всякой магии.
    var claudeCommand: String {
        command(ClaudeTab(
            id: UUID(),
            title: "",
            model: claudeModel,
            effort: claudeEffort,
            permissions: claudePermissions,
            longContext: claudeLongContext,
            resumed: nil
        ))
    }

    /// Открывает НОВУЮ сессию Claude — рядом с уже открытыми, не трогая их.
    ///
    /// Это не тонкость, а суть. Раньше «новая сессия» просто печатала команду запуска в терминал,
    /// где Claude уже работал, — и он читал её как обычное сообщение и вежливо отвечал, что
    /// запускать себя изнутри себя смысла нет. Теперь у каждой сессии свой терминал и свой
    /// процесс: над проектом идёт несколько задач сразу, и открывать одну, обрывая другую,
    /// бессмысленно.
    ///
    /// Claude запускается ЛОКАЛЬНО — в папке на Mac, где лежат скрипты доступа к серверу.
    /// На сервере его обычно и нет, а если и есть — это чужие токены и общая сессия.
    @discardableResult
    func openSession(resuming session: ClaudeSession? = nil) -> ClaudeTab? {
        guard !localPath.isEmpty else { return nil }

        let tab = ClaudeTab(
            id: UUID(),
            title: session?.title ?? "Новая сессия",
            model: claudeModel,
            effort: claudeEffort,
            permissions: claudePermissions,
            longContext: claudeLongContext,
            resumed: session?.id
        )
        claudeTabs.append(tab)
        pane = .claude(tab.id)

        // Следим за журналом этой сессии с момента запуска: по времени и опознаётся её журнал
        // среди чужих — свой id новая сессия придумывает сама и нам его не сообщает.
        probes[tab.id] = SessionProbe(id: tab.id, startedAt: Date(), resumed: tab.resumed)

        // cd перед запуском — страховка. Claude Code читает CLAUDE.md из ТЕКУЩЕГО каталога:
        // запустись он не там, он не узнает ни про сервер, ни про проект и будет уверен,
        // что работает у вас в домашней папке. Профиль шелла вполне может увести из каталога,
        // поэтому не полагаемся на то, что терминал стартовал где надо.
        let cmd = command(tab)
        terminal.run("cd \(shq(localPath)) && \(cmd)", on: tab.terminal)

        return tab
    }

    /// Команда запуска для конкретной сессии. Параметры берутся из неё, а не из текущих настроек:
    /// сессия запущена с тем, с чем запущена, и задним числом это не меняется.
    func command(_ tab: ClaudeTab) -> String {
        var parts = ["claude"]

        // Алиас экранируется, и это не перестраховка: `opus[1m]` — валидный алиас модели, но для
        // шелла квадратные скобки это шаблон имени файла. Незакавыченный, он не доезжал до Claude
        // вовсе — zsh отвечал «no matches found: opus[1m]», и сессия просто не запускалась.
        if let alias = tab.model.alias(longContext: tab.longContext) {
            parts += ["--model", shq(alias)]
        }
        // Флага нет — Claude возьмёт своё. Навязывать ему наши значения поверх его же настроек
        // мы не имеем права: это его конфигурация, а не наша.
        if let effort = tab.effort.flag {
            parts += ["--effort", effort]
        }
        if tab.permissions != .default {
            parts += ["--permission-mode", tab.permissions.rawValue]
        }
        if let resumed = tab.resumed {
            // Экранируем, как и alias: строка уходит в шелл (см. openSession). id сессии — это
            // имя .jsonl-файла Claude, обычно UUID, но дисциплину shq нарушать незачем.
            parts += ["--resume", shq(resumed)]
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Живое состояние сессий

    /// Дочитывает журналы открытых сессий и подтягивает в плашку то, что там происходит.
    ///
    /// Флаги запуска — не то же самое, что состояние сессии: модель меняют `/model`, уровень
    /// reasoning — `/effort`, режим разрешений — shift+tab. Плашка, показывающая флаги, врёт
    /// ровно с первой такой команды, а узнать правду можно только из журнала.
    ///
    /// Чтение — не на главном потоке, и только НОВЫЕ байты журнала: у долгого разговора он
    /// весит десяток мегабайт.
    func followSessions() async {
        guard !claudeTabs.isEmpty, !localPath.isEmpty else { return }

        let path = localPath
        let cached = sessionsDir
        let current = claudeTabs.compactMap { probes[$0.id] }
        guard !current.isEmpty else { return }

        let (dir, updated) = await Task.detached { () -> (URL?, [SessionProbe]) in
            guard let dir = cached ?? ClaudeSessions.directory(for: path) else {
                return (nil, current)
            }
            return (dir, ClaudeJournal.follow(in: dir, probes: current))
        }.value
        if sessionsDir == nil { sessionsDir = dir }

        for probe in updated {
            // Вкладку могли закрыть, пока журналы читались, — не воскрешаем её probe.
            guard let i = claudeTabs.firstIndex(where: { $0.id == probe.id }) else { continue }
            probes[probe.id] = probe
            claudeTabs[i].live = probe.live

            // Узнали id сессии — подтягиваем имя, если человек задавал его этому разговору раньше
            // (в прошлый раз или из списка сессий).
            if claudeTabs[i].customTitle == nil, let sid = probe.live.sessionID,
               let saved = sessionTitles[sid] {
                claudeTabs[i].customTitle = saved
            }

            // Заголовок Claude придумывает сам — им и подписываем вкладку, вместо «Новой сессии».
            // Но если человек задал имя руками, оно приоритетнее: своё название не затираем.
            if claudeTabs[i].customTitle == nil,
               let title = probe.live.title, !title.isEmpty, claudeTabs[i].title != title {
                claudeTabs[i].title = title
            }

            // Хук busy мог прийти раньше, чем журнал сообщил id сессии, — досылаем его сейчас.
            if let sid = probe.live.sessionID, let busy = pendingBusy.removeValue(forKey: sid) {
                claudeTabs[i].isBusy = busy
            }
        }

        // Смотришь на вкладку сессии в активном окне — её уведомления считаются просмотренными.
        // Здесь, а не только при клике по вкладке: id сессии мог стать известен лишь сейчас.
        markActiveSessionSeen()
    }

    /// Снять с иконки в доке метку «ждёт внимания» для сессии, на которую сейчас смотришь.
    /// Просмотр — это факт открытия: активная вкладка в ключевом окне переднего приложения.
    func markActiveSessionSeen() {
        guard NSApp.isActive, window?.isKeyWindow == true else { return }
        guard case .claude(let id) = pane,
              let sid = claudeTabs.first(where: { $0.id == id })?.live.sessionID else { return }
        DockBadge.markSeen(sid)
    }

    /// Смотрит ли пользователь прямо сейчас на вкладку этой сессии в активном окне — тогда
    /// уведомлению от неё незачем зажигать бейдж: его и так видят.
    func isViewingSession(_ session: String?) -> Bool {
        guard let session, NSApp.isActive, window?.isKeyWindow == true else { return false }
        guard case .claude(let id) = pane else { return false }
        return claudeTabs.first { $0.id == id }?.live.sessionID == session
    }

    // MARK: - Управление работающей сессией

    /// Останавливает то, что Claude сейчас делает, — но не убивает сессию.
    ///
    /// Escape: именно его Claude Code и предлагает («esc to interrupt»). Ctrl+C выглядит
    /// заманчивее, но он же и выходит из Claude, если нажать дважды, — а кнопка «Стоп»,
    /// которая иногда закрывает разговор, никуда не годится.
    func stopSession(_ tab: ClaudeTab) {
        terminal.type("\u{1b}", on: tab.terminal)

        // Гасим «работает» по id ВКЛАДКИ, а не по id сессии из переданной копии: копия могла быть
        // снята до того, как журнал сообщил id, и тогда кнопка «Стоп» гасила бы не ту сессию —
        // или, что было на самом деле, вообще ни одной.
        guard let i = claudeTabs.firstIndex(where: { $0.id == tab.id }) else { return }
        claudeTabs[i].isBusy = false
    }

    /// Меняет модель работающей сессии — той же командой, что набрали бы руками.
    ///
    /// Никакой скрытой магии: `/model opus` уходит в терминал и виден в нём. Плашку при этом
    /// переключаем сразу, оптимистично: команда валидна (алиас из нашего же списка), и ждать
    /// полторы секунды, пока журнал догонит, ради подтверждения того, что и так произойдёт, —
    /// значит показывать «ничего не изменилось» в ответ на явное действие. Журнал позже
    /// подтвердит (или, если Claude почему-то не принял, поправит — он источник правды).
    /// Кавычек здесь нет намеренно, в отличие от команды запуска: это ввод не в шелл, а в самого
    /// Claude — он читает строку целиком, и `opus[1m]` для него обычный алиас, а не шаблон файлов.
    func switchModel(_ tab: ClaudeTab, to model: ClaudeModel) {
        guard let alias = model.alias(longContext: tab.longContext) else { return }
        terminal.run("/model " + alias, on: tab.terminal)
        updateLive(tab) { $0.model = model.title; $0.modelAlias = alias }
    }

    func switchEffort(_ tab: ClaudeTab, to effort: ClaudeEffort) {
        guard let level = effort.flag else { return }
        terminal.run("/effort " + level, on: tab.terminal)
        // Особенно важно для effort: его интерактивную смену (`/effort` без аргумента, выбор
        // стрелками) Claude в журнал не пишет вовсе, так что подтвердить оттуда нечем — наш
        // оптимистичный снимок и есть единственный источник для плашки.
        updateLive(tab) { $0.effort = effort }
    }

    /// Меняет режим работы. Слэш-команды для него у Claude Code нет — режимы перебираются
    /// по shift+tab, по кругу. Мы знаем текущий (из журнала) и нужный, поэтому просто шлём
    /// столько shift+tab, сколько шагов между ними.
    func switchPermissions(_ tab: ClaudeTab, to target: ClaudePermissions) {
        let cycle = ClaudePermissions.cycle
        guard let from = cycle.firstIndex(of: tab.shownPermissions),
              let to = cycle.firstIndex(of: target), from != to
        else { return }

        updateLive(tab) { $0.permissions = target }
        let steps = (to - from + cycle.count) % cycle.count
        permissionTasks[tab.id]?.cancel()
        permissionTasks[tab.id] = Task { [weak self] in
            for step in 0..<steps {
                // Нажатия разносим во времени: Claude перерисовывает подсказку режима после
                // каждого, и пачка, пришедшая одним куском, может слипнуться в одно нажатие.
                if step > 0 { try? await Task.sleep(nanoseconds: Delay.permissionKeystroke) }
                guard let self, !Task.isCancelled else { return }
                self.terminal.type("\u{1b}[Z", on: tab.terminal)
            }
        }
    }

    /// Оптимистичное обновление живого состояния вкладки: показать выбор сразу, не дожидаясь,
    /// пока журнал подтвердит то, что мы только что сами и отправили.
    private func updateLive(_ tab: ClaudeTab, _ change: (inout ClaudeLive) -> Void) {
        guard let i = claudeTabs.firstIndex(where: { $0.id == tab.id }) else { return }
        change(&claudeTabs[i].live)
    }

    /// Показать разбивку по лимитам: `/usage` рисует её прямо в терминале Claude. Наружу цифры
    /// он не отдаёт, поэтому просто открываем его же экран — как если бы команду набрали руками.
    func showUsage(_ tab: ClaudeTab) {
        terminal.run("/usage", on: tab.terminal)
    }

    /// Включает/выключает remote-control этой сессии — управление с телефона и push через
    /// приложение Claude. `/remote-control` в Claude Code переключает режим, поэтому и мы
    /// переключаем свой флаг. Состояние оптимистичное: надёжно прочитать его из журнала нельзя.
    func toggleRemoteControl(_ tab: ClaudeTab) {
        terminal.run("/remote-control", on: tab.terminal)
        guard let i = claudeTabs.firstIndex(where: { $0.id == tab.id }) else { return }
        claudeTabs[i].remoteControl.toggle()
    }

    /// Открыть диалог переименования вкладки, подставив в поле текущее имя.
    func startRenaming(_ id: UUID) {
        guard let tab = claudeTabs.first(where: { $0.id == id }) else { return }
        renameText = tab.shownTitle
        renamingTabID = id
    }

    /// Применить набранное имя и закрыть диалог.
    func commitRename() {
        if let id = renamingTabID { renameTab(id, to: renameText) }
        renamingTabID = nil
    }

    /// Переименовать вкладку сессии. Имя живёт у нас (Claude Code не даёт команды переименовать
    /// разговор снаружи) и приоритетнее того, что Claude придумывает сам. Пустое имя возвращает
    /// вкладку к автоматическому заголовку. Если id сессии уже известен — имя сохраняется по нему
    /// и переживает переоткрытие разговора.
    func renameTab(_ id: UUID, to name: String) {
        guard let i = claudeTabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        claudeTabs[i].customTitle = trimmed.isEmpty ? nil : trimmed
        if let sid = claudeTabs[i].live.sessionID {
            SessionTitles.set(claudeTabs[i].customTitle, for: sid)
            sessionTitles = SessionTitles.all()
        }
    }

    /// Переименовать разговор из списка сессий — по его id. Сохраняется на диск и сразу
    /// применяется к открытой вкладке этого разговора, если она есть.
    func renameSession(_ sessionID: String, to name: String) {
        SessionTitles.set(name, for: sessionID)
        sessionTitles = SessionTitles.all()
        if let i = claudeTabs.firstIndex(where: { $0.live.sessionID == sessionID }) {
            claudeTabs[i].customTitle = sessionTitles[sessionID]
        }
    }

    /// Название разговора для показа: заданное пользователем приоритетнее того, что Claude
    /// придумал сам.
    func displayTitle(for session: ClaudeSession) -> String {
        sessionTitles[session.id] ?? session.title
    }

    /// Картинки из разговора активной вкладки. Разбираем журнал по требованию — держать
    /// мегабайты base64 в памяти ради значка со счётчиком незачем (см. ClaudeAttachments).
    func attachments(of tab: ClaudeTab) async -> [ClaudeAttachments.Item] {
        guard let journal = probes[tab.id]?.journal else { return [] }
        return await Task.detached { ClaudeAttachments.list(in: journal) }.value
    }

    /// Открыть окно с картинками разговора.
    func showAttachments(_ tab: ClaudeTab) {
        attachmentsTabID = tab.id
    }

    // MARK: - Ссылки из терминала

    /// Нажали ссылку в терминале.
    ///
    /// Адрес уходит в браузер, а **путь к файлу — в наш редактор**: Claude сыплет в чат путями
    /// (`Sources/Core/Git.swift`, `src/app.py:42`), и открывать их системой бессмысленно — она
    /// честно отвечает «не удалось найти программу», потому что это не URL. А файл вот он, рядом,
    /// и открыть его надо там же, где на него и смотрят.
    func openLink(_ raw: String) {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }

        if let url = URL(string: link), let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto", "ftp"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        Task { await openPath(link) }
    }

    /// Что из ссылки считать путём к файлу.
    ///
    /// Claude печатает пути с указанием строки — `Git.swift:42`, `src/app.py:42:9` — и заворачивает
    /// их в скобки и кавычки. Не отсечёшь хвост — файл просто «не найдётся», и клик по нему
    /// покажет ошибку там, где всё на месте. Отдельной функцией, чтобы это проверялось тестом.
    static func filePath(fromLink link: String) -> String {
        // Обрамление снимаем ПЕРВЫМ: пока на конце висит `)`, номер строки в `(app.py:7)`
        // не выглядит номером — и остаётся частью имени файла.
        let junk = CharacterSet(charactersIn: "\"'()[]<>,. ").union(.whitespacesAndNewlines)
        var path = link.trimmingCharacters(in: junk)
        if let url = URL(string: path), url.scheme?.lowercased() == "file" { path = url.path }

        // `:42` и `:42:9` — номера строки и колонки, а не часть имени.
        while path.contains(":"), !path.hasSuffix("/"),
              let last = path.split(separator: ":").last,
              !last.isEmpty, last.allSatisfy(\.isNumber) {
            path = String(path.dropLast(last.count + 1))
        }
        return path.trimmingCharacters(in: junk)
    }

    /// Путь из терминала → вкладка редактора, просмотр или проигрыватель.
    private func openPath(_ link: String) async {
        let path = Self.filePath(fromLink: link)
        guard !path.isEmpty else { return }

        // Сначала — диск этого Mac. Claude печатает и ЛОКАЛЬНЫЕ пути: скриншоты из буфера
        // (.attachments) и файлы своей рабочей папки лежат здесь, а не на сервере. Раньше такой
        // путь искался по ssh на сервере — и честно «не находился», хотя файл вот он.
        if let local = localCandidate(path) {
            openLocalMedia(local)
            return
        }

        // Относительный путь — от корня проекта: именно так его и печатает Claude.
        let root = repoRoot ?? basePath
        let abs = path.hasPrefix("/") || path.hasPrefix("~") ? path : root + "/" + path

        guard await RemoteFS.exists(conn: conn, path: abs) else {
            toast(.error, "Не нашёл файл «\(path)» в проекте")
            return
        }
        guard await !RemoteFS.isDir(conn: conn, path: abs) else {
            toast(.error, "«\(path)» — это папка, а не файл")
            return
        }

        // Видео и аудио в редакторе не показать — скачиваем во временный файл и отдаём
        // системному проигрывателю. Картинки открывает openFile — своей вкладкой просмотра.
        if let kind = MediaKind(path: abs), kind != .image {
            await openRemoteMedia(abs, kind: kind)
            return
        }

        pane = .file
        await openFile(abs)
    }

    /// Файл с таким путём на диске этого Mac, если он там есть. Относительные пути меряем
    /// от рабочей папки Claude — он пишет их относительно себя.
    private func localCandidate(_ path: String) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        let candidates = [
            expanded.hasPrefix("/") ? expanded : nil,
            localPath.isEmpty ? nil : localPath + "/" + path,
        ].compactMap { $0 }

        for c in candidates {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: c, isDirectory: &isDir), !isDir.boolValue {
                return URL(fileURLWithPath: c)
            }
        }
        return nil
    }

    /// Локальный файл: медиа — системе (Просмотр, QuickTime), остальное — в Finder-открытие
    /// текстом мы не лезем: локальные текстовые файлы открываются из панели Local, а сюда
    /// приходят в основном скриншоты.
    private func openLocalMedia(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Видео/аудио с сервера: во временный файл — и системному проигрывателю.
    private func openRemoteMedia(_ abs: String, kind: MediaKind) async {
        let name = (abs as NSString).lastPathComponent
        toast(.success, "Скачиваю \(kind.title) «\(name)»…")
        do {
            let data = try await RemoteFS.download(conn: conn, path: abs)
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("remoter-media", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent(name)
            try data.write(to: file, options: .atomic)
            NSWorkspace.shared.open(file)
        } catch {
            toast(.error, "Не удалось открыть «\(name)»: \(error.localizedDescription)")
        }
    }

    /// Claude начал отвечать / закончил. Приходит его же хуками (см. LocalWorkspace).
    /// Сессию находим по id — тому самому, что стоит в имени файла журнала.
    func setBusy(_ busy: Bool, session: String?) {
        guard let session else { return }
        guard let i = claudeTabs.firstIndex(where: { $0.live.sessionID == session }) else {
            pendingBusy[session] = busy
            return
        }
        pendingBusy[session] = nil
        guard claudeTabs[i].isBusy != busy else { return }
        claudeTabs[i].isBusy = busy
    }

    /// Закрывает вкладку сессии. Разговор при этом не пропадает: он записан в журнал Claude
    /// и открывается заново из списка сессий.
    func closeSession(_ id: UUID) {
        guard let i = claudeTabs.firstIndex(where: { $0.id == id }) else { return }

        terminal.forget(.claude(id))
        probes[id] = nil
        permissionTasks[id]?.cancel()
        permissionTasks[id] = nil
        claudeTabs.remove(at: i)

        guard case .claude(let active) = pane, active == id else { return }
        // Ушли с закрытой вкладки на соседнюю, а не в пустоту.
        if let next = neighbor(in: claudeTabs, afterRemovalAt: i) {
            pane = .claude(next.id)
        } else {
            pane = .file
        }
    }

    // MARK: - Нижний терминал

    /// Свернуть/развернуть панель терминала. Сам терминал при этом НЕ гибнет: свёрнутая панель —
    /// это спрятанная панель, а не убитый процесс. Иначе свернуть окно посреди сборки означало бы
    /// её оборвать.
    func toggleTerminalPanel() {
        isTerminalPanelOpen.toggle()
        if isTerminalPanelOpen { terminal.focus(shellTerminal) }
    }

    // MARK: - Список прошлых сессий

    /// Журнал сессий ведёт сам Claude Code, мы его только читаем. Чтение с диска — не на главном
    /// потоке: журнал долгой сессии легко весит десяток мегабайт, и на нём заметно дёрнулся бы UI.
    func loadSessions() async {
        let path = localPath
        guard !path.isEmpty else { return }

        isLoadingSessions = true
        let found = await Task.detached { ClaudeSessions.list(for: path) }.value
        sessions = found
        isLoadingSessions = false
    }

    /// Подставляет пути к файлам в строку ввода Claude. Enter не нажимается: подставить путь
    /// и отправить запрос — разные решения, и второе принимает человек.
    ///
    /// Claude читает картинки по пути — этого достаточно, чтобы показать ему скриншот.
    func attach(_ urls: [URL]) {
        guard !urls.isEmpty, let tab = activeClaudeTab else { return }
        terminal.type(Self.attachmentText(for: urls), on: tab.terminal)
    }

    /// Отдельно от отправки — чтобы можно было проверить тестом, что в путях с пробелами
    /// и кавычками ничего не разъезжается.
    static func attachmentText(for urls: [URL]) -> String {
        urls.map { shq($0.path) }.joined(separator: " ") + " "
    }
}
