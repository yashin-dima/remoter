import Foundation

struct RemoteEntry: Identifiable, Hashable {
    var name: String
    /// Абсолютный путь на сервере.
    var path: String
    var isDir: Bool

    var id: String { path }
}

extension [RemoteEntry] {
    /// Папки сверху, дальше по алфавиту как в Finder (10 после 9, а не после 1).
    /// Общий для сервера и локальной папки — сортировка должна выглядеть одинаково.
    func finderSorted() -> [RemoteEntry] {
        sorted {
            $0.isDir == $1.isDir
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.isDir && !$1.isDir
        }
    }
}

/// То же, что `shq`, но с разворотом `~`: пользователь вводит путь как в терминале,
/// а внутри одинарных кавычек тильду не раскрыл бы уже никто. `$HOME` остаётся в двойных
/// кавычках — его раскрывает удалённый шелл, остальное экранировано как обычно.
func shqPath(_ p: String) -> String {
    if p == "~" { return "\"$HOME\"" }
    if p.hasPrefix("~/") { return "\"$HOME\"/" + shq(String(p.dropFirst(2))) }
    return shq(p)
}

/// Содержимое удалённого файла в том виде, в каком его можно показать.
enum RemoteFile {
    /// Валидный UTF-8 — показываем и разрешаем править.
    case text(String)
    /// Читается, но это не UTF-8 (например, windows-1251).
    ///
    /// Показать можем, а вот сохранять НЕЛЬЗЯ: обратно мы пишем UTF-8, и файл был бы молча
    /// перекодирован — то есть испорчен. Такие файлы открываются только на чтение.
    case foreignEncoding(String)
    case binary(bytes: Int)
    case tooLarge(bytes: Int)
    case missing

    /// Текст, если файл вообще показывается.
    var displayText: String? {
        switch self {
        case .text(let s), .foreignEncoding(let s): return s
        default: return nil
        }
    }

    /// Править и сохранять можно только то, что мы гарантированно вернём байт в байт.
    var isEditable: Bool {
        if case .text = self { return true }
        return false
    }
}

enum WriteError: LocalizedError {
    /// Содержимое доехало до сервера не полностью — файл НЕ заменён.
    case truncated(String)
    case readOnlyWorkspace

    var errorDescription: String? {
        switch self {
        case .truncated(let detail):
            return """
            Файл не сохранён: содержимое доехало до сервера не полностью (\(detail)).
            Скорее всего, оборвалась связь. Файл на сервере остался нетронутым — повторите сохранение.
            """
        case .readOnlyWorkspace:
            return "Проект открыт только для чтения — запись выключена в его настройках."
        }
    }
}

enum RemoteFS {

    /// Файлы больше этого показывать в редакторе бессмысленно — Monaco начнёт задыхаться,
    /// да и тянуть их по SSH ради просмотра незачем.
    static let maxFileSize = 4 * 1024 * 1024

    /// Сколько первых байт нюхаем на NUL, решая «бинарник или текст» — столько же смотрит сам git.
    static let binarySniffBytes = 8000

    /// Код выхода скрипта записи «содержимое доехало не полностью». Контракт между
    /// `writeScript` и `writeData`: разъедутся значения — предохранитель молча перестанет
    /// распознаваться.
    static let truncatedExitCode: Int32 = 3

    /// Таймаут записи: базовые секунды плюс запас по размеру. Нижняя планка скорости —
    /// чтобы на медленном канале большой файл не оборвало сторожем ровно на середине.
    static let writeTimeoutBase: TimeInterval = 60
    static let writeMinBytesPerSecond: Double = 20_000

    /// Максимальная глубина разворота симлинков при записи — защита от колец.
    static let maxSymlinkDepth = 20

    /// Сколько вариантов «имя 2», «имя 3»… перебираем, прежде чем перейти к заведомо
    /// уникальному суффиксу.
    static let maxFreeNameAttempts = 99

