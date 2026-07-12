import Foundation

/// Что у сессии Claude **на самом деле** — в отличие от того, с чем её запустили.
///
/// Разница не теоретическая. Модель меняют `/model`, уровень reasoning — `/effort`, режим
/// разрешений — shift+tab. Всё это происходит уже внутри работающего Claude, и флаги запуска
/// после этого врут. Плашка, показывающая флаги, — врёт вместе с ними.
///
/// Узнать правду можно там же, где Claude ведёт свой журнал: он записывает туда и смену режима,
/// и модель каждого ответа, и сами набранные команды. Мы этот журнал только читаем.
struct ClaudeLive: Equatable {
    /// Модель, которой отвечает Claude прямо сейчас: «Opus 4.8».
    var model: String?
    var effort: ClaudeEffort?
    var permissions: ClaudePermissions?
    /// Название разговора, которое Claude придумывает сам, — им подписывается вкладка.
    var title: String?

    /// Id сессии — он же имя файла журнала. По нему события хуков находят свою вкладку.
    var sessionID: String?

    /// Сколько токенов занято в контексте. Считается по последнему ответу Claude: там лежит
    /// весь его вход (включая прочитанное из кэша) и выход — то есть ровно то, что сейчас
    /// занимает окно.
    var contextTokens: Int?

    /// Алиас модели ровно в том виде, в каком его назвали в `/model` внутри сессии: `opus[1m]`,
    /// `sonnet`, `claude-fable-5`. Отдельно от `model` (там человеческое имя), потому что размер
    /// окна виден ТОЛЬКО здесь: `[1m]` — это просьба о миллионе, а в id модели её следа нет.
    ///
    /// Без этого кольцо врало после смены модели на ходу: запустили сессию с `opus[1m]`, набрали
    /// внутри `/model sonnet` — окно стало 200k, а приложение продолжало делить на миллион
    /// и показывало 12% там, где занято 60%. Молчать о подходящем к концу контексте — ровно то,
    /// от чего кольцо и должно спасать.
    var modelAlias: String?
}

/// Сессия, за журналом которой мы следим.
struct SessionProbe: Equatable {
    let id: UUID
    /// Журнал ещё не найден, пока Claude его не создал.
    var journal: URL?
    /// Сколько байт журнала уже прочитано: при опросе дочитываем только хвост, а не файл целиком.
    var offset: UInt64 = 0
    var live = ClaudeLive()
    /// Когда сессию запустили — по этому времени и опознаётся её журнал среди чужих.
    let startedAt: Date
    /// Продолжённый разговор: его журнал известен сразу, искать нечего.
    let resumed: String?
}

/// Чтение журнала Claude по мере того, как он пишется.
enum ClaudeJournal {

    /// Дочитывает журналы всех сессий и возвращает их обновлённое состояние.
    ///
    /// Файл журнала растёт, поэтому каждый опрос читает только НОВЫЕ байты: у долгого разговора
    /// журнал переваливает за десяток мегабайт, и перечитывать его раз в полторы секунды было бы
    /// расточительством на ровном месте.
    static func follow(in dir: URL, probes: [SessionProbe]) -> [SessionProbe] {
        var claimed = Set(probes.compactMap { $0.journal?.path })
        var probes = probes

        // Журналы раздаются в два прохода: сначала сессиям, у которых файла ещё нет вовсе,
        // потом — возобновлённым, ждущим свой «настоящий» журнал (см. journal(in:for:)).
        // Возобновлённая уже сидит на старом файле, ей не горит; жадный захват в один проход
        // мог бы отнять свежий журнал у только что открытой новой вкладки.
        for onlyUnassigned in [true, false] {
            for i in probes.indices where (probes[i].journal == nil) == onlyUnassigned {
                guard let found = journal(in: dir, for: probes[i], claimed: claimed),
                      found != probes[i].journal else { continue }
                // Журнал сменился — всё прочитанное относилось к старому: начинаем с нуля.
                probes[i].journal = found
                probes[i].offset = 0
                probes[i].live = ClaudeLive()
                claimed.insert(found.path)
            }
        }

        return probes.map { probe in
            var probe = probe
            guard let journal = probe.journal else { return probe }
            probe.live.sessionID = journal.deletingPathExtension().lastPathComponent
            read(journal, into: &probe)
            return probe
        }
    }

