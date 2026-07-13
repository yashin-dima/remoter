import Foundation

/// Проект на удалённом сервере. `host` — то, что понимает системный ssh:
/// алиас из ~/.ssh/config, `user@example.com`, что угодно.
///
/// `port` нужен, только если сервер слушает не на 22 и для него нет алиаса в ssh config.
///
/// `sshOptions` — запасной выход на случай, когда ssh config не подходит: свой ключ (`-i ...`),
/// прыжок через бастион (`-J bastion`), нестандартные `-o`. В обычной жизни поле пустое.
struct Workspace: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var host: String
    var path: String
    var port: Int?
    var sshOptions: String?

    /// Проект лежит на этом же Mac — ssh не нужен вовсе.
    ///
    /// Тогда `host` пуст, а `path` — обычная папка на диске. Всё остальное приложение об этом
    /// не знает и знать не должно: команды всё так же уходят в `Connection.sh`, просто исполняет
    /// их `/bin/sh` здесь, а не ssh на сервере (см. Connection).
    var isLocal: Bool = false

    /// Компания, для которой делается проект. Ею список и разбит на разделы: проектов много,
    /// и держать в голове, чей из них какой, — лишняя работа.
    ///
    /// Необязательное поле, и это важно: в уже сохранённых проектах его просто нет, а терять
    /// их из-за нового поля недопустимо.
    var company: String?

    /// Пусто — не повод прятать проект. Он просто попадает в общий раздел.
    static let noCompany = "Без компании"

    var companyOrDefault: String {
        let c = (company ?? "").trimmingCharacters(in: .whitespaces)
        return c.isEmpty ? Self.noCompany : c
    }

    /// Строка, по которой ищут. Искать только по названию мало: помнишь сервер или путь,
    /// а не то, как ты этот проект однажды назвал.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }

        return [name, host, path, company ?? ""].contains {
            $0.localizedCaseInsensitiveContains(q)
        }
    }

    /// Только чтение: приложение не выполнит на сервере ни одной изменяющей команды —
    /// ни записи файла, ни git-операции. Смотреть diff и код можно, испортить что-либо — нет.
    var readOnly: Bool = false

    init(id: UUID = UUID(), name: String, host: String = "", path: String, port: Int? = nil,
         sshOptions: String? = nil, isLocal: Bool = false, company: String? = nil,
         readOnly: Bool = false) {
        self.id = id
        self.name = name
        self.host = host
        self.path = path
        self.port = port
        self.sshOptions = sshOptions
        self.isLocal = isLocal
        self.company = company
        self.readOnly = readOnly
    }

    /// Разбор списка проектов пишется руками, а не синтезируется, ровно по одной причине:
    /// синтезированный декодер падает на КАЖДОМ поле, которого в файле ещё нет. Список писался
    /// прошлыми версиями приложения — там нет ни `isLocal`, ни `readOnly`, — и «строгий» разбор
    /// означал бы «проекты пропали после обновления». Отсутствующее поле — это значение
    /// по умолчанию, а не ошибка.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        path = try c.decode(String.self, forKey: .path)
        port = try c.decodeIfPresent(Int.self, forKey: .port)
        sshOptions = try c.decodeIfPresent(String.self, forKey: .sshOptions)
        isLocal = try c.decodeIfPresent(Bool.self, forKey: .isLocal) ?? false
        company = try c.decodeIfPresent(String.self, forKey: .company)
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
    }

    var subtitle: String {
        // У локального проекта нет ни хоста, ни порта — показывать «· путь» с пустотой слева
        // некрасиво и бессмысленно.
        guard !isLocal else { return path }
        let hostPart = port.map { "\(host):\($0)" } ?? host
        return "\(hostPart) · \(path)"
    }

    /// Опции разбираем как командную строку, а не просто по пробелам: у ключа бывает путь
    /// с пробелом (`-i '/Users/me/My Keys/id_ed25519'`), и наивный split разломал бы его
    /// на куски — ssh получил бы половину пути и хост из второй половины.
    var extraSSHArgs: [String] {
        Self.splitCommandLine(sshOptions ?? "")
    }

    /// Мини-shlex: пробелы разделяют аргументы, одинарные и двойные кавычки склеивают,
    /// `\\` экранирует следующий символ (вне одинарных кавычек — как в POSIX-шелле).
    /// Незакрытая кавычка не роняет разбор: хвост просто уходит в последний аргумент —
    /// ssh сам скажет, что аргумент странный, а вот молча потерять его нельзя.
    static func splitCommandLine(_ s: String) -> [String] {
        var args: [String] = []
        var current = ""
        var started = false          // отличаем '' (пустой аргумент в кавычках) от «ничего не набрано»
        var quote: Character?
        var escaped = false

        for ch in s {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if let q = quote {
                if ch == q {
                    quote = nil
                } else if ch == "\\", q == "\"" {
                    // Внутри двойных кавычек бэкслеш экранирует; внутри одинарных — обычный
                    // символ, как в POSIX.
                    escaped = true
                } else {
                    current.append(ch)
                }
                continue
            }
            switch ch {
            case "\\":
                escaped = true
                started = true
            case "'", "\"":
                quote = ch
                started = true
            case " ", "\t":
                if started {
                    args.append(current)
                    current = ""
                    started = false
                }
            default:
                current.append(ch)
                started = true
            }
        }
        if escaped { current.append("\\") } // висячий бэкслеш — оставляем как есть
        // Незакрытая кавычка не роняет разбор: хвост уходит в последний аргумент —
        // ssh сам скажет, что аргумент странный, а вот молча потерять его нельзя.
        if started { args.append(current) }
        return args
    }
}

