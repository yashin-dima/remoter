import AppKit

// Файловые операции в серверном дереве: выделение, буфер обмена, удаление, переименование,
// новые папки и загрузка перетаскиванием. Всё разрушающее спрашивает подтверждение
// и уважает режим «только чтение».

extension WorkspaceModel {

    struct Clipboard: Equatable {
        var paths: [String]
        /// Вырезание, а не копирование — файлы переедут, а не размножатся.
        var isCut: Bool
    }

    /// Файл, который прямо сейчас едет на сервер.
    struct Upload: Identifiable, Equatable {
        var id = UUID()
        var name: String
        var sent: Int
        var total: Int

        var fraction: Double { total > 0 ? Double(sent) / Double(total) : 0 }
    }

    /// Выделение с ⌘ (по одному) и ⇧ (диапазоном) — как в Finder.
    func select(_ path: String, extending: Bool, toggling: Bool) {
        if toggling {
            if selection.contains(path) { selection.remove(path) } else { selection.insert(path) }
        } else if extending, let anchor = selectedPath,
                  let from = rows.firstIndex(where: { $0.entry.path == anchor }),
                  let to = rows.firstIndex(where: { $0.entry.path == path }) {
            let range = from <= to ? from...to : to...from
            selection = Set(rows[range].map(\.entry.path))
        } else {
            selection = [path]
        }
        selectedPath = path
    }

    /// На чём выполнять операцию: на выделении, а если его нет — на строке под курсором.
    private func targets(_ fallback: String?) -> [String] {
        if !selection.isEmpty { return Array(selection) }
        return fallback.map { [$0] } ?? []
    }

    func copy(_ path: String? = nil) {
        let paths = targets(path)
        guard !paths.isEmpty else { return }
        clipboard = Clipboard(paths: paths, isCut: false)
        toast(.success, paths.count == 1
              ? "Скопирован: \((paths[0] as NSString).lastPathComponent)"
              : "Скопировано объектов: \(paths.count)")
    }

    func cut(_ path: String? = nil) {
        guard canWrite else { return readOnlyComplaint() }
        let paths = targets(path)
        guard !paths.isEmpty else { return }
        clipboard = Clipboard(paths: paths, isCut: true)
        toast(.success, paths.count == 1
              ? "Вырезан: \((paths[0] as NSString).lastPathComponent)"
              : "Вырезано объектов: \(paths.count)")
    }

