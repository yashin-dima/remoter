import AppKit

/// Иконка проекта — его собственный favicon, найденный прямо в коде.
///
/// Проектов в списке десяток, и все они выглядят одинаково: одна и та же серая папка. А у сайта,
/// над которым идёт работа, иконка обычно есть — и она узнаётся мгновенно, без чтения названия.
///
/// Ищем и на сервере, и локально ОДИНАКОВО — через `Connection.sh`, как и всё остальное. Но
/// у списка проектов соединения нет и быть не должно (открывать ssh ко всем серверам, чтобы
/// нарисовать список, — безумие), поэтому иконка ищется при ОТКРЫТИИ проекта и кладётся в кэш.
/// Список берёт её оттуда: в первый раз проект показывается со штатной иконкой, дальше — со своей.
@MainActor
enum ProjectIcon {

    /// Больше мегабайта favicon не бывает; всё, что больше, — не иконка, а чья-то ошибка.
    private static let maxBytes = 1_048_576

    // MARK: - Кэш

    private static var cacheDir: URL {
        let dir = TestIsolation.path("icons") {
            FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Remoter", isDirectory: true)
                .appendingPathComponent("icons", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheFile(_ id: UUID) -> URL {
        cacheDir.appendingPathComponent(id.uuidString)
    }

    /// Иконка проекта, если её уже нашли раньше. Декодируем каждый раз заново, а не держим в
    /// памяти: иконок мало, они крошечные, а вот протухший кэш в памяти — источник странностей.
    static func cached(for id: UUID) -> NSImage? {
        guard let data = try? Data(contentsOf: cacheFile(id)) else { return nil }
        return NSImage(data: data)
    }

    /// Проект удалили — незачем держать его иконку вечно.
    static func forget(_ id: UUID) {
        try? FileManager.default.removeItem(at: cacheFile(id))
    }

    // MARK: - Поиск

    /// Находит favicon в проекте и кладёт в кэш. Тихая операция: не нашли — ну и ладно,
    /// останется штатная иконка. Ошибки сюда не поднимаются: из-за ненайденной картинки
    /// проект открываться не перестанет.
    @discardableResult
    static func discover(conn: Connection, root: String, id: UUID) async -> Bool {
        guard let path = await find(conn: conn, root: root) else { return false }
        guard let data = await read(conn: conn, path: path), NSImage(data: data) != nil else {
            return false
        }
        try? data.write(to: cacheFile(id), options: .atomic)
        return true
    }

    /// Где обычно лежит favicon. Сначала перебираем известные места (это дёшево — один `test -f`
    /// на каждое), и только потом ищем по дереву: `find` по большому репозиторию небесплатен.
    ///
    /// SVG сюда не берём: NSImage их не декодирует, и мы бы бережно положили в кэш то, что потом
    /// не нарисуется.
    private static let candidates = [
        "favicon.ico", "favicon.png",
        "public/favicon.ico", "public/favicon.png",
        "static/favicon.ico", "static/favicon.png",
        "assets/favicon.ico", "assets/favicon.png",
        "src/favicon.ico", "src/favicon.png",
        "app/favicon.ico", "app/favicon.png",
        "web/favicon.ico", "dist/favicon.ico", "build/favicon.ico",
        "public/apple-touch-icon.png", "apple-touch-icon.png",
        "public/logo.png", "static/logo.png", "assets/logo.png",
    ]

    private static func find(conn: Connection, root: String) async -> String? {
        // Один скрипт на весь перебор: два десятка отдельных ssh-команд — это два десятка
        // круговых задержек, а так укладываемся в одну.
        let checks = candidates
            .map { "[ -f \(shq(root + "/" + $0)) ] && { printf '%s' \(shq(root + "/" + $0)); exit 0; }" }
            .joined(separator: "\n")

        // Запасной путь: поискать по дереву неглубоко, обходя стороной node_modules и .git —
        // в них favicon'ов чужих библиотек сотни, и первый попавшийся будет не наш.
        let script = """
        \(checks)
        find \(shq(root)) -maxdepth 3 \\
          \\( -name node_modules -o -name .git -o -name vendor -o -name dist \\) -prune -o \\
          \\( -iname 'favicon.ico' -o -iname 'favicon.png' \\) -print 2>/dev/null | head -n 1
        """

        guard let r = try? await conn.sh(script, timeout: 20), r.ok else { return nil }
        let path = r.line
        return path.isEmpty ? nil : path
    }

    private static func read(conn: Connection, path: String) async -> Data? {
        // Читаем ограниченно: `head -c` не даст втянуть в память чужой многомегабайтный файл,
        // если под именем favicon.png вдруг лежит не иконка.
        guard let r = try? await conn.sh("head -c \(maxBytes) < \(shq(path))", timeout: 20),
              r.ok, !r.out.isEmpty
        else { return nil }
        return r.out
    }
}
