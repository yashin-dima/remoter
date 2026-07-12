import CryptoKit
import Foundation

/// Что случилось с файлом. Порядок важен: по нему сортируется список изменений.
enum ChangeKind: Int, Comparable {
    case conflicted = 0
    case modified = 1
    case added = 2
    case renamed = 3
    case deleted = 4
    case untracked = 5

    static func < (a: ChangeKind, b: ChangeKind) -> Bool { a.rawValue < b.rawValue }

    var letter: String {
        switch self {
        case .conflicted: return "U"
        case .modified:   return "M"
        case .added:      return "A"
        case .renamed:    return "R"
        case .deleted:    return "D"
        case .untracked:  return "?"
        }
    }

    var title: String {
        switch self {
        case .conflicted: return "Конфликт"
        case .modified:   return "Изменён"
        case .added:      return "Добавлен"
        case .renamed:    return "Переименован"
        case .deleted:    return "Удалён"
        case .untracked:  return "Новый"
        }
    }
}

/// Одна строка из `git status`.
struct GitChange: Identifiable, Equatable {
    /// Путь относительно корня репозитория.
    var path: String
    /// Прежний путь — только для переименований; именно из него надо брать версию из HEAD.
    var origPath: String?
    /// Статус в индексе (X) и в рабочей копии (Y) из porcelain v2.
    var x: Character
    var y: Character
    var kind: ChangeKind

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var dir: String { (path as NSString).deletingLastPathComponent }

    /// Файла нет в рабочей копии — правую сторону diff'а показываем пустой.
    var isDeletedInWorktree: Bool { y == "D" }
    /// Изменения целиком лежат в индексе, рабочая копия совпадает с индексом.
    var isStagedOnly: Bool { x != "." && y == "." }
    var isStaged: Bool { x != "." && x != "?" }

    /// Конфликт слияния. Такой файл не «изменён» и не «в индексе» — с ним сначала разбираются.
    var isConflicted: Bool { x == "U" || y == "U" }

    /// Что с файлом сделано В ИНДЕКСЕ. nil — в индексе его нет.
    ///
    /// Отдельно от `worktreeKind`, и это не педантизм: файл сплошь и рядом изменён и там, и там
    /// («MM»). Раньше он попадал только в раздел «В индексе», а его несохранённая правка просто
    /// не показывалась — коммит уносил не то, что было видно на экране.
    var stagedKind: ChangeKind? {
        guard !isConflicted else { return nil }
        switch x {
        case ".", "?":  return nil
        case "A":       return .added
        case "D":       return .deleted
        case "R", "C":  return .renamed
        default:        return .modified
        }
    }

    /// Что с файлом сделано В РАБОЧЕЙ КОПИИ — то, что ещё не в индексе.
    var worktreeKind: ChangeKind? {
        guard !isConflicted else { return nil }
        if x == "?" { return .untracked }
        switch y {
        case ".":  return nil
        case "D":  return .deleted
        case "A":  return .added
        default:   return .modified
        }
    }
}

struct GitStatus: Equatable {
    var branch: String?
    var ahead: Int = 0
    var behind: Int = 0
    var changes: [GitChange] = []
    /// Сырой вывод — по его хэшу поллинг понимает, изменилось ли хоть что-то.
    var fingerprint: String = ""

    static let empty = GitStatus()
}

enum Git {

    /// Корень репозитория, либо nil — тогда мы просто файловый браузер без вкладки изменений.
    /// Путь здесь — пользовательский ввод: `~` надо развернуть самим (кавычки shq его гасят),
    /// а `cd --` защищает от путей, начинающихся с дефиса.
    static func repoRoot(conn: Connection, path: String) async -> String? {
        let r = try? await conn.sh("cd -- \(shqPath(path)) && git rev-parse --show-toplevel 2>/dev/null")
        guard let r, r.ok else { return nil }
        let root = r.line
        return root.isEmpty ? nil : root
    }

    static func status(conn: Connection, root: String) async throws -> GitStatus {
        let r = try await conn.shOK(
            "git -C \(shq(root)) status --porcelain=v2 --branch --untracked-files=all -z"
        )
        var st = parse(r.out)
        // SHA-256 от всего вывода. Именно криптохэш, а не `hashValue`: тот на Darwin считается
        // по первым ~80 байтам, а вывод начинается с неизменного `# branch.oid …` — правки
        // рабочей копии меняли бы буфер дальше по тексту, отпечаток совпадал бы, и поллинг
        // молча пропускал бы изменения до следующего коммита.
        st.fingerprint = SHA256.hash(data: r.out).map { String(format: "%02x", $0) }.joined()
        return st
    }

