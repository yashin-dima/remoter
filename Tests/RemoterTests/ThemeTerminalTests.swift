import XCTest
@testable import Remoter

/// Палитра терминала обязана быть той же палитрой, что у остального приложения, — и уметь
/// отвечать за обе темы явно, а не подглядывать в глобальное состояние на момент создания.
/// Именно из-за подглядывания терминал раньше застревал в старой теме после её смены.
@MainActor
final class ThemeTerminalTests: XCTestCase {

    /// 16 цветов ANSI — стандарт; недостача ломает вывод любых цветных программ.
    func testPalettesHave16Colors() {
        XCTAssertEqual(TerminalTheme.palette(dark: false).count, 16)
        XCTAssertEqual(TerminalTheme.palette(dark: true).count, 16)
    }

    /// Светлая и тёмная палитры — действительно разные (а не одна, выбранная при запуске).
    func testPalettesDifferByTheme() {
        let light = TerminalTheme.palette(dark: false)
        let dark = TerminalTheme.palette(dark: true)
        XCTAssertFalse(
            zip(light, dark).allSatisfy {
                $0.red == $1.red && $0.green == $1.green && $0.blue == $1.blue
            },
            "палитры light и dark не должны совпадать"
        )
    }

    /// Фон, текст и курсор терминала — из тех же хекс-пар Theme, что и у всего окна:
    /// один источник, а не копия, которая разъезжается при правке.
    func testTerminalColorsComeFromThemeHexes() {
        XCTAssertEqual(
            TerminalTheme.background(dark: true),
            Theme.nsColor(Theme.surfaceHex.dark)
        )
        XCTAssertEqual(
            TerminalTheme.background(dark: false),
            Theme.nsColor(Theme.surfaceHex.light)
        )
        XCTAssertEqual(
            TerminalTheme.foreground(dark: true),
            Theme.nsColor(Theme.textHex.dark)
        )
        XCTAssertEqual(
            TerminalTheme.caret(dark: false),
            Theme.nsColor(Theme.accentHex.light)
        )
    }

    /// Разбор хекса в компоненты — по каналам, без перестановок.
    func testNsColorParsesHexChannels() {
        let c = Theme.nsColor(0x123456)
        XCTAssertEqual(c.redComponent, Double(0x12) / 255, accuracy: 0.001)
        XCTAssertEqual(c.greenComponent, Double(0x34) / 255, accuracy: 0.001)
        XCTAssertEqual(c.blueComponent, Double(0x56) / 255, accuracy: 0.001)
        XCTAssertEqual(c.alphaComponent, 1)
    }
}