    /// Содержимое одной директории. Скрипт намеренно на голом POSIX sh: на серверах
    /// встречается что угодно, а GNU-специфичные `find -printf` и `ls --group-directories`
    /// там просто не заведутся.
    static func list(conn: Connection, dir: String) async throws -> [RemoteEntry] {
        let script = """
        cd -- \(shq(dir)) 2>/dev/null || exit 1
        for e in * .*; do
          case "$e" in .|..) continue;; esac
          [ -e "$e" ] || [ -L "$e" ] || continue
          if [ -d "$e" ]; then printf 'd\\t%s\\0' "$e"; else printf 'f\\t%s\\0' "$e"; fi
        done
        """
        let r = try await conn.shOK(script, timeout: 30)

        var out: [RemoteEntry] = []
        for rec in r.out.split(separator: 0) {
            // Строго UTF-8: имя с «чужими» байтами пропускаем, а не искажаем заменой на
            // U+FFFD — искажённый путь дальше ушёл бы в cat/rm/mv и указывал бы не на тот файл.
            guard let s = String(bytes: rec, encoding: .utf8) else { continue }
            guard let tab = s.firstIndex(of: "\t") else { continue }
            let name = String(s[s.index(after: tab)...])
            guard !name.isEmpty else { continue }
            out.append(RemoteEntry(
                name: name,
                path: dir == "/" ? "/" + name : dir + "/" + name,
                isDir: s[s.startIndex] == "d"
            ))
        }
        return out.finderSorted()
    }

    static func read(conn: Connection, path: String) async throws -> RemoteFile {
        // Сначала размер: тянуть 200-мегабайтный лог целиком, чтобы потом сказать «слишком большой», глупо.
        let sizeR = try await conn.sh("wc -c < \(shq(path)) 2>/dev/null")
        try Connection.transportCheck(sizeR)
        guard sizeR.ok, let size = Int(sizeR.line) else { return .missing }
        guard size <= maxFileSize else { return .tooLarge(bytes: size) }

        // Читаем не больше лимита + 1 байт: между `wc` и чтением файл мог вырасти (лог!),
        // и `cat` притащил бы его целиком. Лишний байт — признак «вырос за лимит».
        // Через перенаправление, а не аргументом: `head` не трогает разбор опций, и `--`
        // ему не нужен.
        let r = try await conn.sh("head -c \(maxFileSize + 1) < \(shq(path))", timeout: 120)
        try Connection.transportCheck(r)
        guard r.ok else { return .missing }
        guard r.out.count <= maxFileSize else { return .tooLarge(bytes: r.out.count) }
        return decode(r.out)
    }

    /// Нулевой байт в тексте не встречается — это самый надёжный признак бинарника,
    /// им же пользуется сам git.
    static func decode(_ data: Data) -> RemoteFile {
        if data.prefix(binarySniffBytes).contains(0) { return .binary(bytes: data.count) }
        if let s = String(data: data, encoding: .utf8) { return .text(s) }
        // Не UTF-8 (windows-1251, latin1…). Показать можем, но только на чтение: обратно мы
        // пишем UTF-8, и «сохранение» без правок молча перекодировало бы весь файл.
        if let s = String(data: data, encoding: .isoLatin1) { return .foreignEncoding(s) }
        return .binary(bytes: data.count)
    }

    /// Запись файла на сервер.
    ///
    /// Три вещи, каждая из которых иначе портит файл:
    ///
    /// 1. **Атомарность.** Пишем во временный файл рядом и переставляем через `mv`. Наполовину
    ///    записанный файл никогда не окажется на месте настоящего — а его прямо сейчас может
    ///    читать Claude, тесты или работающее приложение на сервере.
    ///
    /// 2. **Проверка длины.** Если ssh оборвётся посреди передачи, `cat` на сервере увидит EOF
    ///    и завершится УСПЕШНО — на месте файла оказался бы обрубок, и никто бы не заметил.
    ///    Поэтому сверяем размер и переставляем файл, только если доехало всё до байта.
    ///
    /// 3. **Симлинки.** Голый `mv` заменил бы саму ссылку обычным файлом. Идём по ссылкам до
    ///    настоящего файла и пишем в него.
    ///
    /// `cp -p` перед записью нужен, чтобы временный файл унаследовал права оригинала:
    /// иначе исполняемый скрипт после сохранения потеряет `+x`.
    ///
    /// При любой ошибке оригинал остаётся нетронутым, а временный файл убирается по `trap`.
    static func write(conn: Connection, path: String, content: String) async throws {
        try await writeData(conn: conn, path: path, data: Data(content.utf8))
    }

