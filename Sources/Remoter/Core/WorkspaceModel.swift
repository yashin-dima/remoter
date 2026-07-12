import Foundation
import SwiftUI
import AppKit

/// Модель окна проекта: всё состояние и жизненный цикл — соединение, поллинг, реестр окон.
///
/// Класс большой по обязанностям, поэтому разъехался по файлам-по-обязанности:
///  - `WorkspaceModel+Tabs.swift`      — ряд вкладок редактора;
///  - `WorkspaceModel+Documents.swift` — открытие, diff, живое обновление, сохранение;
///  - `WorkspaceModel+Tree.swift`      — серверное дерево файлов и git-бейджи;
///  - `WorkspaceModel+FileOps.swift`   — буфер обмена, удаление, переименование, загрузка;
///  - `WorkspaceModel+Git.swift`       — stage/unstage/commit/discard;
///  - `WorkspaceModel+Claude.swift`    — сессии Claude и терминалы на сервере;
///  - `WorkspaceModel+LocalPanel.swift` — локальная папка проекта на Mac.
///
/// Хранимые свойства Swift разрешает держать только здесь, поэтому весь стейт — в этом файле,
/// а у части @Published снят `private(set)`: их мутируют extension-файлы выше. Снаружи модели
/// (из UI) их по-прежнему нельзя трогать по договорённости — только читать.
@MainActor
final class WorkspaceModel: ObservableObject {

    let workspace: Workspace
    /// Канал к проекту: ssh на сервер или /bin/sh здесь же — остальному коду разницы нет.
    let conn: Connection
    let monaco = MonacoBridge()

    /// Можно ли поднимать терминалы.
    ///
    /// Условие двойное, и вторая половина неочевидна. Соединение поднимается РАНЬШЕ, чем
    /// создаётся локальная папка проекта, а NSViewRepresentable строит терминал ровно один раз.
    /// Стартуй он до появления папки — локальный шелл навсегда остался бы в домашнем каталоге,
    /// Claude не нашёл бы там CLAUDE.md и работал бы, не зная ни про сервер, ни про проект.
    var isTerminalReady: Bool {
        conn.state.isConnected && !localPath.isEmpty
    }

    /// Разрешена ли вообще запись. Проверяется в ОДНОЙ точке на каждую изменяющую операцию,
    /// а не россыпью по UI: спрятать кнопку — не то же самое, что запретить действие.
    var canWrite: Bool { !workspace.readOnly }

    /// Куда сохранять скриншоты из буфера. У локального проекта — не внутрь него: сыпать
    /// `.attachments` в чужой репозиторий и пачкать человеку `git status` мы не будем.
    var attachmentsDir: URL? {
        guard !localPath.isEmpty else { return nil }
        return LocalWorkspace.attachmentsDirectory(for: workspace, localPath: localPath)
    }

    /// Разделы боковой панели. У проекта на этом Mac раздела «Local» нет: он показывает рабочую
    /// папку Claude, а у локального проекта она и есть сам проект — второй раздел с тем же
    /// содержимым только путал бы.
    var sidebarTabs: [SidebarTab] {
        workspace.isLocal ? [.changes, .files] : SidebarTab.allCases
    }

    /// Подпись раздела: «Remote» у проекта, который лежит здесь же, читалось бы как ошибка.
    func sidebarTitle(_ tab: SidebarTab) -> String {
        tab == .files && workspace.isLocal ? "Файлы" : tab.title
    }

    /// Корень проекта на сервере с разрешёнными симлинками. Именно от него строится дерево —
    /// см. пояснение в start().
    @Published private(set) var basePath: String = ""
    @Published private(set) var repoRoot: String?
    @Published private(set) var status = GitStatus.empty
    /// Открытые вкладки. Как в браузере: файл открывается рядом, а не вместо предыдущего —
    /// сравнивать два файла, прыгая туда-сюда, иначе невозможно.
    @Published var tabs: [OpenDoc] = []
    @Published var activePath: String?

    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    /// Счётчик занятых операций: две параллельные (медленное открытие + сохранение) не должны
    /// гасить индикатор друг другу — он горит, пока не закончилась ПОСЛЕДНЯЯ.
    private var busyOps = 0
    func beginBusy() {
        busyOps += 1
        isBusy = true
    }
    func endBusy() {
        busyOps = max(0, busyOps - 1)
        if busyOps == 0 { isBusy = false }
    }

