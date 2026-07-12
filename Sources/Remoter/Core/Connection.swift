import Foundation

/// Канал, по которому выполняются команды проекта.
///
/// Весь остальной код — дерево файлов, git, diff, чтение и запись — разговаривает с проектом
/// ровно одним способом: отдаёт POSIX-скрипт в `sh(...)` и получает stdout/stderr/код. Больше он
/// про транспорт не знает НИЧЕГО. Поэтому проект на сервере и проект на этом же Mac отличаются
/// только тем, кто эти скрипты исполняет:
///
/// - `SSHConnection` — системный ssh через мультиплексор;
/// - `LocalConnection` — `/bin/sh` прямо здесь.
///
/// Абстракция сделана классом, а не протоколом, сознательно: `conn` живёт в SwiftUI как
/// `ObservableObject` (бейдж соединения подписан на `state`), а протокол с `@Published`
/// пришлось бы заворачивать в стирание типа — кода больше, пользы ноль.
@MainActor
class Connection: ObservableObject {

    enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)

        var isConnected: Bool { self == .connected }
    }

    enum ConnectionError: LocalizedError {
        case notConnected
        case remote(String, Int32)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Нет соединения с сервером"
            case .remote(let msg, let code): return msg.isEmpty ? "Команда вернула \(code)" : msg
            case .transport(let msg):
                return msg.isEmpty ? "Связь с сервером потеряна" : "Связь с сервером потеряна: \(msg)"
            }
        }
    }

    /// Состояние меняют только сами транспорты — они в этом же модуле. `private(set)` здесь
    /// не годится: наследники живут в других файлах, и писать бы не смогли.
    @Published var state: State = .idle

    /// Выполняет POSIX-скрипт. Единственная точка, через которую код общается с проектом.
    func sh(
        _ script: String,
        stdin: Data? = nil,
        timeout: TimeInterval = 60,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> ProcResult {
        fatalError("Connection.sh обязан быть переопределён")
    }

    /// То же, но неуспешный код — это ошибка.
    @discardableResult
    final func shOK(
        _ script: String,
        stdin: Data? = nil,
        timeout: TimeInterval = 60,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> ProcResult {
        let r = try await sh(script, stdin: stdin, timeout: timeout, onProgress: onProgress)
        guard r.ok else {
            throw ConnectionError.remote(r.err.trimmingCharacters(in: .whitespacesAndNewlines), r.code)
        }
        return r
    }

    /// ssh резервирует код 255 под свои ошибки (обрыв канала, умерший мастер). Это НЕ ответ
    /// команды: «файла нет» и «связь упала» — разные события, и молча путать их нельзя, иначе
    /// обрыв выглядит как пустой diff или пропавший файл. У локального канала такого кода нет
    /// и быть не может — проверка просто ничего не находит.
    nonisolated static func transportCheck(_ r: ProcResult) throws {
        guard r.code == 255 else { return }
        throw ConnectionError.transport(r.err.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func connect() async {}
    func disconnect() {}

    /// Аргументы для терминала. У ssh это `-S <сокет> … host`, у локального — пусто.
    var terminalLaunch: TerminalLaunch { .localShell }
}

/// Как запускать терминал этого проекта. Терминал — единственное место, где транспорт всё-таки
/// виден снаружи: SwiftTerm запускает процесс сам, и ему нужно сказать, какой именно.
enum TerminalLaunch: Equatable {
    /// Шелл прямо здесь — проект лежит на этом Mac.
    case localShell
    /// ssh на сервер через уже открытый мультиплексор.
    case ssh(socket: String, host: String, args: [String])
}

/// Проект на этом же Mac: те же самые скрипты, только исполняет их `/bin/sh` локально.
///
/// Ни ssh, ни сокета, ни ожидания соединения — поэтому и «подключаться» нечему: состояние
/// `connected` с самого начала, а `connect()`/`disconnect()` ничего не делают. Это не заглушка
/// ради галочки: остальной код проверяет `state.isConnected` перед каждой операцией, и локальный
/// проект обязан честно отвечать «связь есть».
@MainActor
final class LocalConnection: Connection {

    override init() {
        super.init()
        state = .connected
    }

    override func sh(
        _ script: String,
        stdin: Data? = nil,
        timeout: TimeInterval = 60,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> ProcResult {
        // `sh -c` — тот же интерпретатор, которому скрипт уходил бы на сервере. Скрипты пишутся
        // на POSIX sh и одинаково работают по обе стороны: в этом весь смысл единого транспорта.
        try await Proc.run(
            "/bin/sh", ["-c", script],
            stdin: stdin,
            timeout: timeout,
            onProgress: onProgress
        )
    }
}
