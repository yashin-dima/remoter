import Foundation

// Серверное дерево файлов: загрузка каталогов по ssh, раскрытие, git-бейджи.
// Общая логика раскрытия и развёртки в плоский список — в FileTreeState;
// локальное дерево (папка проекта на Mac) — в WorkspaceModel+LocalPanel.swift.

extension WorkspaceModel {

    func loadDir(_ path: String) async {
        tree.loading.insert(path)
        rebuildRows()
        defer { tree.loading.remove(path) }

        do {
            tree.children[path] = try await RemoteFS.list(conn: conn, dir: path)
        } catch {
            tree.children[path] = []
            errorMessage = "Не удалось прочитать \(path): \(error.localizedDescription)"
        }
    }

    func reloadExpandedDirs() async {
        for dir in tree.expanded where tree.children[dir] != nil {
            tree.children[dir] = (try? await RemoteFS.list(conn: conn, dir: dir)) ?? tree.children[dir]
        }
    }

    /// Перечитывает один каталог — после вставки, удаления или загрузки файлов в него.
    func reloadDir(_ dir: String) async {
        guard tree.children[dir] != nil else { return }
        tree.children[dir] = (try? await RemoteFS.list(conn: conn, dir: dir)) ?? tree.children[dir]
        rebuildRows()
    }

    func toggle(_ entry: RemoteEntry) {
        guard entry.isDir else { return }
        let needsLoad = tree.toggle(entry)
        rebuildRows()
        if let path = needsLoad {
            Task {
                await loadDir(path)
                rebuildRows()
            }
        }
    }

    func rebuildRows() {
        rows = tree.rows(from: basePath)
    }

    /// Путь относительно корня репозитория — то, чем оперирует git.
    func relPath(_ absPath: String) -> String? {
        guard let root = repoRoot else { return nil }
        guard absPath.hasPrefix(root + "/") else { return nil }
        return String(absPath.dropFirst(root.count + 1))
    }

    func kind(for entry: RemoteEntry) -> ChangeKind? {
        guard let rel = relPath(entry.path) else { return nil }
        return kindByPath[rel]
    }

    func hasChangesInside(_ entry: RemoteEntry) -> Bool {
        guard entry.isDir, let rel = relPath(entry.path) else { return false }
        return changedDirs.contains(rel)
    }
}