    /// Сколько раз Monaco рапортовал правку по каждому пути. По этому счётчику save()
    /// отличает «сохранил всё» от «пока сохранял, напечатали ещё».
    var dirtyEvents: [String: Int] = [:]

    /// Токен поколения открытия. Побеждать должен ПОСЛЕДНИЙ клик, а не самый медленный ответ
    /// сервера: без токена два быстрых клика по разным файлам показывали тот, чьё чтение
    /// доехало вторым. См. openFile/openDiff.
    var openGeneration = 0

    // Серверное дерево. Логика — в FileTreeState и WorkspaceModel+Tree.swift.
    @Published var rows: [TreeRow] = []
    var tree = FileTreeState()

    // Индекс git-статуса для бейджей: путь → что с ним, плюс папки, внутри которых есть правки.
    private(set) var kindByPath: [String: ChangeKind] = [:]
    private(set) var changedDirs: Set<String> = []

    // UI
    @Published var tab: SidebarTab = .changes
    @Published var selectedPath: String?
    @Published var diffBase: DiffBase = .head {
        didSet {
            // Предыдущее переоткрытие отменяем: быстрое щёлканье по переключателю не должно
            // копить задачи, наперегонки открывающие один и тот же diff.
            reopenTask?.cancel()
            reopenTask = Task { [weak self] in await self?.reopenCurrent() }
        }
    }
    @Published var sideBySide = true { didSet { monaco.setSideBySide(sideBySide) } }

    /// Что занимает основную часть окна. Claude здесь — не полоска внизу, а полноценная вкладка
    /// во весь экран: разговор с ним и есть работа, а diff и дерево — то, чем эту работу проверяют.
    @Published var pane: Pane = .file

    /// Открытые разговоры с Claude. Несколько сразу — это норма: над проектом идёт несколько
    /// задач, и открывать новую, обрывая текущую, бессмысленно.
    @Published var claudeTabs: [ClaudeTab] = []
    @Published var isNewSessionPresented = false

    /// Открытые терминалы на сервере.
    @Published var shells: [ShellTab] = []

    var activeClaudeTab: ClaudeTab? {
        guard case .claude(let id) = pane else { return nil }
        return claudeTabs.first { $0.id == id }
    }
    @Published var quickOpenFiles: [String] = []
    @Published var isQuickOpenPresented = false

    // Загрузка файлов перетаскиванием
    @Published var uploads: [Upload] = []
    @Published var toasts: [Toast] = []

    // Файловые операции в дереве
    /// Выделение множественное: операции чаще нужны над пачкой файлов, чем над одним.
    @Published var selection: Set<String> = []
    @Published var clipboard: Clipboard?
    @Published var renaming: String?

    // Терминал и панель запуска Claude
    let terminal = TerminalHandle()

    // Чем ЗАПУСТИТСЯ следующая сессия. Умолчания берутся из настроек приложения — они у каждого
    // свои; здесь их можно поменять на один раз, не трогая настройку.
    //
    // У уже запущенной сессии эти значения ничего не меняют: Claude читает параметры при старте.
    // Переключить их на ходу можно — но его же командами (`/model`, `/effort`, shift+tab),
    // и делает это switchModel/switchEffort/switchPermissions, а не подмена полей здесь.
    @Published var claudeModel: ClaudeModel = AppSettings.shared.model
    @Published var claudeEffort: ClaudeEffort = AppSettings.shared.effort
    @Published var claudePermissions: ClaudePermissions = AppSettings.shared.permissions
    @Published var claudeLongContext: Bool = AppSettings.shared.longContext

    /// Прошлые разговоры с Claude по этому проекту. Ведёт их сам Claude Code, мы только читаем.
    @Published var sessions: [ClaudeSession] = []
    @Published var isLoadingSessions = false
    @Published var isSessionsPresented = false

    /// Заданные пользователем названия сессий (по id сессии). Зеркало SessionTitles — держим его
    /// @Published, чтобы список сессий и вкладки перерисовывались сразу после переименования.
    @Published var sessionTitles: [String: String] = SessionTitles.all()

    /// Какую вкладку сейчас переименовывают и что набрано в поле. Пусто — диалог закрыт.
    @Published var renamingTabID: UUID?
    @Published var renameText: String = ""

