import AppKit

/// Картинки, которые лежат в разговоре с Claude.
///
/// Терминал — это текст, и картинку он показать не может: бросили Claude скриншот — и он для вас
/// исчез, в терминале осталось «[Image #1]». А вернуться к нему бывает нужно: что именно я ему
/// показывал час назад?
///
/// Сами картинки лежат в журнале Claude (base64 внутри блока `{"type":"image",…}`) — мы его,
/// как и всё остальное, только читаем. Разбираем по требованию, а не держим в памяти: скриншот
/// в base64 — это мегабайт, и десяток таких на каждую открытую вкладку никому не нужен.
enum ClaudeAttachments {

    struct Item: Identifiable {
        let id = UUID()
        let image: NSImage
        /// Расширение исходного файла — по нему картинку сохраняют на диск в первозданном виде.
        let ext: String
    }

    /// Разбирает журнал и возвращает все картинки разговора, свежие в конце.
    ///
    /// Читаем построчно и без загрузки файла целиком: журнал долгой сессии — десятки мегабайт.
    static func list(in journal: URL) -> [Item] {
        guard let data = try? Data(contentsOf: journal, options: .mappedIfSafe) else { return [] }

        var items: [Item] = []
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            // Дешёвая проверка на подстроку — и только совпавшие строки уходят в JSONDecoder:
            // строк тысячи, и почти каждая большой JSON.
            guard line.firstRange(of: imageMarker) != nil else { continue }
            items.append(contentsOf: images(in: Data(line)))
        }
        return items
    }

    private static let imageMarker = Array(#""type":"image""#.utf8)

    /// Формат чужой и может меняться между версиями Claude Code, поэтому разбор нарочно
    /// нетребовательный: не нашли поле — молча пропускаем строку, а не падаем.
    private static func images(in line: Data) -> [Item] {
        guard let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let message = root["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return [] }

        return content.compactMap { block in
            guard block["type"] as? String == "image",
                  let source = block["source"] as? [String: Any],
                  let base64 = source["data"] as? String,
                  let bytes = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
                  let image = NSImage(data: bytes)
            else { return nil }

            let media = (source["media_type"] as? String) ?? "image/png"
            return Item(image: image, ext: media.split(separator: "/").last.map(String.init) ?? "png")
        }
    }
}
