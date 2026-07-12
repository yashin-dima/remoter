import Foundation

/// Страховка от прогона тестов поверх настоящих данных пользователя.
///
/// История, ради которой это написано: тесты заводят проекты, провижнят папки и убирают за собой.
/// Пути к данным переопределяются переменными окружения (`REMOTER_HOME`, `REMOTER_STORE`,
/// `REMOTER_SOCKETS`) — и пока их задают, всё честно. Но забыть переменную ничего не стоит:
/// достаточно набрать `swift test` вместо длинной команды из `Tests/local-sshd.sh` — и прогон
/// молча уходит работать с настоящим списком проектов и настоящей папкой `~/Remoter`. Однажды
/// уборка после такого прогона стёрла все проекты разом; в другой раз тесты насыпали в неё
/// два десятка папок с именами фикстур.
///
/// Поэтому забывчивость больше не наказывается потерей данных: под тестами пути, которые не
/// переопределили явно, уводятся во временный каталог этого процесса. Настоящие данные для
/// тестового процесса просто недостижимы — не по договорённости, а физически.
enum TestIsolation {

    /// Идёт ли прогон тестов. XCTest линкуется только в тестовую сборку — в приложении этого
    /// класса нет, так что проверка честная и не зависит от того, кто как запустил процесс.
    static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

    /// Песочница этого тестового процесса. Своя на процесс — параллельные прогоны не мешают
    /// друг другу, а `swift test` не оставляет следов в доме пользователя.
    ///
    /// `/tmp`, а не `NSTemporaryDirectory()`, и это не вкусовщина: у unix-сокета путь ограничен
    /// 104 байтами, а ssh дописывает к нему свой временный суффикс. `TMPDIR` на маке выглядит как
    /// `/var/folders/9q/nx7s7…/T/` — одного его хватает, чтобы сокет мультиплексора не создался
    /// вовсе, и ssh падал с «path too long». Тесты при этом выглядели просто пропущенными.
    private static let sandbox: URL = {
        let dir = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("remoter-tests-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Настоящий путь — или подменённый на песочницу, если мы под тестами.
    ///
    /// `real` вычисляется лениво: под тестами он не должен даже создаваться на диске.
    static func path(_ name: String, real: () -> URL) -> URL {
        guard isRunningTests else { return real() }

        let substitute = sandbox.appendingPathComponent(name, isDirectory: true)
        NSLog("""
            Remoter: тест не задал переменную для «\(name)» — путь уведён в песочницу \
            \(substitute.path). Настоящие данные пользователя тестам недоступны; \
            полный прогон — командой из Tests/local-sshd.sh.
            """)
        try? FileManager.default.createDirectory(at: substitute, withIntermediateDirectories: true)
        return substitute
    }
}
