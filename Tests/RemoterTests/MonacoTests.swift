import XCTest
import WebKit
@testable import Remoter

/// Веб-половина: локальный сервер и загрузка Monaco.
///
/// Отрисовку здесь проверить нельзя: WebKit считает страницу скрытой в любом окне, которое не
/// принадлежит нормальному GUI-приложению, и замораживает рендеринг — в тестовом процессе Monaco
/// не рисует ни строчки. Поэтому картинку проверяет `Remoter.app --selfcheck` (см. SelfCheck.swift),
/// а сюда вынесено то, что от рендеринга не зависит, — и в первую очередь адрес воркера.
@MainActor
final class MonacoTests: XCTestCase {

    private var bridge: MonacoBridge!

    override func setUp() async throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["REMOTER_WEB_ROOT"] == nil,
            "REMOTER_WEB_ROOT не задан — укажите путь к каталогу Web"
        )
        bridge = MonacoBridge()
        try await waitFor("Monaco загрузился") {
            let r = try? await self.js("window.monaco && window.Remoter ? 1 : 0")
            return (r as? Int) == 1
        }
    }

    override func tearDown() async throws { bridge = nil }

    /// Регрессия, которая стоила больше всего: Monaco выводил адрес воркера от корня сервера
    /// (`/vs/base/worker/workerMain.js`, без токена), получал 404 и молча ронял воркер.
    /// Diff считается именно в воркере — редактор при этом выглядит рабочим, подсветка синтаксиса
    /// на месте, а зелёного и красного не появляется никогда.
    func testWorkerURLKeepsTheTokenPrefix() async throws {
        let url = try await js("self.MonacoEnvironment.getWorkerUrl()") as? String ?? ""
        let token = MonacoServer.shared.token

        XCTAssertTrue(url.contains("/\(token)/"), "в адресе воркера потерялся токен: \(url)")
        XCTAssertTrue(url.hasSuffix("vs/base/worker/workerMain.js"), "неожиданный адрес воркера: \(url)")

        // И этот адрес действительно отдаётся сервером, а не 404.
        let status = try await bridge.webView.callAsyncJavaScript(
            "const r = await fetch(self.MonacoEnvironment.getWorkerUrl()); return r.status;",
            contentWorld: .page
        ) as? Int
        XCTAssertEqual(status, 200, "сервер не отдаёт воркер по тому адресу, который просит Monaco")
    }

    /// Токен в пути — не украшение: без него любой процесс на машине мог бы читать файлы
    /// через наш локальный сервер. И выйти за пределы каталога с Monaco тоже нельзя.
    func testServerRefusesRequestsWithoutTokenOrOutsideRoot() async throws {
        let port = try XCTUnwrap(URL(string: bridge.webView.url?.absoluteString ?? "")?.port)

        func status(_ path: String) async throws -> Int {
            let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }

        let token = MonacoServer.shared.token
        let ok = try await status("/\(token)/editor.html")
        XCTAssertEqual(ok, 200)

        let noToken = try await status("/editor.html")
        XCTAssertEqual(noToken, 404, "без токена сервер не должен ничего отдавать")

        let escape = try await status("/\(token)/../../../../etc/hosts")
        XCTAssertNotEqual(escape, 200, "выход за пределы каталога Monaco должен блокироваться")
    }

    /// Регрессия C2: после ⌘S Swift пишет файл и присылает тот же текст через update —
    /// вкладка обязана перестать быть «грязной». Раньше update сравнивал модель со СТАРЫМ
    /// baseline, считал вкладку грязной навсегда и блокировал все живые обновления.
    func testUpdateAfterSaveClearsDirtyAndUnblocksLiveUpdates() async throws {
        var events: [(path: String, dirty: Bool)] = []
        bridge.onDirty = { events.append(($0, $1)) }

        _ = try await js("window.Remoter.showFile({path:'/x.txt', title:'x', content:'hello', editable:true}); 0")

        // «Печатаем» в модель — так же, как это сделал бы пользователь.
        _ = try await js("""
        (function () {
          const m = monaco.editor.getModels().find((m) => m.getValue() === 'hello');
          m.pushEditOperations([], [{ range: m.getFullModelRange(), text: 'hello world' }], () => null);
          return 0;
        })()
        """)
        try await waitFor("dirty=true после правки") {
            events.contains { $0.path == "/x.txt" && $0.dirty }
        }

        // Swift «сохранил» и прислал тот же текст обратно — dirty должен погаснуть.
        _ = try await js("window.Remoter.update({path:'/x.txt', modified:'hello world'}); 0")
        try await waitFor("dirty=false после update с тем же текстом") {
            events.last.map { $0.path == "/x.txt" && $0.dirty == false } ?? false
        }

        // И следующее живое обновление с сервера снова применяется.
        _ = try await js("window.Remoter.update({path:'/x.txt', modified:'v2'}); 0")
        try await waitFor("следующий update применился") {
            let v = try? await self.js("monaco.editor.getModels().some((m) => m.getValue() === 'v2') ? 1 : 0")
            return (v as? Int) == 1
        }
    }

    /// Запрос с непомерными заголовками не буферизуется бесконечно, а отклоняется:
    /// сервер локальный, но заливать память приложения может любой процесс, знающий порт.
    func testRejectsOversizedHeaders() async throws {
        let port = try XCTUnwrap(bridge.webView.url?.port)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(MonacoServer.shared.token)/editor.html")!)
        req.setValue(String(repeating: "a", count: 20_000), forHTTPHeaderField: "X-Padding")

        let (_, response) = try await URLSession.shared.data(for: req)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 431)
    }

    /// Язык определяем через реестр Monaco, а не своей таблицей расширений — проверяем,
    /// что реестр вообще отвечает и знает то, с чем реально работают.
    func testDetectsLanguagesByFilename() async throws {
        func language(of path: String) async throws -> String {
            let script = """
            (function () {
              const name = '\(path)'.split('/').pop();
              const dot = name.lastIndexOf('.');
              const ext = dot > 0 ? name.slice(dot) : '';
              for (const l of monaco.languages.getLanguages()) {
                if (l.filenames && l.filenames.indexOf(name) >= 0) return l.id;
                if (ext && l.extensions && l.extensions.indexOf(ext) >= 0) return l.id;
              }
              return 'plaintext';
            })()
            """
            return try await js(script) as? String ?? ""
        }

        let swift = try await language(of: "/srv/app/Core/Git.swift")
        XCTAssertEqual(swift, "swift")

        let py = try await language(of: "/srv/app/src/main.py")
        XCTAssertEqual(py, "python")

        // Файлы без расширения тоже должны узнаваться — по имени целиком.
        let docker = try await language(of: "/srv/app/Dockerfile")
        XCTAssertEqual(docker, "dockerfile")
    }

    // MARK: - Вспомогательное

    private func js(_ script: String) async throws -> Any? {
        try await bridge.webView.evaluateJavaScript(script)
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 25, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Не дождались: \(what)")
    }
}
