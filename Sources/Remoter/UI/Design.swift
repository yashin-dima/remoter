import SwiftUI
import AppKit

/// Цвета приложения — все, до единого.
///
/// Палитра не придумана, а взята у VS Code (тема Light Modern): серые поверхности и синий
/// акцент — приложение стоит рядом с редактором и не должно выглядеть чужим.
///
/// Тёмный вариант — Dark Modern оттуда же. Системные цвета (`.controlBackgroundColor`,
/// `.quaternary` и прочие) здесь не используются намеренно: они тянут за собой оформление macOS,
/// из-за которого интерфейс и разъезжался на несколько разных стилей в одном окне.
enum Theme {

    // Хекс-пары light/dark, у которых есть второй потребитель — NSColor-палитра терминала
    // (TerminalTheme). Единый источник: одни и те же значения, а не копия, которая разъехалась
    // бы при первой правке.
    static let surfaceHex = (light: 0xFFFFFF, dark: 0x1F1F1F)
    static let textHex = (light: 0x3B3B3B, dark: 0xCCCCCC)
    static let accentHex = (light: 0x0078D4, dark: 0x4DAAFC)

    /// Фон окна: боковая панель, полоса вкладок, панели.
    static let bg = dynamic(light: 0xF8F8F8, dark: 0x181818)
    /// Рабочая поверхность: редактор, терминал, активная вкладка.
    static let surface = dynamic(light: surfaceHex.light, dark: surfaceHex.dark)
    /// Разделители. Одна тонкая линия — весь декор, который нужен.
    static let border = dynamic(light: 0xE5E5E5, dark: 0x2B2B2B)

    static let text = dynamic(light: textHex.light, dark: textHex.dark)
    static let secondary = dynamic(light: 0x6F6F6F, dark: 0x9D9D9D)

    /// Под курсором и под выделением.
    static let hover = dynamic(light: 0xF0F0F0, dark: 0x2A2A2A)
    static let selection = dynamic(light: 0xE4EDF7, dark: 0x37373D)

    /// Акцент — синий VS Code. Один на всё приложение: кнопки, активные вкладки, выделение.
    static let accent = dynamic(light: accentHex.light, dark: accentHex.dark)
    /// Полупрозрачная подложка акцента. Динамическая, как и всё остальное: раньше это был
    /// один захардкоженный светлый оттенок, и в тёмной теме он выбивался из палитры.
    static let accentSoft = dynamic(light: accentHex.light, dark: accentHex.dark, alpha: 0.12)

    /// Статусы. Приглушённые: рядом с оранжевым акцентом кислотные цвета дерутся за внимание.
    static let added = dynamic(light: 0x2E7D32, dark: 0x4CAF50)
    static let removed = dynamic(light: 0xC62828, dark: 0xEF5350)
    static let modified = dynamic(light: 0xB26A00, dark: 0xE2A03F)
    static let renamed = dynamic(light: 0x1565C0, dark: 0x42A5F5)
    static let conflicted = dynamic(light: 0x6A1B9A, dark: 0xAB47BC)

    private static func dynamic(light: Int, dark: Int, alpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return nsColor(isDark ? dark : light, alpha: alpha)
        })
    }

    /// NSColor из хекса — для мест, куда SwiftUI-цвет не годится (терминал SwiftTerm).
    static func nsColor(_ hex: Int, alpha: Double = 1) -> NSColor {
        NSColor(
            srgbRed: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// Хекс-пара → NSColor нужной темы.
    static func nsColor(pair: (light: Int, dark: Int), dark isDark: Bool) -> NSColor {
        nsColor(isDark ? pair.dark : pair.light)
    }
}

/// Размеры и типографика в одном месте.
///
/// Раньше каждый экран назначал их себе сам, и всё расползлось: шрифты 9–12, кнопки в 12 точек,
/// строки в 3 точки отступа. По отдельности мелочь, вместе — интерфейс, в который надо целиться.
///
/// Главное правило здесь — **зона нажатия**. Она задаётся отдельно от рисунка: крестик может быть
/// нарисован в 9 точек, но нажиматься обязан в 24. Пока это не было разделено, крестик на вкладке
/// приходилось ловить пикселем.
enum D {

    /// Масштаб интерфейса — из настроек. Все размеры ниже считаются от него, поэтому «крупнее»
    /// означает крупнее ВСЁ: и шрифт, и строка, и зона нажатия. Меняй один шрифт — и кнопки
    /// остались бы прежними, а текст перестал бы в них помещаться.
    ///
    /// Ставится один раз при запуске и при изменении настройки (см. AppSettings).
    static var scale: CGFloat = 1

    /// Размер с учётом масштаба. Округляем: половина точки на границе строки даёт мыло.
    static func s(_ value: CGFloat) -> CGFloat { (value * scale).rounded() }

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: s(size), weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: s(size), weight: weight, design: .monospaced)
    }

    /// Минимальная зона нажатия. Меньше — и в кнопку приходится целиться.
    static var hit: CGFloat { s(26) }

    enum Text {
        /// Основной текст интерфейса: имена файлов, строки списков.
        static var body: Font { D.font(13) }
        static var bodyMedium: Font { D.font(13, .medium) }
        /// Заголовки секций и панелей.
        static var title: Font { D.font(14, .semibold) }
        /// Пояснения под основной строкой.
        static var caption: Font { D.font(11) }
        /// Пути, команды, id — всё, что нужно уметь разглядеть посимвольно.
        static var mono: Font { D.mono(11) }
        /// Буква статуса (M, A, D) — маленькая, но жирная, иначе теряется.
        static var badge: Font { D.mono(10, .bold) }
    }

    enum Size {
        static var row: CGFloat { D.s(28) }   // строка дерева и списка изменений
        static var tab: CGFloat { D.s(38) }   // вкладка файла
        static var icon: CGFloat { D.s(13) }  // иконка в строке
        static var radius: CGFloat { D.s(6) }
    }

    enum Pad {
        static var row: CGFloat { D.s(12) }   // отступ строки от края панели
        static var bar: CGFloat { D.s(12) }   // отступ содержимого панелей
    }
}