    /// Локальная папка проекта на Mac — рабочий каталог Claude. См. LocalWorkspace.
    @Published private(set) var localPath: String = ""
    /// Хост, путь и сокет для локального терминала.
    @Published private(set) var localEnv: [String] = []

    // Локальное дерево — своё, отдельное от серверного, но на той же FileTreeState.
    @Published var localRows: [TreeRow] = []
    var localTree = FileTreeState()
    /// Установлен ли `claude` на этой машине. Если нет, панель честно об этом скажет,
    /// а не будет молча слать команду в никуда.
    @Published private(set) var claudeInstalled = true

    // Слежение за сессиями Claude (см. WorkspaceModel+Claude.swift).
    /// За чьими журналами следим. Ключ — вкладка.
    var probes: [UUID: SessionProbe] = [:]
    /// Каталог журналов этого проекта. Ищется один раз и запоминается: неудачное угадывание
    /// имени заставляло ClaudeSessions.directory(for:) перебирать ВСЕ проектные каталоги
    /// с чтением их журналов — и так на каждом тике поллинга, раз в полторы секунды.
    var sessionsDir: URL?
    /// Хуки, пришедшие раньше, чем журнал сообщил id сессии. Первый «Claude начал отвечать»
    /// прилетает через секунду после запуска, а журнал опознаётся тиком поллинга позже —
    /// не придержи мы событие, вкладка не узнала бы, что сессия уже работает.
    var pendingBusy: [String: Bool] = [:]
    /// Серии shift+tab по вкладкам — храним, чтобы обрывать: и при новом клике по плашке
    /// (старая серия ещё не дослана), и при закрытии вкладки (нажатия летели бы в никуда).
    var permissionTasks: [UUID: Task<Void, Never>] = [:]

    private var pollTask: Task<Void, Never>?
    /// Опрос журналов Claude — что сейчас у открытых сессий.
    private var sessionTask: Task<Void, Never>?
    private var isPaused = false
    /// Переоткрытие diff'а после смены diffBase — храним, чтобы отменять предыдущее.
    private var reopenTask: Task<Void, Never>?

    /// Все интервалы и задержки — в одном месте, а не россыпью «магии» по коду.
    enum Delay {
        /// `git status` по ssh: раз в 2.5 секунды — достаточно живо и почти бесплатно.
        static let gitPoll: UInt64 = 2_500_000_000
        /// Журналы Claude — локальные файлы, их можно читать чаще.
        static let sessionPoll: UInt64 = 1_500_000_000
        /// Ошибке даём провисеть дольше: её читают, а не просто замечают.
        static let errorToast: UInt64 = 6_000_000_000
        static let successToast: UInt64 = 3_500_000_000
        /// Пауза между shift+tab: Claude перерисовывает подсказку режима после каждого нажатия,
        /// и пачка, пришедшая одним куском, слипается в одно.
        static let permissionKeystroke: UInt64 = 120_000_000
    }

    init(workspace: Workspace) {
        self.workspace = workspace
        self.basePath = workspace.path

        // Реестр моделей: по нему уведомление находит своё окно. Ссылки слабые — закрытое окно
        // должно исчезать само, а не жить вечно из-за того, что где-то на него держат список.
        Self.live.removeAll { $0.box.model == nil }
        // Единственное место во всём приложении, где выбирается транспорт. Дальше и дерево,
        // и git, и diff, и сохранение работают одинаково — они разговаривают с Connection.
        self.conn = workspace.isLocal
            ? LocalConnection()
            : SSHConnection(
                host: workspace.host,
                port: workspace.port,
                extraArgs: workspace.extraSSHArgs,
                // Канал именуется по проекту, а не по серверу: два проекта на одном сервере —
                // это два независимых окна, и закрытие одного не должно рвать связь у другого.
                key: workspace.id.uuidString
            )

        // События из редактора приходят с путём: Monaco может рапортовать о вкладке,
        // которая уже не активна, и без пути мы бы пометили «грязной» не ту.
        monaco.onDirty = { [weak self] path, dirty in
            // Счётчик правок: сохранение снимает его на старте и по завершении сбрасывает
            // isDirty только если новых правок за время записи не пришло — см. save().
            if dirty { self?.dirtyEvents[path, default: 0] += 1 }
            self?.updateTab(path) { doc in
                doc.isDirty = dirty
                // Начали править — файл больше не «на посмотреть»: вкладка становится постоянной,
                // иначе следующий клик в дереве закрыл бы её вместе с набранным.
                if dirty { doc.isPreview = false }
            }
        }
        monaco.onStats = { [weak self] path, added, removed in
            self?.updateTab(path) { $0.added = added; $0.removed = removed }
        }
        monaco.onSave = { [weak self] path, content in
            Task { await self?.save(path: path, content: content) }
        }

        Self.live.append((workspace.id, WeakModel(self)))
    }