    /// Вставка в папку. Если целью оказался файл — кладём рядом с ним, в его папку.
    func paste(into target: String?) async {
        guard canWrite else { return readOnlyComplaint() }
        guard let board = clipboard, !board.paths.isEmpty else { return }

        let dir = destinationDir(target)
        beginBusy()
        defer { endBusy() }

        do {
            if board.isCut {
                try await RemoteFS.move(conn: conn, paths: board.paths, into: dir, root: basePath)
                clipboard = nil // вырезанное вставляется один раз, дальше буфер пуст
            } else {
                try await RemoteFS.copy(conn: conn, paths: board.paths, into: dir, root: basePath)
            }
            toast(.success, "Вставлено объектов: \(board.paths.count)")
            selection = []
            await refresh(force: true)
            await reloadDir(dir)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ path: String? = nil) async {
        guard canWrite else { return readOnlyComplaint() }
        let paths = targets(path)
        guard !paths.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = paths.count == 1
            ? "Удалить «\((paths[0] as NSString).lastPathComponent)»?"
            : "Удалить объектов: \(paths.count)?"
        alert.informativeText = "Удаление происходит на сервере, минуя корзину. Отменить будет нельзя."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Отменить")
        alert.addButton(withTitle: "Удалить")
        guard alert.runModal() != .alertFirstButtonReturn else { return }

        beginBusy()
        defer { endBusy() }

        do {
            try await RemoteFS.remove(conn: conn, paths: paths, root: basePath)

            // Закрываем вкладки удалённых файлов — иначе останутся висеть призраки.
            // И файлов ВНУТРИ удалённых папок: снесли каталог — его содержимое тоже мертво.
            dropTabs { tab in
                paths.contains { tab.absPath == $0 || tab.absPath.hasPrefix($0 + "/") }
            }

            selection = []
            toast(.success, "Удалено объектов: \(paths.count)")
            await refresh(force: true)
            for dir in Set(paths.map { ($0 as NSString).deletingLastPathComponent }) {
                await reloadDir(dir)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rename(_ path: String, to newName: String) async {
        guard canWrite else { return readOnlyComplaint() }
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != (path as NSString).lastPathComponent else { return }

        beginBusy()
        defer { endBusy() }

        do {
            try await RemoteFS.rename(conn: conn, path: path, to: trimmed, root: basePath)
            if tabs.contains(where: { $0.absPath == path }) { closeTab(path: path) }
            await refresh(force: true)
            await reloadDir((path as NSString).deletingLastPathComponent)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func makeFolder(in target: String?) async {
        guard canWrite else { return readOnlyComplaint() }
        let dir = destinationDir(target)

        guard let name = askName(title: "Новая папка", info: "Будет создана в \(dir)",
                                 initial: "новая папка") else { return }

        do {
            try await RemoteFS.makeDirectory(conn: conn, dir: dir, name: name)
            await reloadDir(dir)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Копирует путь на сервере в буфер обмена Mac — удобно вставить в ssh или в вопрос агенту.
    func copyPathToPasteboard(_ path: String? = nil) {
        let paths = targets(path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        toast(.success, "Путь скопирован в буфер обмена")
    }

    private func destinationDir(_ target: String?) -> String {
        guard let target else { return basePath }
        if rows.first(where: { $0.entry.path == target })?.entry.isDir == true { return target }
        return (target as NSString).deletingLastPathComponent
    }

    func readOnlyComplaint() {
        errorMessage = WriteError.readOnlyWorkspace.localizedDescription
    }

    // MARK: - Диалог имени

    /// Поле ввода имени в диалогах «Новый файл» / «Новая папка».
    private static let nameFieldFrame = NSRect(x: 0, y: 0, width: 260, height: 22)

    /// Диалог ввода имени — один на «Новый файл», «Новая папка» и серверную папку:
    /// три дословные копии окна отличались только заголовком и подставленным именем.
    func askName(title: String, info: String? = nil, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        if let info { alert.informativeText = info }
        let field = NSTextField(frame: Self.nameFieldFrame)
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: "Создать")
        alert.addButton(withTitle: "Отменить")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    // MARK: - Загрузка перетаскиванием

    /// Кладёт файлы с Mac в каталог на сервере.
    ///
    /// Одноимённый файл не затирается: рядом появится «логотип 2.png». Перетаскивание — жест
    /// беглый, и молча потерять чужой файл из-за совпадения имени было бы отвратительно.
    func upload(urls: [URL], to dir: String) async {
        guard canWrite else {
            errorMessage = WriteError.readOnlyWorkspace.localizedDescription
            return
        }

        var uploadedAny = false
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            guard !isDir.boolValue else {
                toast(.error, "Папки пока не загружаются: \(url.lastPathComponent)")
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                toast(.error, "Не удалось прочитать \(url.lastPathComponent)")
                continue
            }

            let name = await RemoteFS.freeName(conn: conn, dir: dir, name: url.lastPathComponent)
            let target = dir + "/" + name

            let job = Upload(name: name, sent: 0, total: data.count)
            uploads.append(job)

            do {
                try await RemoteFS.writeData(conn: conn, path: target, data: data) { sent, total in
                    Task { @MainActor [weak self] in
                        guard let i = self?.uploads.firstIndex(where: { $0.id == job.id }) else { return }
                        self?.uploads[i].sent = sent
                        self?.uploads[i].total = total
                    }
                }
                uploads.removeAll { $0.id == job.id }
                toast(.success, "\(name) — загружен (\(byteString(data.count)))")
                uploadedAny = true
            } catch {
                uploads.removeAll { $0.id == job.id }
                toast(.error, "\(name): \(error.localizedDescription)")
            }
        }

        // Один refresh на всю пачку: перетащили двадцать скриншотов — не нужно сорок
        // раундтрипов `git status` + `ls` между файлами.
        if uploadedAny {
            await refresh(force: true)
            await reloadDir(dir)
        }
    }
}