    /// Та же запись, но байтами — для загрузки картинок и вообще любых файлов перетаскиванием.
    /// Все предохранители (атомарность, проверка длины, симлинки, права) те же самые.
    static func writeData(
        conn: Connection,
        path: String,
        data: Data,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws {
        // Таймаут по размеру: на медленном канале большой файл иначе оборвался бы сторожем
        // ровно на середине — а это и есть та самая обрезка, от которой мы защищаемся.
        let timeout = writeTimeoutBase + Double(data.count) / writeMinBytesPerSecond

        do {
            try await conn.shOK(
                writeScript(path: path, expectedBytes: data.count),
                stdin: data,
                timeout: timeout,
                onProgress: onProgress
            )
        } catch let Connection.ConnectionError.remote(message, code) where code == truncatedExitCode {
            throw WriteError.truncated(message)
        }
    }

    /// Свободное имя в каталоге: `логотип.png` → `логотип 2.png`, если первое занято.
    /// Перетаскивание файла не должно молча затирать одноимённый файл на сервере.
    ///
    /// Занятое имя отсюда не возвращается НИКОГДА: если перебор номеров исчерпан (или связь
    /// шалит и `exists` не может ответить), берётся имя с заведомо уникальным суффиксом.
    /// Лишний суффикс — мелочь, затёртый чужой файл — потеря данных.
    static func freeName(conn: Connection, dir: String, name: String) async -> String {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var candidate = name

        for i in 2...maxFreeNameAttempts {
            if await !exists(conn: conn, path: dir + "/" + candidate) { return candidate }
            candidate = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
        }
        let unique = UUID().uuidString.prefix(8)
        return ext.isEmpty ? "\(base) \(unique)" : "\(base) \(unique).\(ext)"
    }

    /// Скрипт записи вынесен отдельно, чтобы тест на обрыв связи гонял именно его, а не копию:
    /// иначе предохранитель можно было бы убрать из боевого кода, и тест бы этого не заметил.
    static func writeScript(path: String, expectedBytes: Int) -> String {
        """
        f=\(shq(path))

        n=0
        while [ -L "$f" ] && [ "$n" -lt \(maxSymlinkDepth) ]; do
          l=$(readlink -- "$f") || exit 1
          case "$l" in
            /*) f=$l ;;
            *)  f=$(dirname -- "$f")/$l ;;
          esac
          n=$((n + 1))
        done

        d=$(dirname -- "$f") || exit 1
        t="$d/.remoter.tmp.$$"
        trap 'rm -f -- "$t"' EXIT HUP INT TERM

        cp -p -- "$f" "$t" 2>/dev/null || :
        cat > "$t" || exit 1

        got=$(wc -c < "$t" | tr -d ' ')
        if [ "$got" != "\(expectedBytes)" ]; then
          echo "доехало $got байт из \(expectedBytes)" >&2
          exit \(truncatedExitCode)
        fi

        mv -f -- "$t" "$f" || exit 1
        trap - EXIT
        """
    }

    static func exists(conn: Connection, path: String) async -> Bool {
        let r = try? await conn.sh("test -e \(shq(path))")
        return r?.ok ?? false
    }

    // MARK: - Операции над файлами
    //
    // Все они разрушающие, поэтому одинаково устроены: пустые пути отсекаются раньше shell'а,
    // а корень проекта защищён отдельно — снести его случайным ⌘⌫ было бы катастрофой.

    enum OpError: LocalizedError {
        case emptyPath
        case protectedRoot(String)

        var errorDescription: String? {
            switch self {
            case .emptyPath:
                return "Пустой путь — операция отменена."
            case .protectedRoot(let p):
                return "Нельзя тронуть корень проекта (\(p))."
            }
        }
    }

    /// Хвостовые `/` и `/.` перед сравнением срезаются: `/srv/app/` — это тот же корень,
    /// что и `/srv/app`, и защита не должна пропускать его из-за косой черты.
    static func normalized(_ p: String) -> String {
        var s = p
        while s.count > 1, s.hasSuffix("/") || s.hasSuffix("/.") {
            s = String(s.dropLast(s.hasSuffix("/.") ? 2 : 1))
        }
        return s
    }

    static func check(_ paths: [String], root: String) throws {
        let rootN = normalized(root)
        for p in paths {
            let n = normalized(p)
            guard !n.isEmpty, n != "/" else { throw OpError.emptyPath }
            guard n != rootN else { throw OpError.protectedRoot(p) }
        }
    }

    static func remove(conn: Connection, paths: [String], root: String) async throws {
        try check(paths, root: root)
        let args = paths.map(shq).joined(separator: " ")
        try await conn.shOK("rm -rf -- \(args)", timeout: 120)
    }

    /// Копирование или перенос под свободным именем. Свободность проверяется ещё раз
    /// НА СЕРВЕРЕ, прямо перед операцией: `freeName` мог ошибиться (связь шалила, файл возник
    /// между проверкой и операцией) — и тогда `cp`/`mv` молча затёрли бы чужой файл.
    private static func placeScript(_ cmd: String, from: String, to: String) -> String {
        // `to` в тексте ошибки — тоже через shq, отдельным аргументом echo: имя приёмника
        // приходит из имени файла на сервере, а его контролирует кто угодно, кто может создать
        // там файл. Сырой подстановкой в двойные кавычки `$(…)` или `` ` `` в таком имени
        // выполнились бы на сервере (файл `$(reboot)` — реальный сценарий, `/` в имени не нужен).
        """
        if [ -e \(shq(to)) ] || [ -L \(shq(to)) ]; then
          echo "приёмник уже существует:" \(shq(to)) >&2
          exit 1
        fi
        \(cmd) -- \(shq(from)) \(shq(to))
        """
    }

    /// Копирование и перемещение в каталог. Одноимённый файл в приёмнике не затирается —
    /// рядом ляжет копия под свободным именем.
    static func copy(conn: Connection, paths: [String], into dir: String, root: String) async throws {
        try check(paths, root: root)
        for p in paths {
            let name = await freeName(conn: conn, dir: dir, name: (p as NSString).lastPathComponent)
            try await conn.shOK(placeScript("cp -R", from: p, to: dir + "/" + name), timeout: 120)
        }
    }

    static func move(conn: Connection, paths: [String], into dir: String, root: String) async throws {
        try check(paths, root: root)
        for p in paths {
            // Перенос в ту же папку — ничего не делаем, а не плодим «файл 2».
            guard (p as NSString).deletingLastPathComponent != dir else { continue }
            let name = await freeName(conn: conn, dir: dir, name: (p as NSString).lastPathComponent)
            try await conn.shOK(placeScript("mv", from: p, to: dir + "/" + name), timeout: 120)
        }
    }

    static func rename(conn: Connection, path: String, to newName: String, root: String) async throws {
        try check([path], root: root)
        try guardName(newName)
        let dir = (path as NSString).deletingLastPathComponent
        try await conn.shOK("mv -n -- \(shq(path)) \(shq(dir + "/" + newName))")
    }

    static func makeDirectory(conn: Connection, dir: String, name: String) async throws {
        try guardName(name)
        try await conn.shOK("mkdir -p -- \(shq(dir + "/" + name))")
    }

    /// Имя для нового файла/папки: не пустое, без `/` и не навигационное. `.` и `..` увели бы
    /// операцию из целевого каталога (`mv … /dir/sub/..` — уровнем выше), а `mkdir -p` на них
    /// был бы no-op — оба случая читаются как «переименовалось не туда».
    private static func guardName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw OpError.emptyPath
        }
    }

    /// Домашний каталог на сервере — отсюда удобно начинать обзор папок.
    static func home(conn: Connection) async -> String {
        let r = try? await conn.sh("cd && pwd -P")
        guard let r, r.ok, !r.line.isEmpty else { return "/" }
        return r.line
    }

    /// Только каталоги — для окна выбора пути.
    static func listDirs(conn: Connection, dir: String) async throws -> [RemoteEntry] {
        try await list(conn: conn, dir: dir).filter(\.isDir)
    }

    /// Есть ли в каталоге git-репозиторий — в обзоре папок это главный ориентир.
    static func isGitRepo(conn: Connection, path: String) async -> Bool {
        let r = try? await conn.sh("test -e \(shq(path + "/.git")) && echo да")
        return r?.line == "да"
    }

    /// Путь с разрешёнными симлинками.
    ///
    /// Нужно, потому что git всегда отдаёт разрешённый путь (`rev-parse --show-toplevel`), а
    /// пользователь вводит какой хочет. Если проект лежит за симлинком (`/srv/app` → `/mnt/data/app`,
    /// на маке — `/var` → `/private/var`), то корень репозитория и пути в дереве оказываются
    /// из разных «вселенных», ни один файл не сопоставляется со списком изменений — и клик
    /// по файлу в дереве не открывает diff. Приводим оба к одному виду с самого начала.
    /// Путь здесь — пользовательский ввод, поэтому `shqPath`: `~/проект` должен работать,
    /// как в терминале, а внутри одинарных кавычек тильду не развернул бы уже никто.
    static func resolve(conn: Connection, path: String) async -> String? {
        let r = try? await conn.sh("cd -- \(shqPath(path)) && pwd -P")
        guard let r, r.ok, !r.line.isEmpty else { return nil }
        return r.line
    }

    static func isDir(conn: Connection, path: String) async -> Bool {
        let r = try? await conn.sh("test -d \(shqPath(path))")
        return r?.ok ?? false
    }
}