/// Список проектов. Единственное, что приложение хранит на диске, — и потерять его нельзя:
/// это адреса серверов, пути и настройки доступа, набранные руками.
///
/// Поэтому здесь три предохранителя, каждый против своей причины пропажи:
///
/// 1. **Отдельная полка для тестов и отладки.** Путь к файлу берётся из `REMOTER_STORE`, если
///    переменная задана. Без этого любой прогон приложения «на попробовать» лез бы в тот же
///    файл, где лежат настоящие проекты, — и уборка после такого прогона стирала бы их.
/// 2. **Резервная копия.** Перед каждой перезаписью прежнее содержимое уезжает в `.backup`.
///    Если основной файл окажется битым или исчезнет — список поднимется из копии.
/// 3. **Перечитывание перед записью.** Изменение вносится в то, что сейчас НА ДИСКЕ, а не в то,
///    что мы прочли при запуске. Иначе вторая копия приложения, открытая рядом, затирала бы
///    своим устаревшим списком всё, что добавила первая.
@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var workspaces: [Workspace] = []

    /// Последняя ошибка сохранения списка. nil — всё записалось. Диск полон или права
    /// отвалились — правка живёт только в памяти и пропадёт с перезапуском; молчать об этом
    /// нельзя, UI может показать это поле как есть.
    @Published private(set) var lastSaveError: String?

    private let fileURL: URL
    private var backupURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("workspaces.backup.json")
    }

    /// `REMOTER_STORE` — путь к своему файлу списка. Тесты и отладочные запуски задают его,
    /// чтобы физически не иметь доступа к настоящим проектам пользователя.
    static func defaultURL() -> URL {
        if let custom = ProcessInfo.processInfo.environment["REMOTER_STORE"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        // Тест без REMOTER_STORE не должен даже видеть настоящий список проектов — не то что
        // писать в него: ровно так он однажды и пропал. См. TestIsolation.
        return TestIsolation.path("store") {
            FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Remoter", isDirectory: true)
        }
        .appendingPathComponent("workspaces.json")
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL()
        try? FileManager.default.createDirectory(
            at: self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        adoptListFromPreviousName()
        load()
    }

    /// Приложение раньше звалось SSHDiff, и список проектов лежал в папке с тем именем.
    /// Переименование не повод потерять адреса серверов, набранные руками.
    ///
    /// Список именно КОПИРУЕТСЯ, а не переносится: старый файл остаётся лежать нетронутым.
    /// Стоит он ничего, а если в переносе что-то пойдёт не так — из него всё поднимется.
    private func adoptListFromPreviousName() {
        // Только для настоящего хранилища. Тест или отладочный запуск, которому подменили путь,
        // не должен даже читать настоящий список — не говоря о том, чтобы затянуть его к себе.
        let overridden = ProcessInfo.processInfo.environment["REMOTER_STORE"]?.isEmpty == false
        guard !overridden, fileURL == Self.defaultURL() else { return }

        let fm = FileManager.default
        guard !fm.fileExists(atPath: fileURL.path) else { return }

        let old = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SSHDiff", isDirectory: true)
            .appendingPathComponent("workspaces.json")
        guard fm.fileExists(atPath: old.path) else { return }

        try? fm.copyItem(at: old, to: fileURL)
    }

    func workspace(id: UUID?) -> Workspace? {
        guard let id else { return nil }
        return workspaces.first { $0.id == id }
    }

    /// Компании, которые уже встречались, — чтобы в форме проекта их можно было выбрать,
    /// а не набирать заново (и не разводить «Acme» и «acme» как две разные).
    var companies: [String] {
        let all = workspaces.compactMap { $0.company?.trimmingCharacters(in: .whitespaces) }
        return Array(Set(all.filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Раздел списка: компания и её проекты.
    struct Section: Identifiable, Equatable {
        var id: String { company }
        let company: String
        let items: [Workspace]
    }

    /// Список, разбитый по компаниям и отфильтрованный поиском.
    ///
    /// «Без компании» всегда внизу: это не компания, а её отсутствие, и стоять первой в алфавите
    /// у неё оснований нет. Пустые после фильтрации разделы исчезают — иначе поиск показывал бы
    /// заголовки без единого проекта под ними.
    func sections(matching query: String = "") -> [Section] {
        let found = workspaces.filter { $0.matches(query) }

        return Dictionary(grouping: found, by: \.companyOrDefault)
            .map { Section(company: $0.key, items: $0.value.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }) }
            .sorted { a, b in
                if a.company == Workspace.noCompany { return false }
                if b.company == Workspace.noCompany { return true }
                return a.company.localizedStandardCompare(b.company) == .orderedAscending
            }
    }

    func add(_ w: Workspace) {
        mutate { $0.append(w) }
    }

    func update(_ w: Workspace) {
        mutate {
            guard let i = $0.firstIndex(where: { $0.id == w.id }) else { return }
            $0[i] = w
        }
    }

    func remove(_ w: Workspace) {
        mutate { $0.removeAll { $0.id == w.id } }
        // Иконку проекта тоже забываем: держать картинку удалённого проекта незачем.
        ProjectIcon.forget(w.id)
    }

    /// Правку вносим в диск, а не в память: пока это окно было открыто, список мог измениться.
    private func mutate(_ change: (inout [Workspace]) -> Void) {
        var list = decode(fileURL) ?? workspaces
        change(&list)
        workspaces = list
        save()
    }

    private func load() {
        if let list = decode(fileURL) {
            workspaces = list
            return
        }
        // Основного файла нет или он не читается. Резервная копия здесь — не роскошь: пустой
        // список молча уехал бы на диск при первом же сохранении и добил бы то, что осталось.
        if let list = decode(backupURL), !list.isEmpty {
            workspaces = list
            save()
        }
    }

    private func decode(_ url: URL) -> [Workspace]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([Workspace].self, from: data)
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try enc.encode(workspaces)
            try data.write(to: fileURL, options: .atomic)

            // Копия снимается ПОСЛЕ записи и только если записанное читается. Тогда она всегда
            // равна последнему заведомо целому состоянию. Снимай мы её до записи — она отставала бы
            // на один шаг, и восстановление возвращало бы список без самого свежего проекта.
            if decode(fileURL) != nil {
                try? data.write(to: backupURL, options: .atomic)
            }
            lastSaveError = nil
        } catch {
            // Глотать это молча нельзя: правка осталась только в памяти и пропадёт
            // с перезапуском. В лог — для отладки, в published-поле — для UI.
            NSLog("Remoter: не удалось сохранить список проектов в %@: %@",
                  fileURL.path, error.localizedDescription)
            lastSaveError = error.localizedDescription
        }
    }
}
