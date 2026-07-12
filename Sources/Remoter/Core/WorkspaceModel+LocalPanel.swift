import AppKit

// Локальная папка проекта на Mac: документация, заметки и инструкция для Claude живут здесь,
// а не на сервере — серверу про Claude знать незачем, да и складывать туда свои черновики
// плохая идея. Дерево, открытие и файловые операции локальной панели.

extension WorkspaceModel {

    func reloadLocalTree() {
        // У локального проекта раздела «Local» нет: его рабочая папка Claude — сам проект,
        // и второе дерево с тем же содержимым только тратило бы время на каждом обновлении.
        guard !workspace.isLocal else { return }
        guard !localPath.isEmpty else { return }
        localTree.children[localPath] = LocalFS.list(localPath)
        for dir in localTree.expanded where localTree.children[dir] != nil {
            localTree.children[dir] = LocalFS.list(dir)
        }
        rebuildLocalRows()
    }

    func toggleLocal(_ entry: RemoteEntry) {
        guard entry.isDir else { return }
        // Локальный диск читается синхронно — догрузка происходит прямо здесь, без Task.
        if let path = localTree.toggle(entry) {
            localTree.children[path] = LocalFS.list(path)
        }
        rebuildLocalRows()
    }

    private func rebuildLocalRows() {
        localRows = localTree.rows(from: localPath)
    }

    func openLocalFile(_ path: String, preview: Bool = false) {
        let preview = preview && AppSettings.shared.previewTabs

        if tabs.contains(where: { $0.absPath == path }) {
            activate(path: path)
            if !preview { pinTab(path: path) }
            return
        }

        let name = (path as NSString).lastPathComponent
        let file = LocalFS.read(path)

        switch file {
        case .text(let content), .foreignEncoding(let content):
            present(OpenDoc(mode: .view, title: name, absPath: path, relPath: nil,
                            kind: nil, baseline: content, editable: file.isEditable,
                            readOnlyReason: file.isEditable ? nil : "Файл не в UTF-8",
                            isLocal: true, isPreview: preview))
            monaco.showFile(title: name, path: path, content: content, editable: file.isEditable)
            focusEditor()
        case .binary(let bytes):
            monaco.showMessage("\(name) — бинарный файл (\(byteString(bytes)))")
        case .tooLarge(let bytes):
            monaco.showMessage("\(name) — слишком большой (\(byteString(bytes)))")
        case .missing:
            monaco.showMessage("\(name) — не удалось прочитать")
        }
        selectedPath = path
    }

    func newLocalFile(in target: String?) {
        let dir = localDir(target)
        guard let name = askName(
            title: "Новый файл",
            info: "Будет создан в \((dir as NSString).abbreviatingWithTildeInPath)",
            initial: "заметка.md"
        ) else { return }

        do {
            let path = try LocalFS.createFile(dir: dir, name: name)
            reloadLocalTree()
            openLocalFile(path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func newLocalFolder(in target: String?) {
        let dir = localDir(target)
        guard let name = askName(title: "Новая папка", initial: "новая папка") else { return }

        do {
            try LocalFS.createDirectory(dir: dir, name: name)
            reloadLocalTree()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Локальные файлы удаляем В КОРЗИНУ: это черновики пользователя, пусть остаётся шанс
    /// передумать. На сервере такой роскоши нет — там мы поэтому и спрашиваем подтверждение.
    func trashLocal(_ path: String) {
        do {
            try LocalFS.trash(path)
            dropTabs { $0.absPath == path || $0.absPath.hasPrefix(path + "/") }
            reloadLocalTree()
            toast(.success, "\((path as NSString).lastPathComponent) — в корзине")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameLocal(_ path: String, to newName: String) {
        do {
            try LocalFS.rename(path, to: newName)
            if tabs.contains(where: { $0.absPath == path }) { closeTab(path: path) }
            reloadLocalTree()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Открыть локальную папку проекта в Finder — туда кладут документацию.
    func revealLocalFolder() {
        guard !localPath.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: localPath)
    }

    private func localDir(_ target: String?) -> String {
        guard let target else { return localPath }
        if localRows.first(where: { $0.entry.path == target })?.entry.isDir == true { return target }
        return (target as NSString).deletingLastPathComponent
    }
}
