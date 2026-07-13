import XCTest
import AppKit
@testable import Remoter

/// Иконка проекта: её задаёт человек — файлом или адресом сайта.
///
/// Автоматического поиска по коду проекта здесь нет и не будет: он находил то иконку примера,
/// то логотип библиотеки, и объяснить, почему у проекта именно такая картинка, было невозможно.
@MainActor
final class ProjectIconTests: XCTestCase {

    private let id = UUID()

    override func tearDown() {
        super.tearDown()
        MainActor.assumeIsolated { ProjectIcon.forget(id) }
    }

    // MARK: - Хранилище

    /// Картинку положили — она возвращается. И убирается начисто.
    func testIconIsStoredAndForgotten() {
        XCTAssertNil(ProjectIcon.cached(for: id), "иконка взялась из ниоткуда")

        XCTAssertNotNil(ProjectIcon.store(png(), for: id), "картинка не сохранилась")
        XCTAssertNotNil(ProjectIcon.cached(for: id))

        ProjectIcon.forget(id)
        XCTAssertNil(ProjectIcon.cached(for: id), "иконка осталась после удаления")
    }

    /// Не картинка в кэш не попадает. Иначе у проекта была бы «иконка», которая не рисуется, —
    /// и понять, почему её не видно, было бы нельзя.
    func testNonImageIsRejected() {
        XCTAssertNil(ProjectIcon.store(Data("это не картинка".utf8), for: id))
        XCTAssertNil(ProjectIcon.cached(for: id))
    }

    // MARK: - Адрес сайта

    /// Человек набирает адрес как придётся. Нам нужен корень сайта.
    func testSiteAddressIsNormalizedToRoot() {
        XCTAssertEqual(ProjectIcon.url(from: "onco-sos.ru")?.absoluteString, "https://onco-sos.ru")
        XCTAssertEqual(ProjectIcon.url(from: "  onco-sos.ru  ")?.absoluteString, "https://onco-sos.ru")
        XCTAssertEqual(ProjectIcon.url(from: "https://onco-sos.ru/страница?a=1")?.absoluteString,
                       "https://onco-sos.ru")
        XCTAssertEqual(ProjectIcon.url(from: "http://example.com")?.absoluteString, "http://example.com")

        // Не адрес и не сеть — не берём.
        XCTAssertNil(ProjectIcon.url(from: ""))
        XCTAssertNil(ProjectIcon.url(from: "file:///etc/passwd"))
        XCTAssertNil(ProjectIcon.url(from: "ftp://example.com"))
    }

    // MARK: - Разбор страницы

    /// Иконки, объявленные страницей, находятся — и крупные идут первыми: в списке проектов
    /// картинка рисуется не в 16 точек, и favicon.ico там выглядел бы кашей.
    func testDeclaredIconsAreFoundLargestFirst() throws {
        let home = try XCTUnwrap(URL(string: "https://onco-sos.ru"))
        let html = """
        <html><head>
          <link rel="shortcut icon" href="/favicon.ico">
          <link rel="icon" type="image/png" sizes="32x32" href="/img/icon-32.png">
          <link rel="apple-touch-icon" sizes="180x180" href="https://cdn.example.com/touch.png">
          <link rel="stylesheet" href="/style.css">
        </head></html>
        """

        let found = ProjectIcon.declaredIcons(in: html, home: home).map(\.absoluteString)

        XCTAssertEqual(found.first, "https://cdn.example.com/touch.png",
                       "крупная apple-touch-icon должна идти первой")
        XCTAssertTrue(found.contains("https://onco-sos.ru/img/icon-32.png"))
        XCTAssertTrue(found.contains("https://onco-sos.ru/favicon.ico"))
        XCTAssertFalse(found.contains { $0.hasSuffix("style.css") }, "таблица стилей — не иконка")
    }

    /// Страница без единой иконки не должна ронять разбор: дальше сработает `/favicon.ico`,
    /// как в любом браузере.
    func testPageWithoutIconsParsesToNothing() throws {
        let home = try XCTUnwrap(URL(string: "https://example.com"))
        XCTAssertTrue(ProjectIcon.declaredIcons(in: "<html><head></head></html>", home: home).isEmpty)
        XCTAssertTrue(ProjectIcon.declaredIcons(in: "не html вовсе", home: home).isEmpty)
    }

    /// Крошечный валидный PNG.
    private func png() -> Data {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()

        let tiff = image.tiffRepresentation!
        let rep = NSBitmapImageRep(data: tiff)!
        return rep.representation(using: .png, properties: [:])!
    }
}
