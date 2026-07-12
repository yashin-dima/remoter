import Foundation

/// Файлы в локальной папке проекта — документация, заметки, CLAUDE.md.
///
/// Отдельно от RemoteFS намеренно: здесь не нужны ни ssh, ни предохранители от обрыва связи,
/// зато нужен Finder и обычные локальные права. Смешивать их в один слой значило бы тащить
/// сложность одного мира в другой.
enum LocalFS {

    static func list(_ dir: String) -> [RemoteEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }

        var out: [RemoteEntry] = []
        // Скрытые файлы не показываем: .claude с хуками и .attachments со скриншотами — это
        // машинерия, а не документация пользователя. Захочет — откроет в Finder.
        for name in names where !name.hasPrefix(".") {
            let path = dir + "/" + name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            out.append(RemoteEntry(name: name, path: path, isDir: isDir.boolValue))
        }
        // Тот же порядок, что и в серверном дереве, — общий компаратор.
        return out.finderSorted()
    }

    static func read(_ path: String) -> RemoteFile {
        guard let data = FileManager.default.contents(atPath: path) else { return .missing }
        guard data.count <= RemoteFS.maxFileSize else { return .tooLarge(bytes: data.count) }
        return RemoteFS.decode(data)
    }

    static func write(_ path: String, content: String) throws {
        try Data(content.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func createFile(dir: String, name: String) throws -> String {
        let path = dir + "/" + name
        guard !FileManager.default.fileExists(atPath: path) else { return path }
        try Data().write(to: URL(fileURLWithPath: path))
        return path
    }

    static func createDirectory(dir: String, name: String) throws {
        try FileManager.default.createDirectory(
            atPath: dir + "/" + name,
            withIntermediateDirectories: true
        )
    }

    /// Удаление — в корзину, а не насовсем. Это локальные файлы пользователя: пусть у него
    /// останется возможность передумать (на сервере такой роскоши нет).
    static func trash(_ path: String) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }

    static func rename(_ path: String, to newName: String) throws {
        guard !newName.isEmpty, !newName.contains("/") else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.moveItem(atPath: path, toPath: dir + "/" + newName)
    }
}
