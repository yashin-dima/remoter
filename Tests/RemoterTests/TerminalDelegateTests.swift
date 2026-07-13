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