/// Кнопка-иконка с честной зоной нажатия и подсветкой под курсором.
///
/// Подсветка здесь не украшение: она показывает, что курсор попал. Без неё в мелкую иконку
/// приходится целиться вслепую и промахиваться — ровно на это и жаловались.
struct IconButton: View {
    let icon: String
    var size: CGFloat = 12
    var help: String = ""
    var role: ButtonRole?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: D.s(size), weight: .medium))
                .foregroundStyle(role == .destructive && hovering ? Theme.removed : Theme.secondary)
                .frame(width: D.hit, height: D.hit)
                .background(
                    hovering ? Theme.hover : .clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                // Зона нажатия — весь прямоугольник, а не только нарисованные пиксели иконки.
                .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Кнопка основного действия строки-карточки («Открыть» у проекта, «Продолжить» у сессии).
///
/// Видна всегда, а под курсором наливается акцентом — прятать основное действие до наведения
/// значит заставлять искать его мышью. `prominent` обычно привязан к hover всей карточки.
struct RowActionButton: View {
    let title: String
    let prominent: Bool
    var height: CGFloat = 28
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: D.s(12), weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: D.s(height))
                .background(
                    prominent ? Theme.accent : Theme.hover,
                    in: RoundedRectangle(cornerRadius: D.Size.radius)
                )
                .foregroundStyle(prominent ? .white : .primary)
                .contentShape(RoundedRectangle(cornerRadius: D.Size.radius))
        }
        .buttonStyle(.plain)
    }
}

/// Переключатель разделов: «Git / Files / Local», «Локально / Сервер».
///
/// Настоящий segmented control, а не три кнопки, слепленные вручную: одна выделена целиком,
/// нажимать можно в любую точку своей трети.
struct SegmentedBar<T: Hashable>: View {
    let items: [T]
    @Binding var selection: T
    let title: (T) -> String
    let icon: (T) -> String
    var badge: (T) -> Int? = { _ in nil }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { item in
                let active = selection == item

                Button {
                    selection = item
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: icon(item))
                            .font(.system(size: D.s(11), weight: .semibold))
                        Text(title(item))
                            .font(.system(size: D.s(12), weight: .semibold))

                        if let n = badge(item), n > 0 {
                            Text("\(n)")
                                .font(.system(size: D.s(10), weight: .bold))
                                .foregroundStyle(active ? Theme.accent : Color.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(active ? Color.white : Theme.secondary, in: Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: D.s(30))
                    .background(
                        active ? Theme.accent : Theme.hover,
                        in: RoundedRectangle(cornerRadius: D.Size.radius)
                    )
                    .foregroundStyle(active ? Color.white : Theme.text)
                    .contentShape(RoundedRectangle(cornerRadius: D.Size.radius))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Фон строки списка: выделение, наведение, цель перетаскивания — всегда одинаковые.
struct RowBackground: View {
    let selected: Bool
    let hovering: Bool
    var target: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(color)
            .padding(.horizontal, 4)
    }

    private var color: Color {
        if target { return Theme.accentSoft }
        if selected { return Theme.selection }
        return hovering ? Theme.hover : .clear
    }
}

/// «5 минут назад», «вчера» — в списке сессий дата важна относительно, а не абсолютно.
func relativeTime(_ date: Date, now: Date = Date()) -> String {
    let f = RelativeDateTimeFormatter()
    f.locale = Locale(identifier: "ru_RU")
    f.unitsStyle = .full
    return f.localizedString(for: date, relativeTo: now)
}
