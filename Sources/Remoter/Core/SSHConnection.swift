import Foundation

/// Соединение с сервером через системный `ssh` в режиме мультиплексирования (ControlMaster).
///
/// Мы намеренно НЕ реализуем SSH-протокол сами: системный клиент бесплатно даёт нам весь
/// `~/.ssh/config` пользователя — алиасы хостов, ключи, agent, ProxyJump, известные хосты.
/// Одно мастер-соединение держится в фоне, а каждая команда (`git status`, `cat`, запись файла)
/// летит по уже открытому каналу без нового рукопожатия — это миллисекунды вместо секунд.
///
/// Пароли и парольные фразы спрашивает askpass-хелпер (нативный диалог), потому что у мастера
/// нет терминала и спросить в консоли он не может.
@MainActor
final class SSHConnection: Connection {

    /// Состояние и ошибки — общие для всех транспортов (см. Connection). Псевдонимы оставлены,
    /// чтобы не переписывать половину кода и тестов, которые уже зовут их по этим именам.
    typealias SSHError = ConnectionError

    // MARK: - Константы соединения
    //
    // Собраны в одном месте, а не рассыпаны магическими числами по коду.

    /// Как часто мастер шлёт keep-alive серверу (секунды) — и сколько пропусков терпит.
    private static let serverAliveInterval = 15
    private static let serverAliveCountMax = 3
    /// Таймаут TCP-подключения самого ssh (секунды).
    private static let connectTimeout = 20
    /// Сколько всего ждём подъёма мастера — с запасом на askpass: человек вводит пароль.
    private static let masterStartupTimeout: TimeInterval = 90
    /// Пауза между проверками `-O check` при подъёме мастера.
    private static let masterPollInterval: TimeInterval = 0.25
    /// Таймаут одной проверки `-O check` (сокет локальный, но сам ssh может тормозить).
    private static let masterCheckTimeout: TimeInterval = 10
    /// Как часто проверять живость усыновлённого мастера: он не наш ребёнок,
    /// и terminationHandler на него не повесить.
    private static let adoptedWatchInterval: TimeInterval = 15

    let host: String
    let port: Int?
    /// Дополнительные аргументы ssh из настроек воркспейса (свой ключ, бастион и т.п.).
    let extraArgs: [String]
    private let socketPath: String
    private var master: Process?
    private var connectTask: Task<Void, Never>?
    /// Наблюдение за усыновлённым мастером — тем, которого запускали не мы.
    private var adoptedWatchTask: Task<Void, Never>?

    /// `key` разводит соединения по разным сокетам. Для проекта это его id — то есть у каждого
    /// открытого проекта свой канал, даже если сервер один и тот же.
    ///
    /// Раньше сокет зависел только от хоста и порта, и два проекта на одном сервере оказывались
    /// на одном канале. Пока оба открыты — не беда, но `disconnect()` удаляет файл сокета: стоило
    /// закрыть одно окно (или просто нажать «Проверить подключение» в настройках), как второе
    /// теряло связь на ровном месте. Проекты должны быть независимы — значит, и каналы тоже.
    init(host: String, port: Int? = nil, extraArgs: [String] = [], key: String = UUID().uuidString) {
        self.host = host
        self.port = port
        self.extraArgs = extraArgs
        self.socketPath = Self.socketPath(for: host, port: port, key: key)
        super.init()
        // Заодно выкидываем боксы умерших соединений: иначе массив рос бы весь срок жизни
        // приложения — по пустому боксу на каждое «Проверить подключение».
        Self.live.removeAll { $0.conn == nil }
        Self.live.append(WeakBox(self))
    }

    // MARK: - Уборка при выходе
    //
    // Мастер `ssh -N` не умирает вместе с родителем: закрой приложение — и на машине останется
    // висеть фоновый ssh к серверу. Поэтому при выходе гасим все соединения явно.

    private static var live: [WeakBox] = []

    static func disconnectAll() {
        for box in live { box.conn?.disconnect() }
        live.removeAll()
    }

    private final class WeakBox {
        weak var conn: SSHConnection?
        init(_ c: SSHConnection) { conn = c }
    }

    // MARK: - Пути

    /// Сокет мультиплексора. Держим путь коротким: у unix-сокетов лимит ~104 символа,
    /// а `~/Library/Application Support/...` его почти выбирает.
    ///
    /// Имя детерминированное: если приложение упало, не успев прибрать за собой, следующий запуск
    /// того же проекта подберёт осиротевший мастер, а не оставит его висеть навсегда.
    ///
    /// `REMOTER_SOCKETS` — свой каталог сокетов для тестов и отладки (по аналогии с
    /// `REMOTER_STORE`): чтобы прогоны не складывали ничего в настоящий `~/.remoter`.
    /// Больше этого ssh не примет: `sun_path` — 104 байта, и к нашему пути он дописывает
    /// собственный временный суффикс (`.sock.qrv80JODnd6xBZ32`) на время создания listener'а.
    /// Считаем с запасом на суффикс — иначе ssh падает с «path too long», и это выглядит
    /// как «сервер недоступен», а не как «путь не поместился».
    private static let maxSocketPathLength = 84

