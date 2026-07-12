import Foundation
import Network

/// Раздаёт Monaco по http://127.0.0.1:<порт>/<токен>/ — только на loopback.
///
/// Почему не `file://`: Monaco считает diff и разбирает синтаксис в web worker'ах, а из file://
/// воркеры блокируются политикой безопасности — diff бы просто не рисовался. С нормальным
/// http-origin всё работает штатно. Порт эфемерный, случайный токен в пути закрывает доступ
/// другим процессам на машине.
@MainActor
final class MonacoServer {
    static let shared = MonacoServer()

    /// Сервер не поднялся. Терминальное состояние: ожидающие получают ошибку сразу,
    /// а не висят в `await` вечно.
    struct ServerError: LocalizedError {
        let reason: String
        var errorDescription: String? { "Локальный сервер Monaco не поднялся: \(reason)" }
    }

    private static let tokenLength = 16 // 64 бита энтропии — достаточно против локального перебора

    let token: String
    private var listener: NWListener?
    private var outcome: Result<UInt16, ServerError>?
    private var waiters: [CheckedContinuation<UInt16, Error>] = []
    private let queue = DispatchQueue(label: "remoter.monaco-server")
    private let root: URL

    private init() {
        var t = ""
        for _ in 0..<Self.tokenLength { t.append("0123456789abcdef".randomElement()!) }
        token = t
        root = Self.resolveRoot()
    }