    /// Разбор `--porcelain=v2 -z`. Формат машинный именно для того, чтобы не гадать:
    /// записи разделены NUL, так что имена файлов с пробелами, кавычками и юникодом проходят как есть.
    static func parse(_ data: Data) -> GitStatus {
        var st = GitStatus()
        // Пустые записи не выкидываем: у переименования прежнее имя лежит в соседней записи,
        // и сдвиг индексов сломал бы разбор всего, что идёт следом.
        //
        // Декодирование СТРОГОЕ: запись с именем не в UTF-8 пропускается целиком, а не
        // «чинится» заменой байтов на U+FFFD — испорченный путь дальше ушёл бы в rm/git add
        // и попал бы не в тот файл. Тип записи при этом смотрим по сырому байту: даже битую
        // «2» надо опознать, чтобы съесть её вторую NUL-запись с прежним именем.
        let raw = data.split(separator: 0, omittingEmptySubsequences: false)

        var i = 0
        while i < raw.count {
            let rec = raw[i]
            i += 1
            guard let firstByte = rec.first else { continue }
            let decoded = String(bytes: rec, encoding: .utf8)

            switch firstByte {
            case UInt8(ascii: "#"):
                // "# branch.head main", "# branch.ab +2 -1"
                guard let t = decoded else { break }
                let f = t.split(separator: " ").map(String.init)
                if f.count >= 3, f[1] == "branch.head" {
                    st.branch = f[2] == "(detached)" ? nil : f[2]
                } else if f.count >= 4, f[1] == "branch.ab" {
                    st.ahead = abs(Int(f[2]) ?? 0)
                    st.behind = abs(Int(f[3]) ?? 0)
                }

            case UInt8(ascii: "1"):
                // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
                guard let t = decoded else { break }
                let f = split(t, keeping: 8)
                guard f.count == 9, f[1].count >= 2 else { break }
                let xy = Array(f[1])
                st.changes.append(make(path: f[8], orig: nil, x: xy[0], y: xy[1]))

            case UInt8(ascii: "2"):
                // 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>\0<origPath>
                // Прежнее имя лежит в СЛЕДУЮЩЕЙ NUL-записи — её надо съесть, иначе она уедет
                // в разбор как отдельная запись и всё поедет. Съедаем и для битой записи.
                let origRaw = i < raw.count ? raw[i] : nil
                i += 1
                guard let t = decoded else { break }
                let f = split(t, keeping: 9)
                guard f.count == 10, f[1].count >= 2 else { break }
                // Прежнее имя не в UTF-8 — не повод терять запись: без origPath diff просто
                // покажет файл как новый, но сам путь останется верным.
                let orig = origRaw.flatMap { String(bytes: $0, encoding: .utf8) }
                let xy = Array(f[1])
                st.changes.append(make(path: f[9], orig: orig, x: xy[0], y: xy[1]))

            case UInt8(ascii: "u"):
                // u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
                guard let t = decoded else { break }
                let f = split(t, keeping: 10)
                guard f.count == 11 else { break }
                st.changes.append(GitChange(path: f[10], origPath: nil, x: "U", y: "U", kind: .conflicted))

            case UInt8(ascii: "?"):
                guard let t = decoded else { break }
                let path = String(t.dropFirst(2))
                guard !path.isEmpty else { break }
                st.changes.append(GitChange(path: path, origPath: nil, x: "?", y: "?", kind: .untracked))

            default:
                break // "!" — игнорируемые, нам не нужны
            }
        }

        st.changes.sort {
            $0.kind == $1.kind
                ? $0.path.localizedStandardCompare($1.path) == .orderedAscending
                : $0.kind < $1.kind
        }
        return st
    }

    /// Файл часто имеет сразу два статуса: X — в индексе, Y — в рабочей копии. Например «RM» —
    /// переименован и потом ещё правлен. Показать надо самое существенное, а не просто последнее:
    /// про переименованный файл важно знать, что он переименован, иначе он выглядит как обычная
    /// правка и непонятно, куда делся старый.
    private static func make(path: String, orig: String?, x: Character, y: Character) -> GitChange {
        let kind: ChangeKind

        if x == "U" || y == "U" {
            kind = .conflicted
        } else if y == "D" {
            kind = .deleted // в рабочей копии файла уже нет — это главное
        } else if x == "R" || x == "C" {
            kind = .renamed
        } else if x == "A" {
            kind = .added // в HEAD его не было, даже если поверх успели поправить
        } else if x == "D" {
            kind = .deleted
        } else {
            kind = .modified // остаётся M и T (смена типа файла) — для нас это одно и то же
        }
        return GitChange(path: path, origPath: orig, x: x, y: y, kind: kind)
    }

