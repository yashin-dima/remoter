import Foundation

/// Поиск по СОДЕРЖИМОМУ файлов проекта — на сервере (или в локальной папке), где файлы и лежат.
///
/// «Помню, что где-то было `retry_count`» — обычный вопрос к проекту, и отвечать на него
/// перекачиванием репозитория на Mac глупо: grep на месте отвечает за доли секунды.
///
/// В git-репозитории ищет `git grep`: он сам не лезет в .git и не читает бинарники, а с
/// `--untracked` видит и ещё не закоммиченные файлы. Без репозитория — обычный `grep -r`.
enum RemoteSearch {

    struct Hit: Identifiable, Equatable {
        /// Путь относительно места поиска.
        let path: String
        let line: Int
        let text: String

        var id: String { "\(path):\(line)" }
    }

    /// Больше результатов человек всё равно не читает — он уточняет запрос. Обрезаем на
    /// сервере (`head`), а не у себя: гнать мегабайты совпадений по ssh, чтобы выкинуть, глупо.
    static let maxHits = 300
    /// Строки-простыни (минифицированный js) обрезаются: в списке от них один шум.
    static let maxLineLength = 200

    /// Ищет `query` как обычный текст (не regex: сюрпризы от нечаянной `.` в запросе хуже,
    /// чем отсутствие regex). Пустые `dir`/`exclude` — искать везде.
    static func search(
        conn: Connection,
        root: String,
        query: String,
        dir: String = "",
        exclude: String = "",
        isRepo: Bool
    ) async throws -> [Hit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        let script = isRepo
            ? gitScript(root: root, query: q, dir: dir, exclude: exclude)
            : grepScript(root: root, query: q, dir: dir, exclude: exclude)

        let r = try await conn.sh(script, timeout: 60)
        try Connection.transportCheck(r)
        // Код 1 у grep — «ничего не нашлось», это не ошибка.
        guard r.ok || r.code == 1 else {
            throw Connection.ConnectionError.remote(r.err, r.code)
        }
        return parse(r.text)
    }

    /// `git grep`: NUL после пути (-z) — двоеточия в именах файлов не ломают разбор.
    private static func gitScript(root: String, query: String, dir: String, exclude: String) -> String {
        var pathspec: [String] = []
        if !dir.isEmpty { pathspec.append(dir) }
        // `:(exclude)` — штатный способ git сказать «только не здесь».
        for ex in excludeList(exclude) { pathspec.append(":(exclude)\(ex)") }

        let spec = pathspec.isEmpty ? "" : " -- " + pathspec.map(shq).joined(separator: " ")
        return "cd \(shq(root)) && git grep -nIz --untracked -F -e \(shq(query))\(spec)"
            + " 2>/dev/null | head -n \(maxHits)"
    }

    /// Без репозитория: `grep -rnI`. `--exclude-dir` понимают и GNU, и BSD grep.
    private static func grepScript(root: String, query: String, dir: String, exclude: String) -> String {
        let base = dir.isEmpty ? "." : dir
        var flags = ["-rnI", "--exclude-dir=.git"]
        for ex in excludeList(exclude) { flags.append("--exclude-dir=\(shq(ex))") }

        return "cd \(shq(root)) && grep \(flags.joined(separator: " ")) -F -e \(shq(query))"
            + " -- \(shq(base)) 2>/dev/null | head -n \(maxHits)"
    }

    /// «node_modules, dist» → две папки. Разделители — запятая или пробел, как напишется.
    static func excludeList(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Разбор вывода. Формат двоякий, и это нормально:
    /// - `git grep -z`: `путь\0строка\0текст` — NUL и после пути, и после номера
    ///   (проверено на живом git, а не по памяти: сначала разбор ждал `:` и терял всё);
    /// - `grep`:        `путь:строка:текст` (двоеточие в пути здесь редкость, принимаем риск).
    static func parse(_ out: String) -> [Hit] {
        out.split(separator: "\n").compactMap { raw in
            let line = String(raw)

            let path: String
            let number: Int
            let rawText: String

            if line.contains("\0") {
                let parts = line.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, let n = Int(parts[1]) else { return nil }
                path = String(parts[0])
                number = n
                rawText = String(parts[2])
            } else {
                guard let colon1 = line.firstIndex(of: ":") else { return nil }
                let rest = String(line[line.index(after: colon1)...])
                guard let colon2 = rest.firstIndex(of: ":"),
                      let n = Int(rest[..<colon2]) else { return nil }
                path = String(line[..<colon1])
                number = n
                rawText = String(rest[rest.index(after: colon2)...])
            }

            var text = rawText.trimmingCharacters(in: .whitespaces)
            if text.count > maxLineLength {
                text = String(text.prefix(maxLineLength)) + "…"
            }
            // grep -r по "." даёт пути вида "./src/app.py" — точка тут не информация.
            let clean = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
            return Hit(path: clean, line: number, text: text)
        }
    }
}
