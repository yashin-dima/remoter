import AppKit
import WebKit
import UserNotifications

/// `Remoter.app/Contents/MacOS/Remoter --selfcheck` — проверяет, что веб-половина жива:
/// Monaco нашёлся в бандле, отдался с локального сервера, посчитал diff и нарисовал
/// зелёные и красные строки.
///
/// Почему это не обычный XCTest: WebKit считает страницу скрытой в любом окне, которое
/// не принадлежит нормальному GUI-приложению, и замораживает отрисовку — в тестовом процессе
/// Monaco не рисует вообще ничего. Проверять рендеринг можно только в настоящем приложении.
///
/// Полезно после каждого обновления Monaco: молча сломавшийся редактор выглядит просто
/// как «diff не появился», и без этой проверки причину пришлось бы искать руками.
@MainActor
enum SelfCheck {

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--selfcheck")
    }

    static func run() {
        Task {
            let web = await perform()
            let notif = await checkNotifications()
            let ok = web && notif
            print(ok ? "\n✅ Всё в порядке" : "\n❌ Что-то сломано")
            exit(ok ? 0 : 1)
        }
    }

    /// Уведомления: Claude закончил работу или ждёт ответа.
    ///
    /// Проверяется вся цепочка от ссылки до доставленного уведомления. Не выдано разрешение —
    /// это не поломка, а настройка системы, и говорится об этом прямо: молчащие уведомления
    /// иначе выглядят как сломанные.
    private static func checkNotifications() async -> Bool {
        Notifications.setUp()
        try? await Task.sleep(nanoseconds: 800_000_000)

        guard await Notifications.isAuthorized() else {
            report("уведомления разрешены", ok: false,
                   detail: "нет. Системные настройки → Уведомления → Remoter")
            return true
        }
        report("уведомления разрешены", ok: true)

        let project = "Самопроверка"
        let b64 = Data(project.utf8).base64EncodedString()

        Notifications.handle(
            event: "Stop",
            project64: b64,
            id: UUID().uuidString,
            payload: Data(#"{"last_assistant_message":"Проверка связи"}"#.utf8)
        )

        try? await Task.sleep(nanoseconds: 1_500_000_000)

        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        let found = delivered.contains { $0.request.content.title == project }
        report("уведомление доставлено", ok: found)

        // Убираем за собой: тестовое уведомление в центре уведомлений никому не нужно.
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: delivered
                .filter { $0.request.content.title == project }
                .map(\.request.identifier)
        )
        return found
    }

    private static func perform() async -> Bool {
        let bridge = MonacoBridge()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Remoter — самопроверка"
        window.contentView = bridge.webView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let loaded = await wait("Monaco загрузился", bridge, condition: { web in
            (try? await web.evaluateJavaScript("window.monaco && window.Remoter ? 1 : 0")) as? Int == 1
        })
        guard loaded else { return false }

        bridge.showDiff(
            title: "main.py",
            path: "/srv/app/src/main.py",
            original: "def hello():\n    print(\"hi\")\n    return 1\n",
            modified: "def hello():\n    print(\"HELLO\")\n    print(\"new\")\n    return 42\n",
            editable: true
        )

        let rendered = await wait("код отрисован", bridge, condition: { web in
            let n = (try? await web.evaluateJavaScript("document.querySelectorAll('.view-line').length")) as? Int ?? 0
            return n > 0
        })
        guard rendered else { return false }

        let highlighted = await wait("diff посчитан и подсвечен", bridge, condition: { web in
            let ins = (try? await web.evaluateJavaScript("document.querySelectorAll('.line-insert').length")) as? Int ?? 0
            let del = (try? await web.evaluateJavaScript("document.querySelectorAll('.line-delete').length")) as? Int ?? 0
            return ins > 0 && del > 0
        })
        guard highlighted else {
            await dumpDOM(bridge)
            return false
        }

        let lang = (try? await bridge.webView.evaluateJavaScript(
            "monaco.editor.getModels().map(m => m.getLanguageId()).join(',')"
        )) as? String ?? ""
        report("язык определён по имени файла", ok: lang.contains("python"), detail: lang)

        let tabsOK = await checkTabs(bridge)

        let panes = (try? await bridge.webView.evaluateJavaScript(
            "document.querySelectorAll('.monaco-diff-editor .editor').length"
        )) as? Int ?? 0
        report("diff двухколоночный", ok: panes >= 2, detail: "колонок: \(panes)")

        let errors = (try? await bridge.webView.evaluateJavaScript(
            "(window.__errors || []).join(' | ') || 'нет'"
        )) as? String ?? "?"
        report("ошибок JS нет", ok: errors == "нет", detail: errors)

        return lang.contains("python") && panes >= 2 && tabsOK && errors == "нет"
    }

    /// Вкладки держат каждая своё состояние: ушёл на соседнюю, вернулся — ты там же, где был.
    /// Без этого вкладки бессмысленны: прыгать между файлами, каждый раз проваливаясь в начало,
    /// хуже, чем не иметь вкладок вовсе.
    private static func checkTabs(_ bridge: MonacoBridge) async -> Bool {
        let long = (1...400).map { "строка \($0)" }.joined(separator: "\n")

        bridge.showFile(title: "a.txt", path: "/tmp/a.txt", content: long, editable: true)
        bridge.showFile(title: "b.txt", path: "/tmp/b.txt", content: "другой файл\n", editable: true)

        // Возвращаемся на первую и прокручиваем её.
        bridge.showFile(title: "a.txt", path: "/tmp/a.txt", content: long, editable: true)
        _ = try? await bridge.webView.evaluateJavaScript(
            "monaco.editor.getEditors()[0].setScrollTop(2000), 1"
        )
        try? await Task.sleep(nanoseconds: 300_000_000)

        let before = (try? await bridge.webView.evaluateJavaScript(
            "monaco.editor.getEditors()[0].getScrollTop()"
        )) as? Double ?? 0

        // Уходим на вторую и возвращаемся.
        bridge.showFile(title: "b.txt", path: "/tmp/b.txt", content: "другой файл\n", editable: true)
        try? await Task.sleep(nanoseconds: 300_000_000)
        bridge.showFile(title: "a.txt", path: "/tmp/a.txt", content: long, editable: true)
        try? await Task.sleep(nanoseconds: 400_000_000)

        let after = (try? await bridge.webView.evaluateJavaScript(
            "monaco.editor.getEditors()[0].getScrollTop()"
        )) as? Double ?? -1

        let ok = before > 0 && abs(after - before) < 2
        report("вкладки помнят позицию скролла", ok: ok, detail: "было \(Int(before)), стало \(Int(after))")
        return ok
    }

    private static func wait(
        _ what: String,
        _ bridge: MonacoBridge,
        timeout: TimeInterval = 20,
        condition: (WKWebView) async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition(bridge.webView) {
                report(what, ok: true)
                return true
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        report(what, ok: false, detail: "не дождались за \(Int(timeout)) с")
        return false
    }

    /// Когда подсветка не появилась, важно понять почему: diff не посчитался или Monaco
    /// сменил имена классов. Печатаем то, что реально есть в DOM.
    private static func dumpDOM(_ bridge: MonacoBridge) async {
        func js(_ s: String) async -> String {
            let r = try? await bridge.webView.evaluateJavaScript(s)
            return String(describing: r ?? "nil")
        }
        print("\n  Что в DOM на самом деле:")
        print("    строк кода:", await js("document.querySelectorAll('.view-line').length"))
        print("    lineChanges:", await js("(monaco.editor.getDiffEditors()[0]?.getLineChanges() || []).length"))
        print("    ошибки JS:", await js("(window.__errors || []).join(' | ') || 'нет'"))
        print("    классы с insert/delete/diff:", await js("""
        Array.from(new Set(
          Array.from(document.querySelectorAll('*'))
            .flatMap(e => Array.from(e.classList))
            .filter(c => /insert|delete|diff|changed|modified/i.test(c))
        )).sort().join(' ')
        """))
    }

    private static func report(_ what: String, ok: Bool, detail: String = "") {
        let mark = ok ? "✓" : "✗"
        let suffix = detail.isEmpty ? "" : " — \(detail)"
        print("  \(mark) \(what)\(suffix)")
    }
}