    // MARK: - Запуск

    func start() async {
        await conn.connect()
        guard conn.state.isConnected else {
            // У локального проекта соединение не нужно и всегда «есть» — сюда попадает только
            // серверный, и ему есть что сказать про хост.
            monaco.showMessage("Нет соединения с \(workspace.host)")
            return
        }

        // Симлинки разрешаем сразу: git отдаёт корень репозитория уже разрешённым, и если
        // дерево строить по «сырому» пути, пути из дерева и пути из git не совпадут ни в одном
        // символе — бейджи не появятся, а клик по файлу не откроет diff.
        basePath = await RemoteFS.resolve(conn: conn, path: workspace.path) ?? workspace.path

        repoRoot = await Git.repoRoot(conn: conn, path: basePath)
        if repoRoot == nil { tab = .files }

        await loadDir(basePath)
        tree.expanded.insert(basePath)
        await refresh(force: true)
        rebuildRows()
        monaco.showMessage(placeholderMessage)

        // Локальное пространство для Claude: папка на Mac со скриптами доступа к серверу.
        // Обновляем при каждом открытии — сокет и путь могли поменяться.
        let notifyURL = await MonacoServer.shared.notifyURL()
        do {
            let dir = try LocalWorkspace.provision(
                workspace: workspace,
                conn: conn,
                remoteRoot: repoRoot ?? basePath,
                notifyURL: notifyURL
            )
            localPath = dir.path
            localEnv = LocalWorkspace.environment(
                workspace: workspace,
                conn: conn,
                remoteRoot: repoRoot ?? basePath
            )
        } catch {
            // localPath остаётся пустым — и это правильнее любого фолбэка: запусти мы Claude
            // в домашней папке, он прочитал бы чужой CLAUDE.md, а мы стали бы читать журналы
            // «проекта $HOME» — чужие сессии. Пустой путь честно блокирует запуск.
            toast(.error, "Не удалось создать локальную папку проекта: \(error.localizedDescription)")
        }
        claudeInstalled = LocalWorkspace.isClaudeInstalled()
        reloadLocalTree()

        await loadSessions()
        autostartClaude()

        startPolling()
        Task { await loadQuickOpenIndex() }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        sessionTask?.cancel()
        sessionTask = nil
        reopenTask?.cancel()
        reopenTask = nil
        refreshChain?.cancel()
        refreshChain = nil
        for task in permissionTasks.values { task.cancel() }
        permissionTasks.removeAll()
        conn.disconnect()
    }

    func setPaused(_ paused: Bool) { isPaused = paused }

    // MARK: - Кто где живёт
    //
    // Уведомление приходит от Claude из КОНКРЕТНОГО проекта, и по клику надо попасть именно в его
    // окно и именно на его вкладку. Значит, откуда-то нужно узнать, какая модель какому проекту
    // принадлежит и в каком окне она нарисована. Отсюда этот реестр.

    private static var live: [(id: UUID, box: WeakModel)] = []

    private final class WeakModel {
        weak var model: WorkspaceModel?
        init(_ m: WorkspaceModel) { model = m }
    }

    /// Окно, в котором нарисована эта модель. Ставится самим окном (см. WindowReader):
    /// изнутри SwiftUI до NSWindow дотянуться больше нечем.
    weak var window: NSWindow?

    static func model(for id: UUID) -> WorkspaceModel? {
        live.first { $0.id == id }?.box.model
    }

