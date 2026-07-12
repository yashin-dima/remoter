import Foundation

/// Названия сессий, заданные пользователем руками.
///
/// Claude Code придумывает заголовок разговора сам и наружу команды переименовать его не даёт.
/// Поэтому своё имя мы храним у себя — по id сессии (он же имя файла журнала), чтобы оно пережило
/// и закрытие вкладки, и переоткрытие разговора из списка. Ключ по sessionID, а не по вкладке:
/// вкладка временна, а разговор — нет.
///
/// Живёт в UserDefaults: это горстка коротких строк, отдельный файл ради них заводить незачем.
enum SessionTitles {
    private static let key = "claude.sessionTitles"

    private static var defaults: UserDefaults { .standard }

    static func all() -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func title(for id: String) -> String? {
        all()[id]
    }

    /// Пустое имя стирает запись — вкладка вернётся к автоматическому заголовку Claude.
    static func set(_ title: String?, for id: String) {
        guard !id.isEmpty else { return }
        var d = all()
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            d.removeValue(forKey: id)
        } else {
            d[id] = trimmed
        }
        defaults.set(d, forKey: key)
    }
}
