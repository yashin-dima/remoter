import SwiftUI
import AppKit
import UserNotifications

/// Настройки приложения — те, что у каждого свои.
///
/// Живут в UserDefaults и общие на все окна: масштаб интерфейса — свойство человека, а не проекта.
/// Меняются они редко, но меняться должны сразу, без перезапуска, — поэтому это ObservableObject,
/// а не набор разрозненных @AppStorage по разным экранам.
@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    /// Масштаб интерфейса. У кого-то 27" и хочется убористее, у кого-то ноутбук и мелкий шрифт
    /// не разглядеть — системного способа масштабировать одно приложение macOS не даёт.
    /// Границы задаёт сам ползунок. Подрезать значение ЗДЕСЬ нельзя: присваивание внутри `didSet`
    /// у `@Published`-свойства снова зовёт сеттер (свойство вычисляемое — это обёртка), тот снова
    /// зовёт `didSet`, и так до переполнения стека. Ровно на этом приложение и падало, стоило
    /// тронуть ползунок масштаба.
    @Published var scale: Double {
        didSet {
            D.scale = CGFloat(scale)
            defaults.set(scale, forKey: "ui.scale")
        }
    }

    static let scaleRange = 0.8...1.6

    /// Терминал и редактор — отдельно: в них смотрят часами, и там свой комфортный размер,
    /// не обязательно совпадающий с масштабом кнопок и списков.
    @Published var terminalFontSize: Double {
        didSet { defaults.set(terminalFontSize, forKey: "terminal.fontSize") }
    }

    @Published var editorFontSize: Double {
        didSet { defaults.set(editorFontSize, forKey: "editor.fontSize") }
    }

    /// Звук уведомления, когда Claude закончил работу, и когда он о чём-то спрашивает.
    /// Разные — чтобы «он ждёт меня» было слышно, не глядя на экран.
    @Published var soundDone: NotificationSound {
        didSet { defaults.set(soundDone.rawValue, forKey: "sound.done") }
    }

    @Published var soundAsk: NotificationSound {
        didSet { defaults.set(soundAsk.rawValue, forKey: "sound.ask") }
    }

    /// С чем открывать новую сессию Claude. Это именно значения по умолчанию: в окне запуска
    /// их можно поменять на один раз, не трогая настройку.
    @Published var model: ClaudeModel {
        didSet { defaults.set(model.rawValue, forKey: "claude.model") }
    }

    @Published var effort: ClaudeEffort {
        didSet { defaults.set(effort.rawValue, forKey: "claude.effort") }
    }

    @Published var permissions: ClaudePermissions {
        didSet { defaults.set(permissions.rawValue, forKey: "claude.permissions") }
    }

    /// Запускать Opus и Sonnet с контекстом в миллион токенов (`--model opus[1m]`).
    ///
    /// Без этого Claude получает обычные 200k — даже если в вашем `~/.claude/settings.json`
    /// стоит `opus[1m]`: флаг запуска перекрывает настройку. Ровно так приложение и обрезало
    /// контекст, ничего об этом не сообщая.
    @Published var longContext: Bool {
        didSet { defaults.set(longContext, forKey: "claude.longContext") }
    }

    /// Продолжать последний разговор при открытии проекта.
    @Published var resumeLastSession: Bool {
        didSet { defaults.set(resumeLastSession, forKey: "claude.resumeLast") }
    }

    /// Одиночный клик по файлу открывает вкладку-предпросмотр (как в VS Code), а не постоянную.
    @Published var previewTabs: Bool {
        didSet { defaults.set(previewTabs, forKey: "editor.previewTabs") }
    }

    /// Открыта ли нижняя панель терминала и сколько места она занимает (доля высоты).
    /// Запоминаются на приложение: раскладка — привычка человека, а не свойство проекта.
    @Published var terminalPanelOpen: Bool {
        didSet { defaults.set(terminalPanelOpen, forKey: "terminal.panelOpen") }
    }

    @Published var terminalPanelFraction: Double {
        didSet { defaults.set(terminalPanelFraction, forKey: "terminal.panelFraction") }
    }

    /// Границы доли терминала: и ему, и тому, что сверху, всегда остаётся рабочее место.
    static let terminalFractionRange = 0.15...0.75

    private let defaults: UserDefaults

    /// Прежние bundle id приложения. UserDefaults живут в файле, названном ПО bundle id, —
    /// смена id (com.yashin.remoter → app.remoter.Remoter при выходе в open source) оставила
    /// все настройки в старом файле, и у людей «слетели» масштаб и звуки. Недопустимо: при
    /// первом запуске под новым id все ключи переносятся из старых доменов. Разово — дальше
    /// живём в своём домене, и обычные обновления настройки не трогают вовсе.
    private static let legacyDomains = ["com.yashin.remoter"]
    private static let migrationKey = "migration.defaults.v1"

    private static func migrateLegacyDefaults(into defaults: UserDefaults) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        defaults.set(true, forKey: migrationKey)

        for domain in legacyDomains {
            guard let old = UserDefaults.standard.persistentDomain(forName: domain) else { continue }
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Под тестами не мигрируем: xctest подхватил бы старый домен в свой, и прогоны
        // зависели бы от того, что лежит у разработчика в старых настройках.
        if !TestIsolation.isRunningTests {
            Self.migrateLegacyDefaults(into: defaults)
        }

        let saved = defaults.object(forKey: "ui.scale") as? Double ?? 1
        scale = min(max(saved, Self.scaleRange.lowerBound), Self.scaleRange.upperBound)
        terminalFontSize = defaults.object(forKey: "terminal.fontSize") as? Double ?? 14
        editorFontSize = defaults.object(forKey: "editor.fontSize") as? Double ?? 13

        soundDone = NotificationSound(rawValue: defaults.string(forKey: "sound.done") ?? "")
        soundAsk = NotificationSound(rawValue: defaults.string(forKey: "sound.ask") ?? "Ping")

        // По умолчанию не навязываем Claude ничего: модель, effort и режим разрешений он возьмёт
        // свои — те, что стоят в его же настройках. Наши флаги перекрывали их молча (ровно так
        // `--model opus` обрезал контекст с миллиона до двухсот тысяч).
        model = ClaudeModel(rawValue: defaults.string(forKey: "claude.model") ?? "") ?? .inherit
        effort = ClaudeEffort(rawValue: defaults.string(forKey: "claude.effort") ?? "") ?? .inherit
        // `.default` не добавляет `--permission-mode` вовсе — Claude берёт свой `defaultMode`.
        // Прежний дефолт `.bypassPermissions` НАВЯЗЫВАЛ полный доступ из коробки: сессия
        // автостартует (см. autostartClaude), и чужой Claude сразу получал право на всё без единого
        // запроса. Кто хочет полный доступ — включает его осознанно (или ставит в самом Claude).
        // У кого значение уже сохранено — останется его.
        permissions = ClaudePermissions(rawValue: defaults.string(forKey: "claude.permissions") ?? "")
            ?? .default

        longContext = defaults.object(forKey: "claude.longContext") as? Bool ?? true
        resumeLastSession = defaults.object(forKey: "claude.resumeLast") as? Bool ?? true
        previewTabs = defaults.object(forKey: "editor.previewTabs") as? Bool ?? true

        // Терминал внизу открыт сразу: сплошная стена текста Claude во весь экран пугает, а с
        // терминалом под ней окно читается как рабочее место, а не как лог.
        terminalPanelOpen = defaults.object(forKey: "terminal.panelOpen") as? Bool ?? true
        let savedFraction = defaults.object(forKey: "terminal.panelFraction") as? Double ?? 0.5
        terminalPanelFraction = min(max(savedFraction, Self.terminalFractionRange.lowerBound),
                                    Self.terminalFractionRange.upperBound)

        D.scale = CGFloat(scale)
    }
}

