import Foundation

/// Прошлые разговоры с Claude по этому проекту.
///
/// Claude Code сам ведёт журнал: `~/.claude/projects/<каталог>/<id сессии>.jsonl`, по файлу
/// на сессию. Мы этот журнал только ЧИТАЕМ — ничего не пишем и не удаляем. Формат чужой,
/// поэтому разбор нарочно нетребовательный: не нашли поле — показываем, что нашли, и не падаем.
///
/// Возобновляется сессия штатным `claude --resume <id>`.
struct ClaudeSession: Identifiable, Hashable {
    /// Он же имя файла, он же аргумент для `--resume`.
    let id: String
    let title: String
    /// О чём говорили последний раз — вторая строка в списке.
    let lastPrompt: String
    let updated: Date
    let messages: Int

    var subtitle: String {
        lastPrompt.isEmpty ? "\(messages) сообщений" : lastPrompt
    }
}

enum ClaudeSessions {

    /// Где Claude Code держит свои данные. Обычно `~/.claude`, но он сам умеет слушать
    /// `CLAUDE_CONFIG_DIR` — значит, и мы обязаны: иначе у тех, кто эту переменную задал,
    /// список сессий оказался бы пустым без всякого объяснения.
    static var configDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    /// Журнал сессий для рабочего каталога.
    ///
    /// Имя каталога Claude собирает из пути, заменяя `/` и `.` на `-`. Правило не документировано,
    /// поэтому если угаданный каталог не нашёлся — ищем честно: по полю `cwd` внутри самих файлов.
    static func directory(for cwd: String) -> URL? {
        let root = configDirectory.appendingPathComponent("projects", isDirectory: true)

        let encoded = String(cwd.map { ($0 == "/" || $0 == ".") ? "-" : $0 })
        let guess = root.appendingPathComponent(encoded, isDirectory: true)
        if FileManager.default.fileExists(atPath: guess.path) { return guess }

        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )) ?? []
        return dirs.first { dir in
            guard let file = journals(in: dir).first else { return false }
            return firstCWD(of: file) == cwd
        }
    }

    /// Список сессий, свежие сверху.
    static func list(for cwd: String) -> [ClaudeSession] {
        guard !cwd.isEmpty, let dir = directory(for: cwd) else { return [] }
        return list(in: dir)
    }

    /// Разбор журнала идёт по строкам и без загрузки файла в память: журнал одной долгой сессии
    /// легко перевалит за десяток мегабайт.
    static func list(in dir: URL) -> [ClaudeSession] {
        journals(in: dir)
            .compactMap(session(from:))
            .sorted { $0.updated > $1.updated }
    }

    /// Название конкретной сессии по пути к её журналу.
    ///
    /// Путь приезжает прямо в хуке (`transcript_path`), так что искать каталог не нужно.
    /// Нужно это уведомлениям: «Claude закончил работу» без указания, в каком именно разговоре,
    /// бесполезно, когда открыто несколько проектов.
    static func title(ofJournal path: String) -> String? {
        guard !path.isEmpty else { return nil }
        return session(from: URL(fileURLWithPath: path))?.title
    }

    // MARK: - Разбор

    private static func journals(in dir: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return files.filter { $0.pathExtension == "jsonl" }
    }

    private static func session(from file: URL) -> ClaudeSession? {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }

        var title = ""
        var lastPrompt = ""
        var messages = 0

        // Строк в журнале тысячи, и почти каждая — большой JSON с содержимым сообщения.
        // Разбирать их все было бы расточительно, поэтому сначала дешёвая проверка на подстроку,
        // и только совпавшие строки уходят в JSONDecoder.
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            // Сайдчейны — переписка подагентов, а не разговор: считать их сообщениями значит
            // показать «120 сообщений» там, где человек написал десять.
            if contains(line, sidechainMarker) { continue }

            if contains(line, aiTitleMarker) {
                title = decode(line)?.aiTitle ?? title
            } else if contains(line, lastPromptMarker) {
                lastPrompt = decode(line)?.lastPrompt ?? lastPrompt
            } else if contains(line, userMarker) || contains(line, assistantMarker) {
                messages += 1
            }
        }

        // Заголовок Claude придумывает не сразу: у совсем свежей сессии его ещё нет.
        // Тогда лучше показать, с чего разговор начался, чем «Без названия».
        let shown = title.isEmpty
            ? (lastPrompt.isEmpty ? "Новая сессия" : lastPrompt)
            : title

        let updated = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast

        return ClaudeSession(
            id: file.deletingPathExtension().lastPathComponent,
            title: single(shown),
            lastPrompt: title.isEmpty ? "" : single(lastPrompt),
            updated: updated,
            messages: messages
        )
    }

    /// Первый `cwd` из журнала — им опознаётся каталог, когда угадать имя не вышло.
    private static func firstCWD(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file),
              let head = try? handle.read(upToCount: 64 * 1024)
        else { return nil }
        try? handle.close()

        for line in head.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            if let cwd = decode(line)?.cwd { return cwd }
        }
        return nil
    }

    // MARK: - Мелочи

    private struct Line: Decodable {
        let aiTitle: String?
        let lastPrompt: String?
        let cwd: String?
    }

    private static let aiTitleMarker = Array(#""type":"ai-title""#.utf8)
    private static let lastPromptMarker = Array(#""type":"last-prompt""#.utf8)
    private static let userMarker = Array(#""type":"user""#.utf8)
    private static let assistantMarker = Array(#""type":"assistant""#.utf8)
    private static let sidechainMarker = Array(#""isSidechain":true"#.utf8)

    private static func contains(_ line: Data, _ needle: [UInt8]) -> Bool {
        guard line.count >= needle.count else { return false }
        return line.firstRange(of: needle) != nil
    }

    private static func decode(_ line: Data) -> Line? {
        try? JSONDecoder().decode(Line.self, from: line)
    }

    /// Промпт бывает многострочным — в строку списка должна попасть одна строка, а не абзац.
    private static func single(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