    /// Показать проект: поднять его окно и открыть вкладку Claude — ту самую, откуда пришло
    /// уведомление. Окна может уже не быть (проект закрыли) — тогда ничего и не происходит.
    @discardableResult
    static func reveal(_ id: UUID) -> Bool {
        guard let model = model(for: id) else { return false }

        // Ведём на последнюю активную сессию Claude — уведомление пришло именно оттуда.
        if let tab = model.activeClaudeTab ?? model.claudeTabs.last {
            model.pane = .claude(tab.id)
            model.terminal.focus(tab.terminal)
            // Открыли по клику на уведомлении — значит просмотрели: гасим его вклад в бейдж.
            DockBadge.markSeen(tab.live.sessionID)
        }

        NSApp.activate(ignoringOtherApps: true)
        model.window?.makeKeyAndOrderFront(nil)
        return true
    }

    // MARK: - Поллинг
    //
    // Мы не ставим ничего на сервер: раз в 2.5 секунды дёргаем `git status` по уже открытому
    // каналу — это десятки миллисекунд. Если вывод не изменился, ничего не перерисовываем.
    //
    // Отдельная тонкость: когда Claude правит файл, который git и так считает изменённым,
    // вывод `git status` остаётся прежним. Поэтому у открытого файла дополнительно проверяем
    // контрольную сумму — иначе «живого» обновления diff'а бы не получилось.

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Delay.gitPoll)
                guard let self, !Task.isCancelled else { return }
                if self.isPaused { continue }
                await self.refresh(force: false)
            }
        }

        // Журналы Claude читаются отдельно и чаще: это локальные файлы, а не команды на сервере,
        // и стоят они почти ничего. На паузу этот опрос не встаёт — вернувшись к окну, вы должны
        // видеть, что у сессии сейчас, а не то, что было, когда вы от неё ушли.
        sessionTask?.cancel()
        sessionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Delay.sessionPoll)
                guard let self, !Task.isCancelled else { return }
                await self.followSessions()
            }
        }
    }

    /// Очередь обновлений. Refresh'и НЕ должны идти вперемешку: два параллельных запроса
    /// `git status` возвращаются в произвольном порядке, и устаревший, доехав вторым,
    /// перекрыл бы свежий — бейджи и список изменений врали бы до следующего тика.
    private var refreshChain: Task<Void, Never>?
    private var isRefreshing = false

    func refresh(force: Bool) async {
        // Плановый поллинг не встаёт в очередь за уже идущим обновлением: следующий тик догонит.
        if !force, isRefreshing { return }

        let previous = refreshChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.performRefresh(force: force)
        }
        refreshChain = task
        await task.value
        if refreshChain == task { refreshChain = nil }
    }

    private func performRefresh(force: Bool) async {
        isRefreshing = true
        defer { isRefreshing = false }

        // Связь могла отвалиться (сон Mac, смена сети) — поллинг заодно и переподключает.
        if !conn.state.isConnected {
            await conn.connect()
            guard conn.state.isConnected else { return }
        }

        async let statusResult: GitStatus? = fetchStatus()
        async let checksumResult: (path: String, sum: String)? = fetchOpenFileChecksum()

        let (newStatus, checksum) = await (statusResult, checksumResult)

        if let newStatus, force || newStatus.fingerprint != status.fingerprint {
            status = newStatus
            reindexStatus()
            await reloadExpandedDirs()
            rebuildRows()
        }

        // Содержимое открытого файла поменялось на сервере — подтягиваем.
        if let checksum,
           tabs.first(where: { $0.absPath == checksum.path })?.checksum != checksum.sum {
            updateTab(checksum.path) { $0.checksum = checksum.sum }
            await reloadContent(path: checksum.path)
        }
    }

    private func fetchStatus() async -> GitStatus? {
        guard let root = repoRoot else { return nil }
        return try? await Git.status(conn: conn, root: root)
    }

    private func reindexStatus() {
        kindByPath = [:]
        changedDirs = []
        for c in status.changes {
            kindByPath[c.path] = c.kind
            var dir = (c.path as NSString).deletingLastPathComponent
            while !dir.isEmpty {
                changedDirs.insert(dir)
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
    }

    // MARK: - Уведомления

    enum ToastKind { case success, error }

    struct Toast: Identifiable, Equatable {
        var id = UUID()
        var kind: ToastKind
        var text: String
    }

    func toast(_ kind: ToastKind, _ text: String) {
        let t = Toast(kind: kind, text: text)
        toasts.append(t)
        // weak: таймер тоста не должен держать закрытое окно в памяти лишние секунды.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: kind == .error ? Delay.errorToast : Delay.successToast)
            self?.toasts.removeAll { $0.id == t.id }
        }
    }
}