/// Звук уведомления: системный, свой файл или тишина.
///
/// macOS ищет звук по ИМЕНИ файла — в бандле приложения, в `/System/Library/Sounds` и
/// в `~/Library/Sounds`. Поэтому свой файл мы кладём в последнюю папку: иначе система его
/// просто не найдёт и молча сыграет стандартный.
enum NotificationSound: Equatable, Hashable {
    case silent
    case system(String)
    /// Имя файла в ~/Library/Sounds.
    case custom(String)

    private static let customPrefix = "custom:"

    init(rawValue: String) {
        switch true {
        case rawValue.isEmpty:                       self = .system("Glass")
        case rawValue == "-":                        self = .silent
        case rawValue.hasPrefix(Self.customPrefix):
            self = .custom(String(rawValue.dropFirst(Self.customPrefix.count)))
        default:                                     self = .system(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .silent:            return "-"
        case .system(let name):  return name
        case .custom(let name):  return Self.customPrefix + name
        }
    }

    var title: String {
        switch self {
        case .silent:            return "Без звука"
        case .system(let name):  return name
        case .custom(let name):  return (name as NSString).deletingPathExtension
        }
    }

    /// Имя файла для UNNotificationSound. Система дописывает расширение сама только системным.
    var fileName: String? {
        switch self {
        case .silent:            return nil
        case .system(let name):  return name + ".aiff"
        case .custom(let name):  return name
        }
    }

    /// Проиграть здесь и сейчас — чтобы выбирать звук на слух, а не по названию.
    func play() {
        switch self {
        case .silent:
            break // «Без звука» и звучит как тишина — бип здесь только сбивал бы с толку
        case .system(let name):
            NSSound(named: name)?.play()
        case .custom(let name):
            let url = NotificationSound.customDirectory.appendingPathComponent(name)
            NSSound(contentsOf: url, byReference: true)?.play()
        }
    }

    /// Куда класть свои звуки. Не наша папка — системная, но это единственное место, где macOS
    /// станет искать звук для уведомления.
    static var customDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Sounds", isDirectory: true)
    }

    /// Что лежит в /System/Library/Sounds — то, что и предлагает система в своих настройках.
    static var systemSounds: [String] {
        let dir = URL(fileURLWithPath: "/System/Library/Sounds")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files
            .filter { $0.hasSuffix(".aiff") }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Копирует выбранный файл в ~/Library/Sounds — иначе система его не найдёт.
    /// Возвращает звук, готовый к употреблению, или nil, если скопировать не вышло.
    static func adopt(_ file: URL) -> NotificationSound? {
        let dir = customDirectory
        let dest = dir.appendingPathComponent(file.lastPathComponent)

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: file, to: dest)
        } catch {
            return nil
        }
        return .custom(dest.lastPathComponent)
    }
}
