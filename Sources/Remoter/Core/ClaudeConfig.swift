import Foundation

/// Настройки самого Claude Code — те, что он держит в `settings.json`.
///
/// Читаем их по одной причине: **приложение не должно решать за Claude**. У вас в его настройках
/// стоит `opus[1m]` и `xhigh` — значит именно с этим он и должен запускаться, а не с тем, что мы
/// когда-то зашили в код. Раньше приложение подставляло свои флаги, и они молча перекрывали ваши:
/// `--model opus` вместо вашего `opus[1m]` обрезал контекст с миллиона до двухсот тысяч.
///
/// Пишем сюда никогда — это чужой файл.
enum ClaudeConfig {

    // Всё знание о контекстных окнах собрано здесь — и только здесь.
    /// Суффикс алиаса, который просит миллион токенов: `opus[1m]`.
    static let longContextSuffix = "[1m]"
    /// Обычное окно моделей Claude.
    static let standardWindow = 200_000
    /// Окно с суффиксом `[1m]`.
    static let longWindow = 1_000_000

    /// Модель по умолчанию, как её записал сам Claude: `opus`, `opus[1m]`, `claude-fable-5`…
    static var model: String? { string("model") }

    /// Уровень reasoning по умолчанию: его ставит `/effort`.
    static var effort: String? { string("effortLevel") }

    /// Размер контекстного окна для алиаса модели.
    ///
    /// Единственное, что здесь «знание»: у моделей Claude окно 200k, а суффикс `[1m]` просит
    /// миллион. Это описано в документации и в самом `/model`; никакой команды, которая вернула
    /// бы размер окна числом, у Claude Code нет — `/context` рисует его картинкой в терминале
    /// и наружу не отдаёт.
    static func window(alias: String?) -> Int {
        (alias ?? model ?? "").contains(longContextSuffix) ? longWindow : standardWindow
    }

    /// Отображаемое имя алиаса модели: `opus` → «Opus 4.8».
    ///
    /// Алиасы Claude указывают на ТЕКУЩЕЕ поколение, поэтому версии протухнут с его сменой —
    /// и именно поэтому зашиты в одном-единственном месте, а не россыпью по UI. Для незнакомого
    /// алиаса и полного id имя собирается из самой строки — `ClaudeJournal.modelName(fromID:)`.
    static func modelTitle(alias: String) -> String? {
        aliasTitles[alias]
    }

    private static let aliasTitles: [String: String] = [
        "fable":  "Fable 5",
        "opus":   "Opus 4.8",
        "sonnet": "Sonnet 5",
        "haiku":  "Haiku 4.5",
    ]

    // MARK: - Чтение с кэшем

    /// Разобранный settings.json и mtime файла, из которого он разобран.
    ///
    /// Кэш не прихоть: настройки читаются из вычисляемых свойств плашек SwiftUI, то есть на
    /// каждую перерисовку — а плашки перерисовываются каждые полторы секунды, когда поллинг
    /// журналов обновляет вкладки. Читать и парсить файл на каждый рендер главного потока
    /// расточительно; сверка mtime — один дешёвый stat, и правку настроек снаружи она ловит.
    private static var cache: (mtime: Date, values: [String: String])?

    private static func string(_ key: String) -> String? {
        let file = ClaudeSessions.configDirectory.appendingPathComponent("settings.json")
        let mtime = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate])
            as? Date ?? .distantPast

        if let cache, cache.mtime == mtime { return cache.values[key] }

        var values: [String: String] = [:]
        if let data = try? Data(contentsOf: file),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for (k, v) in root {
                if let s = v as? String, !s.isEmpty { values[k] = s }
            }
        }
        cache = (mtime, values)
        return values[key]
    }
}
