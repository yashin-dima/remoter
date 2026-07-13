import XCTest
import SwiftTerm
@testable import Remoter

/// Терминал с подменённым делегатом.
///
/// Подмена нужна, чтобы перехватывать нажатые ссылки: SwiftTerm иначе зовёт `NSWorkspace.open`,
/// и на пути к файлу (`Sources/Core/Git.swift`) macOS отвечает «не удалось найти программу».
/// Но через того же делегата идёт **ввод с клавиатуры** — забудь мы переслать один метод,
/// и терминал онемел бы: буквы печатаются, а в процесс не доходят. Молча.
///
/// Поэтому здесь гоняется ровно тот путь, которым идёт нажатая клавиша: делегат → процесс →
/// вывод на экране терминала.
@MainActor
final class TerminalDelegateTests: XCTestCase {

    /// Главное: после подмены делегата ввод по-прежнему доходит до процесса.
    func testTypingReachesTheProcessAfterDelegateSwap() async throws {
        let view = DropTerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        view.startProcess(
            executable: "/bin/sh",
            args: [],
            environment: Terminal.getEnvironmentVariables(termName: "xterm-256color")
        )
        defer { view.process.terminate() }

        // Ровно так SwiftTerm отдаёт нажатую клавишу: не напрямую в процесс, а через делегата.
        view.terminalDelegate?.send(source: view, data: ArraySlice(Array("echo ДОЕХАЛО\n".utf8)))

        let seen = await waitForText("ДОЕХАЛО", in: view, seconds: 10)
        XCTAssertTrue(seen, "после подмены делегата ввод не доходит до процесса — терминал онемел")
    }

    /// Ссылку перехватываем мы, а не система: путь к файлу должен доехать до приложения,
    /// а не уйти в NSWorkspace с ошибкой «не удалось найти программу».
    func testLinkClickIsHandedToTheApp() {
        let view = DropTerminalView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))

        var opened: String?
        view.onOpenLink = { opened = $0 }

        view.terminalDelegate?.requestOpenLink(
            source: view, link: "Sources/Remoter/Core/Git.swift:42", params: [:])

        XCTAssertEqual(opened, "Sources/Remoter/Core/Git.swift:42",
                       "ссылка ушла мимо приложения — значит, в NSWorkspace, где её и не открыть")
    }

    /// Горячие клавиши работают в ТОМ терминале, где фокус.
    ///
    /// Баг, ради которого этот тест и написан: `performKeyEquivalent` AppKit рассылает по ДЕРЕВУ
    /// view, а не по фокусу — первый, кто ответит «да», тот и обработал. Терминалов в окне
    /// несколько, и все смонтированы разом, поэтому ⌘V перехватывал тот, кто просто раньше стоит
    /// в дереве: человек печатал в Claude, а вставлялось в терминал внизу. По той же причине ⌘V
    /// уводился и из редактора кода.
    func testShortcutsGoToTheFocusedTerminalNotTheFirstInTheViewTree() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = container

        // Первый в дереве — тот, кто раньше и перехватывал чужие сочетания.
        let firstInTree = DropTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        let focused = DropTerminalView(frame: NSRect(x: 0, y: 300, width: 800, height: 300))
        container.addSubview(firstInTree)
        container.addSubview(focused)

        for term in [firstInTree, focused] {
            // `cat` возвращает эхом всё, что в него вставили, — по нему и видно, кто получил ⌘V.
            term.startProcess(executable: "/bin/cat", args: [],
                              environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"))
        }
        defer { firstInTree.process.terminate(); focused.process.terminate() }

        window.makeFirstResponder(focused)

        // Буфер обмена общий на систему — прогон тестов его перезапишет. Иначе вставку не проверить.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("ВСТАВКА_СЮДА", forType: .string)

        let paste = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))

        XCTAssertTrue(window.performKeyEquivalent(with: paste), "⌘V не обработал никто")

        let landedWhereFocused = await waitForText("ВСТАВКА_СЮДА", in: focused, seconds: 10)
        XCTAssertTrue(landedWhereFocused, "вставка ушла не в тот терминал, где фокус")
        XCTAssertFalse(screenText(of: firstInTree).contains("ВСТАВКА_СЮДА"),
                       "вставку перехватил терминал, который просто раньше стоит в дереве view")
    }

    private func waitForText(_ needle: String, in view: DropTerminalView, seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if screenText(of: view).contains(needle) { return true }
        }
        return false
    }

    /// Что видно на экране терминала — по строкам буфера.
    private func screenText(of view: DropTerminalView) -> String {
        let term = view.getTerminal()
        return (0..<term.rows)
            .compactMap { term.getLine(row: $0)?.translateToString(trimRight: true) }
            .joined(separator: "\n")
    }
}
