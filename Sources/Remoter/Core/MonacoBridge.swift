import Foundation
import WebKit

/// Мост между Swift и Monaco (движок редактора VS Code), живущим внутри WKWebView.
///
/// WebView создаётся один раз на окно и переживает переключение файлов — пересоздавать его на
/// каждый клик было бы и медленно, и заметно морганием. Команды, пришедшие до того, как страница
/// загрузилась, копятся и выполняются пачкой по готовности.
@MainActor
final class MonacoBridge: NSObject, ObservableObject {

    let webView: WKWebView

    // Во всех событиях первым идёт путь: вкладок много, и без него мы бы не знали,
    // о какой именно Monaco рапортует.
    /// ⌘S внутри редактора: Monaco перехватывает сочетание сам и присылает нам текст.
    var onSave: ((String, String) -> Void)?
    var onDirty: ((String, Bool) -> Void)?
    var onStats: ((String, Int, Int) -> Void)?

    private var isReady = false
    private var pending: [String] = []

    override init() {
        let cfg = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()

        // Официальный API вместо KVC-ключа developerExtrasEnabled: приватный ключ мог бы
        // исчезнуть в будущем macOS, и setValue(forKey:) уронил бы приложение исключением.
        webView.isInspectable = true

        // Конфиг копируется при создании WKWebView, поэтому обработчик вешаем на живую копию.
        // Через слабый прокси: WKUserContentController держит обработчик намертво, и, добавь мы
        // сюда себя, окно никогда бы не освободилось.
        let proxy = ScriptProxy()
        proxy.bridge = self
        webView.configuration.userContentController.add(proxy, name: "bridge")
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = self

        Task { [weak self] in await self?.loadEditor() }
    }

    /// Если локальный сервер не поднялся, показываем причину прямо в WebView:
    /// пустое окно без объяснений — худший из вариантов.
    private func loadEditor() async {
        do {
            let url = try await MonacoServer.shared.editorURL()
            webView.load(URLRequest(url: url))
        } catch {
            let reason = error.localizedDescription
            NSLog("Remoter: редактор не загрузился: \(reason)")
            let escaped = reason
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            let html = """
            <!doctype html><meta charset="utf-8">
            <body style="margin:0;display:flex;align-items:center;justify-content:center;height:100vh;\
            background:#1e1e1e;color:#7d7d82;font:13px -apple-system,sans-serif;text-align:center;padding:0 40px">
            <div>Редактор не загрузился: \(escaped)<br>Перезапустите приложение.</div>
            </body>
            """
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    // MARK: - Swift → JS

    func showDiff(title: String, path: String, original: String, modified: String, editable: Bool) {
        call("showDiff", [
            "title": title, "path": path,
            "original": original, "modified": modified,
            "editable": editable,
        ])
    }

    func showFile(title: String, path: String, content: String, editable: Bool) {
        call("showFile", [
            "title": title, "path": path,
            "content": content, "editable": editable,
        ])
    }

    /// Обновление содержимого без пересоздания моделей — сохраняет позицию скролла и курсор.
    /// Это то, что даёт эффект «живого кода», когда Claude правит файл на сервере.
    func update(path: String, original: String?, modified: String) {
        var p: [String: Any] = ["path": path, "modified": modified]
        if let original { p["original"] = original }
        call("update", p)
    }

    /// Вкладку закрыли — освобождаем её модели, иначе они копятся в памяти.
    func closePane(path: String) { call("closePane", ["path": path]) }

    func showMessage(_ text: String) { call("showMessage", ["text": text]) }
    func setTheme(dark: Bool) { call("setTheme", ["dark": dark]) }
    func setFontSize(_ size: Double) { call("setFontSize", ["size": size]) }
    func setSideBySide(_ on: Bool) { call("setSideBySide", ["on": on]) }
    func openFind() { call("openFind", [:]) }

    /// Фокус в редактор. Двумя шагами, и оба нужны: сначала клавиатуру отдаёт окно (иначе она
    /// остаётся в дереве файлов, и стрелки листают его, а не код), потом фокус внутри страницы
    /// забирает сам Monaco.
    func focusEditor() {
        webView.window?.makeFirstResponder(webView)
        call("focusEditor", [:])
    }

    /// Просит Monaco прислать текущий текст — дальше он приедет обратно как событие save.
    func requestSave() { call("requestSave", [:]) }

    private func call(_ fn: String, _ payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload) else {
            // Например NaN в числе: молча выброшенная команда выглядела бы как «кнопка не работает».
            NSLog("Remoter: payload для \(fn) не сериализуется в JSON — вызов пропущен")
            return
        }
        let js = "window.Remoter.\(fn)(\(String(decoding: data, as: UTF8.self)))"
        if isReady {
            evaluate(js)
        } else {
            pending.append(js)
        }
    }

    /// Все вызовы в JS — через одну точку, с логом ошибки: `completionHandler: nil` прятал бы
    /// и упавший Remoter, и синтаксическую ошибку в editor.js.
    private func evaluate(_ js: String) {
        webView.evaluateJavaScript(js) { _, error in
            if let error {
                NSLog("Remoter: ошибка JS-вызова: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - JS → Swift

    fileprivate func handle(_ body: [String: Any]) {
        guard let type = body["t"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            for js in pending { evaluate(js) }
            pending.removeAll()
        case "dirty":
            guard let path = body["path"] as? String else { break }
            onDirty?(path, body["dirty"] as? Bool ?? false)
        case "save":
            guard let path = body["path"] as? String else { break }
            // Без content сохранять нечего. Прежний `?? ""` записал бы на сервер пустой файл.
            guard let content = body["content"] as? String else {
                NSLog("Remoter: событие save без содержимого для \(path) — игнорирую")
                break
            }
            onSave?(path, content)
        case "stats":
            guard let path = body["path"] as? String else { break }
            onStats?(path, body["added"] as? Int ?? 0, body["removed"] as? Int ?? 0)
        case "error":
            // Ошибки страницы (window.onerror и промисы) — в лог приложения: без этого
            // сломавшийся Monaco виден только с открытым Web-инспектором.
            NSLog("Remoter: ошибка в WebView: \(body["text"] as? String ?? "<без текста>")")
        default:
            break
        }
    }
}

extension MonacoBridge: WKNavigationDelegate {
    /// Процесс WebContent убит (чаще всего OOM на огромном diff) — без этого хендлера окно
    /// оставалось бы белым навсегда, а все команды молча уходили бы в мёртвый процесс.
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            NSLog("Remoter: процесс WebContent упал — перезагружаю редактор")
            self.isReady = false
            self.webView.reload()
        }
    }
}

private final class ScriptProxy: NSObject, WKScriptMessageHandler {
    weak var bridge: MonacoBridge?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { bridge?.handle(body) }
    }
}
