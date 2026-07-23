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

    /// Кнопка «Обновить» над деревом: перечитать раскрытые папки и git разом.
    ///
    /// Поллинг перечитывает дерево только когда меняется git-статус — файл, появившийся на
    /// сервере мимо git (лог, артефакт сборки, `.gitignore`-жилец), сам в дереве не всплывёт.
    /// Для этого и кнопка.
    func reloadTree() async {
        beginBusy()
        defer { endBusy() }
        await reloadExpandedDirs()
        rebuildRows()
        await refresh(force: true)
    }

    /// Поиск по содержимому файлов проекта. nil — ошибка (и она уже показана тостом).
    func searchContent(query: String, dir: String, exclude: String) async -> [RemoteSearch.Hit]? {
        let root = repoRoot ?? basePath
        do {
            return try await RemoteSearch.search(
                conn: conn, root: root, query: query,
                dir: dir.trimmingCharacters(in: .whitespaces),
                exclude: exclude,
                isRepo: repoRoot != nil
            )
        } catch {
            toast(.error, "Поиск не удался: \(error.localizedDescription)")
            return nil
        }
    }

    /// Открыть найденное: путь у результата — от корня поиска.
    func openSearchHit(_ hit: RemoteSearch.Hit) async {
        let root = repoRoot ?? basePath
        await openFile(root + "/" + hit.path, preview: true)
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
