import XCTest
@testable import Remoter

/// Проверка стенда — одна на все тесты, и она принципиально отличает «стенда нет» от «стенд есть,
/// но соединение не встало».
///
/// Раньше это было одним `XCTSkipIf(!isConnected, "sshd не поднят")`, и разница терялась: любая
/// поломка соединения выглядела пропуском. Так и вышло — сокет мультиплексора перестал создаваться
/// (путь вылез за лимит unix-сокета), а прогон бодро отрапортовал «passed», просто пропустив
/// половину тестов. Зелёный прогон, не проверивший ничего, хуже красного.
enum TestStand {

    /// Задан ли стенд (`REMOTER_TEST_REPO` из `Tests/local-sshd.sh`).
    static var isConfigured: Bool {
        ProcessInfo.processInfo.environment["REMOTER_TEST_REPO"]?.isEmpty == false
    }

    /// Пропускает тест, если стенда нет вовсе. Если стенд задан, а соединения нет — валит тест
    /// с настоящей причиной от ssh, вместо того чтобы молча пройти мимо.
    static func require(_ state: SSHConnection.State, file: StaticString = #filePath,
                        line: UInt = #line) throws {
        guard isConfigured else {
            throw XCTSkip("стенда нет — нужен ./Tests/local-sshd.sh")
        }
        guard state.isConnected else {
            XCTFail("стенд задан, но соединение не встало: \(state)", file: file, line: line)
            throw XCTSkip("соединение не встало")
        }
    }
}