    /// Какой из журналов принадлежит этой сессии сейчас.
    ///
    /// Новая сессия придумывает id сама и нам его не сообщает: узнать его можно только по
    /// факту — журнал, который появился в каталоге ПОСЛЕ её запуска и не занят другой вкладкой.
    ///
    /// Возобновлённая хитрее, чем кажется: `--resume <id>` не дописывает старый `<id>.jsonl`,
    /// а заводит НОВУЮ сессию с новым id и новым файлом. Старый журнал годится, чтобы сразу
    /// показать состояние (в нём вся история разговора), но как только новый файл появился —
    /// переходим на него: иначе плашка застынет на прошлом, а хуки busy будут искать вкладку
    /// по мёртвому id.
    private static func journal(in dir: URL, for probe: SessionProbe, claimed: Set<String>) -> URL? {
        // На «настоящем» журнале (имя не совпадает со старым id) — с него не слезаем.
        if let current = probe.journal,
           current.deletingPathExtension().lastPathComponent != probe.resumed {
            return current
        }

        if let fresh = newJournal(in: dir, after: probe.startedAt, claimed: claimed) {
            return fresh
        }

        // Возобновлённая, пока Claude не создал новый файл: читаем историю из старого.
        if probe.journal == nil, let resumed = probe.resumed {
            let file = dir.appendingPathComponent(resumed + ".jsonl")
            if FileManager.default.fileExists(atPath: file.path), !claimed.contains(file.path) {
                return file
            }
        }
        return probe.journal
    }