    private static func socketPath(for host: String, port: Int?, key: String) -> String {
        let env = ProcessInfo.processInfo.environment["REMOTER_SOCKETS"]
        let dir = env?.isEmpty == false
            ? env!
            // Тест без REMOTER_SOCKETS кладёт сокеты в свою песочницу, а не в ~/.remoter.
            : TestIsolation.path("sockets") {
                URL(fileURLWithPath: NSHomeDirectory() + "/.remoter/sockets", isDirectory: true)
            }.path

        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in "\(host):\(port ?? 0):\(key)".utf8 { hash = (hash ^ UInt64(b)) &* 0x1000_0000_01b3 }
        let name = "\(String(hash, radix: 36)).sock"

        // Каталог может оказаться длинным: TMPDIR на маке — это /var/folders/9q/nx7s7…/T/,
        // и одного его хватает, чтобы сокет не создался. Тогда уходим в /tmp: короткий путь
        // важнее красивого расположения, без сокета не работает вообще ничего.
        var chosen = "\(dir)/\(name)"
        if chosen.utf8.count > maxSocketPathLength {
            let short = "/tmp/remoter-\(ProcessInfo.processInfo.processIdentifier)"
            NSLog("Remoter: путь сокета \(chosen) длиннее \(maxSocketPathLength) байт — беру \(short)")
            chosen = "\(short)/\(name)"
        }

        try? FileManager.default.createDirectory(
            atPath: (chosen as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        return chosen
    }

    /// Путь к сокету нужен снаружи: терминал подключается через тот же канал.
    var controlSocket: String { socketPath }

    /// Аргументы ssh, общие для мастера, команд и терминала.
    var connectArgs: [String] { (port.map { ["-p", String($0)] } ?? []) + extraArgs }

    /// Терминал этого проекта — ssh по тому же каналу, что и команды: открывается мгновенно
    /// и не спрашивает пароль второй раз.
    override var terminalLaunch: TerminalLaunch {
        .ssh(socket: socketPath, host: host, args: connectArgs)
    }

    private var askpassEnv: [String: String] {
        guard let script = Bundle.main.path(forResource: "askpass", ofType: "sh") else { return [:] }
        return [
            "SSH_ASKPASS": script,
            // force — иначе ssh проигнорирует askpass, решив, что можно спросить в консоли.
            "SSH_ASKPASS_REQUIRE": "force",
            // Значение фиктивное: X11 на маке нет, но без установленного DISPLAY старые ssh
            // отказываются звать askpass вовсе. Сам дисплей никогда не открывается.
            "DISPLAY": ":0",
        ]
    }

    // MARK: - Жизненный цикл

    /// Поднимает мастер-соединение, если его ещё нет. Повторные вызовы во время подключения
    /// присоединяются к уже идущей попытке, а не плодят новые.
    override func connect() async {
        if state.isConnected, await isMasterAlive() { return }
        if let t = connectTask { await t.value; return }

        let task = Task { await self.performConnect() }
        connectTask = task
        await task.value
        connectTask = nil
    }

    private func performConnect() async {
        state = .connecting
        tearDownMaster()

        // Чужой (или наш осиротевший) мастер на этом сокете — используем его как есть.
        // Он не наш ребёнок, terminationHandler на него не повесить — за ним следит
        // отдельная периодическая проверка, иначе «connected» зависло бы навсегда.
        if await isMasterAlive() {
            state = .connected
            watchAdoptedMaster()
            return
        }
        try? FileManager.default.removeItem(atPath: socketPath)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = [
            "-M", "-S", socketPath,
            // ControlPersist=no — мастер живёт ровно столько, сколько живём мы.
            // Иначе после выхода из приложения на сервере остаётся висеть процесс.
            "-o", "ControlPersist=no",
            "-o", "ServerAliveInterval=\(Self.serverAliveInterval)",
            "-o", "ServerAliveCountMax=\(Self.serverAliveCountMax)",
            "-o", "ConnectTimeout=\(Self.connectTimeout)",
            "-N", "-T",
        ] + connectArgs + [host]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in askpassEnv { env[k] = v }
        p.environment = env

        let errPipe = Pipe()
        p.standardError = errPipe
        // stdout мастера никто не читает: с `-N` ему нечего сказать, а Pipe(), который
        // не дренируют, — это 64К буфера и заблокированный мастер, если сервер вдруг
        // окажется болтливым (Banner и т.п.). В null — надёжнее.
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice

        let errBox = ErrBox()
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { errBox.append(d) }
        }

        do { try p.run() } catch {
            state = .failed("Не удалось запустить ssh: \(error.localizedDescription)")
            return
        }
        master = p

        // Мастер поднимается асинхронно: ждём, пока сокет начнёт отвечать на `-O check`.
        // Параллельно следим, не умер ли сам ssh (неверный ключ, отказ в доступе, нет хоста).
        let deadline = Date().addingTimeInterval(Self.masterStartupTimeout)
        while Date() < deadline {
            if !p.isRunning {
                let reason = errBox.text.trimmingCharacters(in: .whitespacesAndNewlines)
                state = .failed(reason.isEmpty ? "ssh завершился с кодом \(p.terminationStatus)" : reason)
                master = nil
                return
            }
            if await isMasterAlive() {
                state = .connected
                observeMasterExit(p)
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.masterPollInterval * 1_000_000_000))
        }

        tearDownMaster()
        state = .failed("Таймаут подключения к \(host)")
    }