    /// Режет строку по пробелам, оставляя хвост (путь) целым — в пути пробелы легальны.
    private static func split(_ s: String, keeping n: Int) -> [String] {
        s.split(separator: " ", maxSplits: n, omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: - Содержимое сторон diff'а

    /// Файл из коммита/индекса. `rev` — "HEAD" или "" (пустая строка = индекс, как `git show :path`).
    /// Отсутствие файла в ревизии — не ошибка: для нового файла левая сторона просто пустая.
    /// А вот обрыв транспорта — ошибка: он не должен выглядеть как «файла в ревизии нет».
    static func show(conn: Connection, root: String, rev: String, path: String) async throws -> Data? {
        let r = try await conn.sh("git -C \(shq(root)) show \(shq(rev + ":" + path)) 2>/dev/null")
        try Connection.transportCheck(r)
        return r.ok ? r.out : nil
    }

    enum GitError: LocalizedError {
        case emptyPath

        var errorDescription: String? {
            "Пустой путь — операция отменена."
        }
    }

    /// Пустой путь в разрушающей команде — это `rm -rf <корень>/` и стёртый репозиторий.
    /// Такого пути git не отдаёт, но проверить дешевле, чем потом объясняться.
    private static func checked(_ change: GitChange) throws -> String {
        guard !change.path.isEmpty, change.path != "." else { throw GitError.emptyPath }
        return change.path
    }

    static func stage(conn: Connection, root: String, change: GitChange) async throws {
        let path = try checked(change)
        // `git add -A -- path` корректно ставит в индекс и удаление, и переименование.
        try await conn.shOK("git -C \(shq(root)) add -A -- \(shq(path))")
    }

    static func unstage(conn: Connection, root: String, change: GitChange) async throws {
        let path = try checked(change)
        // Переименование в индексе — это ДВЕ операции: удаление старого пути и добавление
        // нового. Сбросить только новый путь — значит оставить старый застейдженным как
        // Deleted, и «пустой» на вид коммит удалил бы файл из репозитория. Поэтому прежний
        // путь сбрасывается вместе с новым.
        var paths = [path]
        if let orig = change.origPath, !orig.isEmpty, orig != "." {
            paths.append(orig)
        }
        let quoted = paths.map(shq).joined(separator: " ")

        // В репозитории без единого коммита HEAD ещё не существует, и `reset HEAD` там не работает —
        // тогда файл убирается из индекса напрямую. Раньше это было склеено через `||`, и любой
        // сбой `reset` приводил бы к `rm --cached` на отслеживаемом файле, то есть совсем не к тому.
        let script = """
        cd -- \(shq(root)) || exit 1
        if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
          git reset -q HEAD -- \(quoted)
        else
          git rm -q --cached -- \(quoted)
        fi
        """
        try await conn.shOK(script)
    }

    /// Откат правок в рабочей копии. Для неотслеживаемого файла — удаление.
    static func discard(conn: Connection, root: String, change: GitChange) async throws {
        let path = try checked(change)
        if change.kind == .untracked {
            // Именно `rm -f`, а не `rm -rf`: с `--untracked-files=all` git перечисляет файлы
            // поимённо, каталогов среди них не бывает, а рекурсивное удаление здесь — лишний
            // риск на ровном месте.
            try await conn.shOK("rm -f -- \(shq(root + "/" + path))")
        } else {
            try await conn.shOK("git -C \(shq(root)) checkout -- \(shq(path))")
        }
    }

    static func commit(conn: Connection, root: String, message: String) async throws {
        try await conn.shOK("git -C \(shq(root)) commit -F - ", stdin: Data(message.utf8))
    }

    /// Все файлы под контролем git — источник для быстрого перехода (⌘P).
    static func lsFiles(conn: Connection, root: String) async throws -> [String] {
        let r = try await conn.shOK(
            "git -C \(shq(root)) ls-files -z --cached --others --exclude-standard",
            timeout: 30
        )
        // Строго UTF-8: имя с «чужими» байтами пропускаем, а не искажаем заменой на U+FFFD —
        // по искажённому пути файл всё равно не открылся бы.
        return r.out.split(separator: 0)
            .compactMap { String(bytes: $0, encoding: .utf8) }
            .filter { !$0.isEmpty }
    }
}
