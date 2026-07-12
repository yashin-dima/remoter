import Foundation

/// Результат запуска внешнего процесса.
struct ProcResult {
    var out: Data
    var err: String
    var code: Int32

    var ok: Bool { code == 0 }
    var text: String { String(decoding: out, as: UTF8.self) }
    /// stdout без хвостового перевода строки — удобно для однострочных ответов вроде `git rev-parse`.
    var line: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum ProcError: LocalizedError {
    case launchFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .launchFailed(let m): return "Не удалось запустить процесс: \(m)"
        case .timedOut: return "Команда не ответила вовремя"
        }
    }
}

enum Proc {
    /// ssh может умереть, пока мы пишем ему в stdin (обрыв сети, сработал сторож) — тогда
    /// запись получает SIGPIPE, который по умолчанию убивает всё приложение. Гасим сигнал
    /// один раз на процесс: ошибка записи и так приходит из write(contentsOf:) как исключение.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// Через сколько после SIGTERM добивать зависший процесс SIGKILL.
    private static let killEscalationDelay: TimeInterval = 5

    /// Запускает процесс, ждёт завершения, возвращает stdout/stderr/код.
    /// stdout и stderr читаются параллельно с ожиданием — иначе большой вывод забивает pipe и всё виснет.
    static func run(
        _ executable: String,
        _ args: [String],
        env: [String: String]? = nil,
        stdin: Data? = nil,
        timeout: TimeInterval = 60,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> ProcResult {
        _ = ignoreSIGPIPE
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = args
                if let env {
                    var e = ProcessInfo.processInfo.environment
                    for (k, v) in env { e[k] = v }
                    p.environment = e
                }

                let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
                p.standardOutput = outPipe
                p.standardError = errPipe
                p.standardInput = inPipe

                do { try p.run() } catch {
                    cont.resume(throwing: ProcError.launchFailed(error.localizedDescription))
                    return
                }

                // Сторож: снимает зависшую команду, чтобы UI не залипал навсегда.
                // SIGTERM процесс может проигнорировать — тогда добиваем SIGKILL,
                // иначе waitUntilExit не вернётся и вся async-задача повиснет.
                let timedOutLock = NSLock()
                var timedOut = false
                let watchdog = DispatchWorkItem {
                    guard p.isRunning else { return }
                    timedOutLock.withLock { timedOut = true }
                    p.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + killEscalationDelay) {
                        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

                var outData = Data(), errData = Data()
                let group = DispatchGroup()

                group.enter()
                DispatchQueue.global().async {
                    // Пишем кусками, а не одним махом: только так можно честно показать прогресс
                    // загрузки — pipe принимает ровно столько, сколько ssh успел отправить,
                    // так что счётчик записанных байт и есть реальный прогресс передачи.
                    // write(contentsOf:) — throwing-вариант: если ssh умер посреди записи,
                    // получаем EPIPE как ошибку (а не SIGPIPE-крэш) и просто перестаём писать —
                    // код завершения процесса расскажет, что пошло не так.
                    if let stdin {
                        let handle = inPipe.fileHandleForWriting
                        let chunk = 64 * 1024
                        var sent = 0
                        while sent < stdin.count {
                            let end = min(sent + chunk, stdin.count)
                            do { try handle.write(contentsOf: stdin[sent..<end]) } catch { break }
                            sent = end
                            onProgress?(sent, stdin.count)
                        }
                    }
                    try? inPipe.fileHandleForWriting.close()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                p.waitUntilExit()
                group.wait()
                watchdog.cancel()

                if timedOutLock.withLock({ timedOut }) {
                    cont.resume(throwing: ProcError.timedOut)
                    return
                }
                cont.resume(returning: ProcResult(
                    out: outData,
                    err: String(decoding: errData, as: UTF8.self),
                    code: p.terminationStatus
                ))
            }
        }
    }
}

extension Proc {
    /// Синхронный запуск — только для коротких проверок вроде «есть ли команда в PATH».
    /// Для всего остального есть async-версия: блокировать поток ради ssh недопустимо.
    /// stderr читается параллельно (болтливый профиль шелла иначе забьёт pipe и всё повиснет),
    /// а сторож с таймаутом гарантирует, что «короткая проверка» не станет вечной.
    static func runSync(_ executable: String, _ args: [String], timeout: TimeInterval = 10) throws -> ProcResult {
        _ = ignoreSIGPIPE
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()

        let timedOutLock = NSLock()
        var timedOut = false
        let watchdog = DispatchWorkItem {
            guard p.isRunning else { return }
            timedOutLock.withLock { timedOut = true }
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + killEscalationDelay) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        group.wait()
        watchdog.cancel()

        if timedOutLock.withLock({ timedOut }) { throw ProcError.timedOut }
        return ProcResult(out: data, err: String(decoding: errData, as: UTF8.self), code: p.terminationStatus)
    }
}

/// Экранирование для POSIX-шелла: оборачиваем в одинарные кавычки, а сами кавычки бьём на '\''.
func shq(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