    /// Усыновлённый мастер (осиротевший после падения или чужой) — не наш дочерний процесс:
    /// узнать о его смерти можно только опросом. Без этого разрыв сети оставлял бы UI
    /// в состоянии «connected» навсегда.
    private func watchAdoptedMaster() {
        adoptedWatchTask?.cancel()
        adoptedWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.adoptedWatchInterval * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                guard self.state.isConnected else { return }
                if await !self.isMasterAlive() {
                    guard self.state.isConnected else { return }
                    self.state = .failed("Соединение с \(self.host) потеряно")
                    return
                }
            }
        }
    }

    /// Мастер может умереть в любой момент (сон Mac, разрыв сети) — тогда переводим UI в offline.
    private func observeMasterExit(_ p: Process) {
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self, self.master === proc else { return }
                self.master = nil
                if self.state.isConnected {
                    self.state = .failed("Соединение с \(self.host) потеряно")
                }
            }
        }
    }

    private func isMasterAlive() async -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        let r = try? await Proc.run(
            "/usr/bin/ssh",
            ["-O", "check", "-S", socketPath, host],
            timeout: Self.masterCheckTimeout
        )
        return r?.ok ?? false
    }

    private func tearDownMaster() {
        adoptedWatchTask?.cancel()
        adoptedWatchTask = nil
        if let m = master {
            m.terminationHandler = nil
            if m.isRunning { m.terminate() }
        }
        master = nil
    }

    override func disconnect() {
        connectTask?.cancel()
        connectTask = nil
        // `-O exit` просит мастера завершиться — это единственный способ погасить
        // УСЫНОВЛЁННОГО мастера (он не наш ребёнок, terminate() до него не дотянется).
        // Раньше сокет просто удалялся, и осиротевший ssh жил вечно — теперь уже недостижимый.
        // Разговор идёт по локальному unix-сокету, так что это быстро; мёртвый сокет — ошибка
        // сразу, её глотаем.
        if FileManager.default.fileExists(atPath: socketPath) {
            _ = try? Proc.runSync("/usr/bin/ssh", ["-O", "exit", "-S", socketPath, host], timeout: 3)
        }
        tearDownMaster()
        try? FileManager.default.removeItem(atPath: socketPath)
        state = .idle
    }

    // MARK: - Выполнение команд

    /// Выполняет POSIX-скрипт на сервере через уже открытый канал.
    ///
    /// Скрипт передаётся как `/bin/sh -c '<script>'`, а не россыпью аргументов: ssh всё равно
    /// склеил бы их через пробел и скормил логин-шеллу, так что кавычки безопаснее расставить самим.
    @discardableResult
    override func sh(
        _ script: String,
        stdin: Data? = nil,
        timeout: TimeInterval = 60,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> ProcResult {
        guard state.isConnected else { throw SSHError.notConnected }
        return try await Proc.run(
            "/usr/bin/ssh",
            [
                "-S", socketPath,
                "-o", "ControlMaster=no",
                // BatchMode: если мастер вдруг умер, лучше быстро упасть, чем повесить UI
                // на скрытом запросе пароля, которого никто не увидит.
                "-o", "BatchMode=yes",
                "-T",
            ] + connectArgs + [
                host,
                "/bin/sh -c " + shq(script),
            ],
            stdin: stdin,
            timeout: timeout,
            onProgress: onProgress
        )
    }

    // shOK общий для всех транспортов — он в Connection.
}

/// Копилка stderr мастера: читается на фоновом потоке, поэтому под замком.
private final class ErrBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ d: Data) {
        lock.lock(); data.append(d); lock.unlock()
    }
    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