    /// Журнал, появившийся после запуска сессии и не занятый другой вкладкой.
    ///
    /// Допуск нарочно асимметричный: файл, созданный ДО запуска, нашим быть не может — часы
    /// у нас и у файловой системы одни (это один Mac), а «запас на всякий случай» в прошлое
    /// и есть способ присвоить себе журнал соседней сессии.
    private static func newJournal(in dir: URL, after startedAt: Date, claimed: Set<String>) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]
        )) ?? []

        return files
            .filter { $0.pathExtension == "jsonl" && !claimed.contains($0.path) }
            .compactMap { url -> (URL, Date)? in
                guard let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?
                    .creationDate else { return nil }
                guard created > startedAt else { return nil }
                return (url, created)
            }
            .min { $0.1 < $1.1 }?
            .0
    }

    /// Дочитывает хвост журнала и обновляет состояние сессии.
    private static func read(_ file: URL, into probe: inout SessionProbe) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0

        // Журнал не сокращается — а если сократился, значит это уже другой файл под тем же именем.
        // Тогда честнее перечитать его с начала, чем разбирать середину строки.
        if size < probe.offset {
            probe.offset = 0
            probe.live = ClaudeLive()
        }
        guard size > probe.offset else { return }

        try? handle.seek(toOffset: probe.offset)
        guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else { return }

        // Последняя строка может быть недописана — Claude пишет журнал прямо сейчас. Разбираем
        // только то, что заведомо дописано до перевода строки, остальное дочитаем в следующий раз.
        guard let lastNewline = chunk.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = chunk[chunk.startIndex...lastNewline]
        probe.offset += UInt64(complete.count)

        for line in complete.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            apply(line, to: &probe.live)
        }
    }

    /// Разбор одной записи журнала. Формат чужой, поэтому сначала дешёвая проверка на подстроку,
    /// и только совпавшие строки уходят в JSONDecoder: строк тысячи, и почти каждая — большой JSON.
    private static func apply(_ line: Data, to live: inout ClaudeLive) {
        // Сайдчейны — реплики подагентов. У них своя модель и свой контекст: возьми мы usage
        // оттуда, кольцо контекста прыгало бы на цифры субагента, а плашка — на его модель.
        if contains(line, sidechainMarker) { return }

        if contains(line, permissionMarker), let value = decode(line)?.permissionMode {
            live.permissions = ClaudePermissions(rawValue: value) ?? live.permissions

        } else if contains(line, titleMarker), let value = decode(line)?.aiTitle {
            live.title = value

        } else if contains(line, assistantMarker), let message = decode(line)?.message {
            if let value = message.model {
                live.model = modelName(fromID: value)
            }
            // Занятый контекст — это весь вход последнего ответа (включая то, что Claude прочитал
            // из кэша: в окне оно занимает место наравне с остальным) плюс его выход.
            if let usage = message.usage, let used = usage.contextTokens {
                live.contextTokens = used
            }

        } else if contains(line, commandMarker), let text = decode(line)?.message?.text {
            // `/effort xhigh` и `/model opus` Claude записывает в журнал как обычную реплику
            // пользователя, обёрнутую в теги команды. Другого следа они не оставляют: effort
            // не попадает ни в одну запись журнала, а модель — только в СЛЕДУЮЩИЙ ответ Claude.
            switch commandName(in: text) {
            case "/effort":
                if let arg = commandArgs(in: text), let effort = ClaudeEffort(rawValue: arg) {
                    live.effort = effort
                }
            case "/model":
                if let arg = commandArgs(in: text) {
                    // `[1m]` — просьба о длинном окне, не часть имени. А алиас, которого нет
                    // в нашем списке (`opus[1m]` целиком, полный id вроде `claude-fable-5`),
                    // не повод промолчать: имя собирается из самого id.
                    let bare = arg.hasSuffix(ClaudeConfig.longContextSuffix)
                        ? String(arg.dropLast(ClaudeConfig.longContextSuffix.count))
                        : arg
                    live.model = ClaudeModel(rawValue: bare)?.title ?? modelName(fromID: bare)
                    // Алиас целиком — по нему считается размер окна, и `[1m]` виден только здесь.
                    live.modelAlias = arg
                }
            default:
                break
            }
        }
    }

    /// `claude-opus-4-8` → `Opus 4.8`, `claude-haiku-4-5-20251001` → `Haiku 4.5`.
    ///
    /// Собираем имя из самого id, а не сверяемся со списком известных: список устареет с первой же
    /// новой моделью, и приложение станет показывать «Opus 4.8» там, где работает Opus 4.9.
    static func modelName(fromID id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        // Хвостовая дата в id (20251001) — не часть названия модели.
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        guard let family = parts.first, !family.isEmpty else { return id }

        let version = parts.dropFirst().joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version)"
    }

    // MARK: - Мелочи

    private struct Line: Decodable {
        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheReadInputTokens: Int?
            let cacheCreationInputTokens: Int?

            /// Сколько занято в окне. Кэш здесь не бесплатный: прочитанное из кэша занимает
            /// столько же места, сколько занимало бы обычным входом, — просто дешевле стоит.
            var contextTokens: Int? {
                let total = (inputTokens ?? 0) + (outputTokens ?? 0)
                    + (cacheReadInputTokens ?? 0) + (cacheCreationInputTokens ?? 0)
                return total > 0 ? total : nil
            }

            private enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
            }
        }

        struct Message: Decodable {
            let model: String?
            let usage: Usage?
            /// У реплики пользователя content — строка, у ответа Claude — массив блоков.
            /// Нас интересует только первый случай, поэтому второй молча пропускаем.
            let text: String?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                model = try? c.decodeIfPresent(String.self, forKey: .model)
                usage = try? c.decodeIfPresent(Usage.self, forKey: .usage)
                text = try? c.decodeIfPresent(String.self, forKey: .content)
            }

            private enum CodingKeys: String, CodingKey { case model, content, usage }
        }

        let permissionMode: String?
        let aiTitle: String?
        let message: Message?
    }

    private static let permissionMarker = Array(#""type":"permission-mode""#.utf8)
    private static let titleMarker = Array(#""type":"ai-title""#.utf8)
    private static let assistantMarker = Array(#""type":"assistant""#.utf8)
    private static let commandMarker = Array("<command-name>".utf8)
    private static let sidechainMarker = Array(#""isSidechain":true"#.utf8)

    private static func commandName(in text: String) -> String? {
        tag("command-name", in: text)
    }

    private static func commandArgs(in text: String) -> String? {
        tag("command-args", in: text)?.split(separator: " ").first.map(String.init)
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func contains(_ line: Data, _ needle: [UInt8]) -> Bool {
        guard line.count >= needle.count else { return false }
        return line.firstRange(of: needle) != nil
    }

    private static func decode(_ line: Data) -> Line? {
        try? JSONDecoder().decode(Line.self, from: line)
    }
}