    /// Обычно web-ресурсы лежат в бандле. Переменная окружения нужна тестам (у них свой бандл)
    /// и разработке: можно править editor.js и просто перезапускать, не пересобирая приложение.
    private static func resolveRoot() -> URL {
        if let path = ProcessInfo.processInfo.environment["REMOTER_WEB_ROOT"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        guard let res = Bundle.main.resourceURL else {
            return URL(fileURLWithPath: ".", isDirectory: true)
        }
        return res.appendingPathComponent("web", isDirectory: true)
    }

    /// URL страницы редактора. Ждёт, пока сервер поднимется; если тот не поднялся — бросает,
    /// а не зависает: вызывающий обязан показать ошибку, пустое окно навсегда хуже.
    func editorURL() async throws -> URL {
        let port = try await ready()
        return URL(string: "http://127.0.0.1:\(port)/\(token)/editor.html")!
    }

    /// Куда хук Claude сообщает, что тот закончил работу или ждёт ответа.
    ///
    /// Раньше это делалось ссылкой `remoter://` и командой `open`. Работало, но ценой: `open`
    /// идёт через Launch Services, а те на всякую доставку «переоткрывают» приложение — и AppKit
    /// послушно показывал первую сцену, то есть список проектов. Каждое уведомление распахивало
    /// окно поверх работы. Здесь этой цепочки нет вовсе: хук стучится прямо в наш локальный
    /// сервер, приложение при этом даже не шевелится.
    ///
    /// Не бросает: вызывающие пишут URL в hook-скрипт, где curl и так завершается `|| true`.
    /// При мёртвом сервере возвращаем заведомо нерабочий адрес и пишем в лог — уведомления
    /// не придут, но и никто не зависнет.
    func notifyURL() async -> String {
        do {
            let port = try await ready()
            return "http://127.0.0.1:\(port)/\(token)/notify"
        } catch {
            NSLog("Remoter: notifyURL без сервера: \(error.localizedDescription)")
            return "http://127.0.0.1:0/\(token)/notify"
        }
    }

    private func ready() async throws -> UInt16 {
        if let outcome { return try outcome.get() }
        start()
        // start() мог упасть синхронно (NWListener не создался) — не подвешиваем continuation.
        if let outcome { return try outcome.get() }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    private func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            // Слушаем строго loopback: снаружи машины сервер не виден в принципе.
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            params.allowLocalEndpointReuse = true

            let l = try NWListener(using: params)
            let handler = RequestHandler(root: root, token: token)
            let queue = self.queue // не захватываем self: listener живёт в self, вышел бы цикл
            l.newConnectionHandler = { conn in handler.accept(conn, on: queue) }
            l.stateUpdateHandler = { [weak self, weak l] state in
                switch state {
                case .ready:
                    // Порт обязан быть известен и ненулевым — URL с портом 0 никуда не ведёт.
                    let port = l?.port?.rawValue
                    Task { @MainActor in
                        if let port, port != 0 {
                            self?.publish(.success(port))
                        } else {
                            self?.publish(.failure(ServerError(reason: "listener готов, но порт неизвестен")))
                        }
                    }
                case .failed(let error):
                    Task { @MainActor in
                        self?.publish(.failure(ServerError(reason: String(describing: error))))
                    }
                case .cancelled:
                    Task { @MainActor in
                        self?.publish(.failure(ServerError(reason: "listener отменён")))
                    }
                default:
                    break
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            publish(.failure(ServerError(reason: String(describing: error))))
        }
    }

    private func publish(_ result: Result<UInt16, ServerError>) {
        guard outcome == nil else { return }
        outcome = result
        if case .failure(let e) = result {
            NSLog("Remoter: не удалось поднять локальный сервер: \(e.reason)")
        }
        for w in waiters { w.resume(with: result.mapError { $0 as Error }) }
        waiters.removeAll()
    }
}

/// Минимальный HTTP/1.1: только GET, один запрос на соединение, ответ и закрытие.
/// Держать keep-alive незачем — Monaco тянет свои ~50 файлов один раз при старте окна.
private final class RequestHandler: @unchecked Sendable {
    /// Пределы на запрос: наш единственный «толстый» вход — тело notify-хука (последняя реплика
    /// Claude), и мегабайта ему хватает с запасом. Без пределов любой локальный процесс,
    /// знающий лишь порт (токен для этого не нужен!), мог бы заливать память бесконечным вводом.
    private static let maxHeaderBytes = 16 * 1024
    private static let maxBodyBytes = 1024 * 1024

    private let root: URL
    private let resolvedRootPath: String
    private let token: String

    init(root: URL, token: String) {
        let std = root.standardizedFileURL
        self.root = std
        // Для проверки симлинков — «настоящий» путь корня (сам корень тоже бывает симлинком:
        // /tmp → /private/tmp в тестах с REMOTER_WEB_ROOT).
        self.resolvedRootPath = std.resolvingSymlinksInPath().path
        self.token = token
    }

    func accept(_ conn: NWConnection, on queue: DispatchQueue) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isDone, error in
            guard let self else { return }
            var buf = buffer
            if let chunk { buf.append(chunk) }

            if error != nil || (isDone && buf.isEmpty) {
                conn.cancel()
                return
            }
            // Заголовки целиком ещё не пришли — ждём дальше, но не бесконечно.
            guard let headEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
                if buf.count > Self.maxHeaderBytes {
                    self.send(conn, status: "431 Request Header Fields Too Large", body: Data(), type: "text/plain")
                } else if isDone {
                    conn.cancel()
                } else {
                    self.receive(conn, buffer: buf)
                }
                return
            }
            guard headEnd.lowerBound <= Self.maxHeaderBytes else {
                self.send(conn, status: "431 Request Header Fields Too Large", body: Data(), type: "text/plain")
                return
            }

            let head = String(decoding: buf[..<headEnd.lowerBound], as: UTF8.self)

            // У POST есть тело, и оно вполне может не поместиться в первый пакет: последняя
            // реплика Claude бывает длинной. Ждём, пока приедет ровно столько, сколько обещано.
            let length = Self.contentLength(head)
            guard length <= Self.maxBodyBytes else {
                self.send(conn, status: "413 Content Too Large", body: Data(), type: "text/plain")
                return
            }
            let body = buf[headEnd.upperBound...]
            if body.count < length {
                if isDone { conn.cancel() } else { self.receive(conn, buffer: buf) }
                return
            }

            self.respond(to: head, body: Data(body.prefix(length)), on: conn)
        }
    }

    private static func contentLength(_ head: String) -> Int {
        for line in head.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }

    private func respond(to head: String, body: Data, on conn: NWConnection) {
        guard let requestLine = head.split(separator: "\r\n").first else {
            send(conn, status: "400 Bad Request", body: Data(), type: "text/plain")
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            send(conn, status: "400 Bad Request", body: Data(), type: "text/plain")
            return
        }

        let method = String(parts[0])
        var path = String(parts[1])
        var query = ""
        if let q = path.firstIndex(of: "?") {
            query = String(path[path.index(after: q)...])
            path = String(path[..<q])
        }
        path = path.removingPercentEncoding ?? path

        // Хук Claude: «закончил работу» / «ждёт ответа». Тело — тот самый JSON, который Claude
        // передаёт хуку на stdin; разбирается он уже в приложении.
        if method == "POST", path == "/\(token)/notify" {
            let items = URLComponents(string: "?" + query)?.queryItems ?? []
            let event = items.first { $0.name == "event" }?.value ?? ""
            let project = items.first { $0.name == "project" }?.value ?? ""
            let id = items.first { $0.name == "id" }?.value ?? ""

            Task { @MainActor in
                Notifications.handle(event: event, project64: project, id: id, payload: body)
            }
            send(conn, status: "204 No Content", body: Data(), type: "text/plain")
            return
        }

        guard method == "GET" else {
            send(conn, status: "405 Method Not Allowed", body: Data(), type: "text/plain")
            return
        }

        guard let file = resolve(path), let data = try? Data(contentsOf: file) else {
            log("HTTP 404 \(path)")
            send(conn, status: "404 Not Found", body: Data("not found".utf8), type: "text/plain")
            return
        }
        log("HTTP 200 \(path) (\(data.count) байт)")
        // Monaco внутри vs/ не меняется до пересборки, а весит почти 4 МБ. Разрешаем кешировать,
        // иначе каждое новое окно тянет его заново. Свои editor.html/editor.js — без кеша,
        // чтобы правки в них были видны сразу после перезапуска.
        let immutable = path.contains("/vs/")
        send(
            conn,
            status: "200 OK",
            body: data,
            type: Self.mime(file.pathExtension),
            cache: immutable ? "public, max-age=86400" : "no-store"
        )
    }

    /// Проверяем токен и то, что итоговый путь не вылез за пределы каталога с Monaco
    /// (иначе `../../` в запросе отдал бы наружу любой файл диска).
    private func resolve(_ path: String) -> URL? {
        let prefix = "/\(token)/"
        guard path.hasPrefix(prefix) else { return nil }
        let rel = String(path.dropFirst(prefix.count))
        guard !rel.isEmpty else { return nil }

        let url = root.appendingPathComponent(rel).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { return nil }

        // standardizedFileURL убирает `..`, но не разворачивает симлинки: симлинк внутри
        // каталога, указывающий наружу, прошёл бы проверку выше. Сверяем и реальный путь.
        let real = url.resolvingSymlinksInPath().path
        guard real == resolvedRootPath || real.hasPrefix(resolvedRootPath + "/") else { return nil }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        return url
    }

    /// REMOTER_DEBUG_HTTP=1 — печатать каждый запрос. Без этого сломавшийся ресурс выглядит
    /// просто как «Monaco не работает», а какой именно файл не отдался — не видно.
    ///
    /// Пишем в stderr, а не в stdout: stdout буферизуется, когда это не терминал, и приложение,
    /// закрытое по сигналу, унесло бы весь лог с собой — ровно тогда, когда он и нужен.
    private static let logRequests = ProcessInfo.processInfo.environment["REMOTER_DEBUG_HTTP"] != nil

    private func log(_ line: String) {
        guard Self.logRequests else { return }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private func send(
        _ conn: NWConnection,
        status: String,
        body: Data,
        type: String,
        cache: String = "no-store"
    ) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: \(cache)\r\n"
        head += "Connection: close\r\n\r\n"

        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "ttf": return "font/ttf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "png": return "image/png"
        default: return "application/octet-stream"
        }
    }
}
