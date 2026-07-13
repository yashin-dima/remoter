import AppKit

/// Иконка проекта — та, что вы задали ему сами.
///
/// Проектов в списке десяток, и все они выглядят одинаково: одна и та же серая коробка. Своя
/// иконка узнаётся мгновенно, не читая названия.
///
/// Ищем её не мы, а **вы**: картинкой с диска или адресом сайта, у которого мы заберём favicon.
/// Автоматический поиск по коду проекта здесь был и убран — он лазил по чужому дереву, находил
/// то иконку примера, то логотип библиотеки, и объяснить, почему у проекта именно такая картинка,
/// было невозможно. Явный выбор честнее любой догадки.
///
/// Живут иконки в Application Support, по файлу на проект. В самом проекте ничего не появляется.
@MainActor
enum ProjectIcon {

    /// Иконка больше мегабайта — это не иконка, а чья-то ошибка.
    static let maxBytes = 1_048_576

    // MARK: - Хранилище

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

    private static func file(_ id: UUID) -> URL {
        cacheDir.appendingPathComponent(id.uuidString)
    }

    static func cached(for id: UUID) -> NSImage? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return NSImage(data: data)
    }

    /// Кладём картинку проекту. Возвращает nil, если это не картинка, — молча положить в кэш
    /// то, что потом не нарисуется, было бы худшим исходом: иконки нет, а почему — непонятно.
    @discardableResult
    static func store(_ data: Data, for id: UUID) -> NSImage? {
        guard data.count <= maxBytes, let image = NSImage(data: data) else { return nil }
        try? data.write(to: file(id), options: .atomic)
        return image
    }

    static func forget(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(id))
    }

    // MARK: - Иконка с сайта

    enum FetchError: LocalizedError {
        case badAddress
        case notFound
        case notAnImage

        var errorDescription: String? {
            switch self {
            case .badAddress: return "Не разобрал адрес сайта."
            case .notFound:   return "На сайте не нашлось иконки."
            case .notAnImage: return "По этому адресу лежит не картинка."
            }
        }
    }

    /// Забирает favicon у сайта: читает его страницу, находит объявленную иконку, а если её
    /// нет — пробует `/favicon.ico`, как это делает любой браузер.
    static func fetch(fromSite address: String) async throws -> Data {
        guard let home = url(from: address) else { throw FetchError.badAddress }

        var candidates = (try? await declaredIcons(at: home)) ?? []
        // Ничего не объявлено — там, где браузер ищет по умолчанию.
        candidates.append(contentsOf: [
            home.appendingPathComponent("favicon.ico"),
            home.appendingPathComponent("favicon.png"),
            home.appendingPathComponent("apple-touch-icon.png"),
        ])

        for candidate in candidates {
            guard let data = try? await load(candidate), data.count <= maxBytes else { continue }
            guard NSImage(data: data) != nil else { continue }
            return data
        }
        throw FetchError.notFound
    }

    /// Адрес, набранный человеком: «onco-sos.ru», «https://onco-sos.ru/страница». Нам нужен корень.
    static func url(from address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var parts = URLComponents(string: withScheme),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              parts.host?.isEmpty == false
        else { return nil }

        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    /// Иконки, объявленные самой страницей (`<link rel="icon" href="…">`), — они точнее, чем
    /// угаданный `/favicon.ico`, и там же лежат крупные apple-touch-icon.
    ///
    /// Разбор нарочно нетребовательный: HTML в жизни бывает любой, и падать из-за картинки
    /// приложение не должно — не разобрали, значит просто пойдём по умолчанию.
    private static func declaredIcons(at home: URL) async throws -> [URL] {
        declaredIcons(in: String(decoding: try await load(home), as: UTF8.self), home: home)
    }

    /// Отдельно от загрузки — чтобы разбор HTML проверялся тестом, а не «на живом сайте»,
    /// который завтра поменяет вёрстку.
    static func declaredIcons(in html: String, home: URL) -> [URL] {
        // <link rel="icon" ... href="...">  и  <link href="..." ... rel="apple-touch-icon">
        let pattern = #"<link\b[^>]*>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }
        let range = NSRange(html.startIndex..., in: html)

        var found: [(rank: Int, url: URL)] = []
        for match in re.matches(in: html, range: range) {
            guard let r = Range(match.range, in: html) else { continue }
            let tag = String(html[r])
            guard let rel = attribute("rel", in: tag)?.lowercased(),
                  rel.contains("icon"),
                  let href = attribute("href", in: tag),
                  let url = URL(string: href, relativeTo: home)?.absoluteURL
            else { continue }

            // Крупные — вперёд: в списке проектов иконка рисуется не в 16 точек.
            let rank = rel.contains("apple-touch") ? 0 : (size(in: tag) >= 32 ? 1 : 2)
            found.append((rank, url))
        }
        return found.sorted { $0.rank < $1.rank }.map(\.url)
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\(name)\\s*=\\s*[\"']([^\"']+)[\"']"
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let r = Range(m.range(at: 1), in: tag)
        else { return nil }
        return String(tag[r]).trimmingCharacters(in: .whitespaces)
    }

    /// `sizes="32x32"` → 32. Нет — 0.
    private static func size(in tag: String) -> Int {
        guard let sizes = attribute("sizes", in: tag),
              let first = sizes.split(separator: "x").first,
              let n = Int(first)
        else { return 0 }
        return n
    }

    private static func load(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // Некоторые сайты без «человеческого» агента отдают заглушку вместо страницы.
        request.setValue("Mozilla/5.0 (Macintosh) Remoter", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.notFound
        }
        return data
    }
}
