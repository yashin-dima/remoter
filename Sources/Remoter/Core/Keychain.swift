import Foundation
import Security

/// Пароли от серверов — в Keychain, и только в нём.
///
/// Список проектов (`workspaces.json`) лежит на диске открытым JSON'ом: его читает любой процесс
/// пользователя, он уезжает в бэкапы Time Machine и в синхронизацию папки. Паролю там не место —
/// поэтому в `Workspace` его нет ни одним полем, и в файл он не попадает даже случайно.
///
/// Пароль привязан к СЕРВЕРУ, а не к проекту. На одном хосте обычно живёт несколько проектов, и
/// вводить один и тот же пароль для каждого — работа на ровном месте. Ключ — то же, что видит ssh:
/// строка хоста (возможно, с `user@`) и порт.
///
/// Ключи и agent это никак не отменяет: пароль спрашивается только там, где сервер сам просит
/// пароль. Есть ключ — ssh войдёт по ключу, и сохранённый пароль не понадобится.
enum Keychain {

    private static let service = "Remoter SSH"

    /// Тесты не должны ни читать, ни писать настоящую связку ключей — как и настоящий список
    /// проектов (см. WorkspaceStore). Под тестами храним в памяти процесса и умираем вместе с ним.
    private static let isTest = NSClassFromString("XCTestCase") != nil
    nonisolated(unsafe) private static var fake: [String: String] = [:]

    /// Один сервер — один пароль. Порт в ключе, потому что `example.com` и `example.com:2222`
    /// вполне могут оказаться разными машинами.
    static func account(host: String, port: Int?) -> String {
        "\(host.trimmingCharacters(in: .whitespaces)):\(port ?? 22)"
    }

    static func password(host: String, port: Int?) -> String? {
        let account = account(host: host, port: port)
        guard !isTest else { return fake[account] }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8),
              !s.isEmpty
        else { return nil }
        return s
    }

    static func hasPassword(host: String, port: Int?) -> Bool {
        password(host: host, port: port) != nil
    }

    /// Пустой пароль — это «пароля нет», а не «пароль из нуля символов»: иначе в связке остался бы
    /// мусорный элемент, а ssh получал бы пустую строку вместо того, чтобы спросить человека.
    static func save(_ password: String, host: String, port: Int?) {
        let account = account(host: host, port: port)
        guard !password.isEmpty else { return delete(host: host, port: port) }
        guard !isTest else { fake[account] = password; return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(password.utf8)

        // Сначала пробуем обновить существующий: SecItemAdd на уже занятый ключ вернул бы
        // errSecDuplicateItem, и пароль молча не сохранился бы.
        let updated = SecItemUpdate(query as CFDictionary,
                                    [kSecValueData as String: data] as CFDictionary)
        if updated == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            // Пароль нужен фоновому ssh — в том числе сразу после разлочки по Touch ID, когда
            // окно приложения ещё не открывали. ThisDeviceOnly: в iCloud-связку не уезжает.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(add as CFDictionary, nil)
            if status != errSecSuccess {
                NSLog("Remoter: не удалось сохранить пароль для %@ в Keychain (код %d)",
                      account, Int(status))
            }
        } else if updated != errSecSuccess {
            NSLog("Remoter: не удалось обновить пароль для %@ в Keychain (код %d)",
                  account, Int(updated))
        }
    }

    static func delete(host: String, port: Int?) {
        let account = account(host: host, port: port)
        guard !isTest else { fake[account] = nil; return }

        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
