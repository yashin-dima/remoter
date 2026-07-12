import AppKit

// Содержимое документов: открытие файла и diff'а, живое обновление с сервера, сохранение
// со сверкой конфликтов, контрольные суммы, быстрый переход ⌘P.

extension WorkspaceModel {

    // MARK: - Открытие

    /// Открывает файл. `preview` — одиночный клик: вкладка временная и будет заменена следующим
    /// таким же кликом. Постоянной она становится от двойного клика или от первой правки.
    func openFile(_ absPath: String, preview: Bool = false) async {
        let preview = preview && AppSettings.shared.previewTabs

        // Уже открыт — просто переключаемся, ничего не перечитывая.
        if tabs.contains(where: { $0.absPath == absPath }) {
            activate(path: absPath)
            // Двойной клик по файлу, уже открытому на предпросмотр, закрепляет его.
            if !preview { pinTab(path: absPath) }
            return
        }
        selectedPath = absPath
        openGeneration += 1
        let gen = openGeneration
        beginBusy()
        defer { endBusy() }

        let rel = relPath(absPath)
        let name = (absPath as NSString).lastPathComponent

        // Файл в списке изменений — открываем сразу как diff, это же основной сценарий.
        if let rel, let change = status.changes.first(where: { $0.path == rel }) {
            await openDiff(change, preview: preview)
            return
        }

        let file: RemoteFile
        do {
            file = try await RemoteFS.read(conn: conn, path: absPath)
        } catch {
            // Обрыв связи — не «файла нет»: честно говорим, что случилось, и не рисуем пустышку.
            guard gen == openGeneration else { return }
            errorMessage = error.localizedDescription
            return
        }
        // Пока файл ехал, кликнули по другому — этот показывать уже не надо.
        guard gen == openGeneration else { return }

        switch file {
        case .text(let content), .foreignEncoding(let content):
            let editable = file.isEditable && canWrite
            present(OpenDoc(mode: .view, title: name, absPath: absPath, relPath: rel,
                            kind: nil, baseline: content, editable: editable,
                            readOnlyReason: readOnlyReason(for: file), isPreview: preview))
            monaco.showFile(title: name, path: absPath, content: content, editable: editable)
            focusEditor()
            await refreshChecksum(of: absPath)
        case .binary(let bytes):
            monaco.showMessage("\(name) — бинарный файл (\(byteString(bytes)))")
        case .tooLarge(let bytes):
            monaco.showMessage("\(name) — слишком большой для просмотра (\(byteString(bytes)))")
        case .missing:
            monaco.showMessage("\(name) — не удалось прочитать")
        }
    }

    func openChange(_ change: GitChange, preview: Bool = false) async {
        guard let root = repoRoot else { return }
        let preview = preview && AppSettings.shared.previewTabs
        let absPath = root + "/" + change.path

        if tabs.contains(where: { $0.absPath == absPath }) {
            activate(path: absPath)
            if !preview { pinTab(path: absPath) }
            return
        }
        selectedPath = absPath
        await openDiff(change, preview: preview)
    }

    /// Фокус в редактор — сразу, без второго клика по нему.
    ///
    /// Иначе получается странное: файл открыт, вы его видите, а стрелки и ⌘F по-прежнему
    /// разговаривают с деревом. Ровно так это и работает в VS Code: открыл — печатай.
    func focusEditor() {
        pane = .file
        monaco.focusEditor()
    }

    private func openDiff(_ change: GitChange, preview: Bool = false) async {
        guard let root = repoRoot else { return }
        openGeneration += 1
        let gen = openGeneration
        beginBusy()
        defer { endBusy() }

        let absPath = root + "/" + change.path
        let name = change.name

        async let originalSide: String? = loadOriginal(change)
        async let currentFile: RemoteFile = loadWorktree(change, absPath: absPath)

        let maybeOriginal: String?
        let current: RemoteFile
        do {
            (maybeOriginal, current) = try await (originalSide, currentFile)
        } catch {
            // Обрыв связи — не «пустая левая сторона»: изменённый файл выглядел бы
            // целиком добавленным. Говорим как есть.
            guard gen == openGeneration else { return }
            errorMessage = error.localizedDescription
            return
        }
        // Пока стороны diff'а ехали, открыли другой файл — не перекрываем его этим.
        guard gen == openGeneration else { return }

        guard let original = maybeOriginal else {
            monaco.showMessage("\(name) — бинарный файл, diff не показать")
            return
        }

        switch current {
        case .text(let modified), .foreignEncoding(let modified):
            let editable = current.isEditable && canWrite && !change.isDeletedInWorktree
            present(OpenDoc(mode: .diff, title: name, absPath: absPath,
                            relPath: change.path, kind: change.kind,
                            original: original, baseline: modified, editable: editable,
                            readOnlyReason: readOnlyReason(for: current), isPreview: preview))
            monaco.showDiff(title: name, path: absPath, original: original,
                            modified: modified, editable: editable)
            focusEditor()
            await refreshChecksum(of: absPath)
        case .binary(let bytes):
            monaco.showMessage("\(name) — бинарный файл (\(byteString(bytes))), diff не показать")
        case .tooLarge(let bytes):
            monaco.showMessage("\(name) — слишком большой для diff (\(byteString(bytes)))")
        case .missing:
            monaco.showMessage("\(name) — не удалось прочитать")
        }
    }

    /// Левая сторона diff'а. nil — файл бинарный, показывать нечего.
    ///
    /// Для переименования версию надо брать по СТАРОМУ имени: по новому в HEAD ничего нет,
    /// и diff выглядел бы как «файл целиком добавлен», хотя изменилась пара строк.
    private func loadOriginal(_ change: GitChange) async throws -> String? {
        guard let root = repoRoot, change.kind != .untracked else { return "" }
        let historical = change.origPath ?? change.path

        // Отсутствие файла в ревизии — не ошибка: у нового файла левая сторона просто пустая.
        // Обрыв транспорта Git.show бросает — он до вызывающего дойдёт как ошибка, не как «пусто».
        guard let data = try await Git.show(
            conn: conn, root: root, rev: diffBase.rev, path: historical
        ) else { return "" }

        let file = RemoteFS.decode(data)
        if let text = file.displayText { return text }
        if case .binary = file { return nil }
        return ""
    }

    private func loadWorktree(_ change: GitChange, absPath: String) async throws -> RemoteFile {
        if change.isDeletedInWorktree { return .text("") }
        return try await RemoteFS.read(conn: conn, path: absPath)
    }

    func reopenCurrent() async {
        // С несохранёнными правками базу diff'а не переключаем: openDiff пересоздал бы вкладку
        // и буфер Monaco с серверным содержимым — набранное пропало бы молча и безвозвратно.
        guard let doc, !doc.isDirty, let rel = doc.relPath,
              let change = status.changes.first(where: { $0.path == rel })
        else { return }
        await openDiff(change)
    }

    // MARK: - Живое обновление

    /// Файл поменялся на сервере — обновляем содержимое, не трогая скролл и курсор.
    /// Ради этого и живёт поллинг: правку, которую Claude сделал на сервере, видно сразу.
    ///
    /// Работает по пути, а не по активной вкладке: между запросом и ответом сервер медленный,
    /// а пользователь быстрый — активная вкладка запросто успевает смениться.
    func reloadContent(path: String) async {
        guard let d = tabs.first(where: { $0.absPath == path }), !d.isDirty, !d.isLocal
        else { return }

        // Обрыв транспорта — молча выходим: это фоновое обновление, следующий тик поллинга повторит.
        guard let file = try? await RemoteFS.read(conn: conn, path: path),
              let content = file.displayText else { return }

        var original: String?
        if d.mode == .diff, let rel = d.relPath,
           let change = status.changes.first(where: { $0.path == rel }) {
            do { original = try await loadOriginal(change) ?? "" } catch { return }
        }

        // Пока содержимое ехало с сервера, пользователь мог начать печатать — тогда не трогаем:
        // Monaco на своей стороне тоже откажется (см. update в editor.js), но лучше не просить.
        guard tabs.first(where: { $0.absPath == path })?.isDirty == false else { return }

        updateTab(path) { doc in
            if let original { doc.original = original }
            doc.baseline = content
        }
        monaco.update(path: path, original: original, modified: content)
    }

    // MARK: - Контрольные суммы

    /// Контрольная сумма активного файла — вместе с путём: пока она ехала по ssh, активная
    /// вкладка могла смениться, и результат должен попасть в ту, для которой считался.
    func fetchOpenFileChecksum() async -> (path: String, sum: String)? {
        // Локальный файл на сервере не лежит — считать его контрольную сумму по ssh незачем.
        guard let doc, !doc.isDirty, !doc.isLocal else { return nil }
        let path = doc.absPath
        guard let sum = await fetchChecksum(of: path) else { return nil }
        return (path, sum)
    }

    /// cksum вместо перекачивания файла: гонять мегабайт каждые 2.5 секунды ради проверки
    /// «не поменялся ли» — расточительно, а crc32 приезжает одной строкой.
    private func fetchChecksum(of path: String) async -> String? {
        let r = try? await conn.sh("cksum < \(shq(path)) 2>/dev/null || echo missing")
        return r?.line
    }

    /// Запоминает у вкладки контрольную сумму только что прочитанной серверной версии.
    private func refreshChecksum(of path: String) async {
        guard let sum = await fetchChecksum(of: path) else { return }
        updateTab(path) { $0.checksum = sum }
    }

    // MARK: - Сохранение

    /// ⌘S из меню: сам текст лежит в Monaco, поэтому просим его прислать — сохранение
    /// продолжится в `save(path:content:)`, когда текст приедет обратно.
    func requestSave() { monaco.requestSave() }

    func save(path: String, content: String) async {
        guard let d = tabs.first(where: { $0.absPath == path }), d.editable else { return }

        // Снимок счётчика правок. Пока запись едет по ssh, пользователь продолжает печатать —
        // и сбросить isDirty после такого сохранения значило бы разрешить поллингу затереть
        // недопечатанное серверной версией. Все обновления ниже идут точечно через updateTab
        // по пути, а не через `doc = …`: сеттер doc заодно переключает активную вкладку,
        // и сохранение фоновой вкладки выдёргивало пользователя из той, где он работает.
        let edits = dirtyEvents[path] ?? 0
        func markSaved() {
            updateTab(path) {
                $0.baseline = content
                $0.conflict = false
                if (dirtyEvents[path] ?? 0) == edits { $0.isDirty = false }
            }
        }

        // Локальный файл — просто на диск. Ни ssh, ни предохранителей от обрыва связи, ни режима
        // «только чтение»: он про сервер, а это наши собственные заметки.
        if d.isLocal {
            do {
                try LocalFS.write(path, content: content)
                markSaved()
                reloadLocalTree()
            } catch {
                errorMessage = "Не удалось сохранить: \(error.localizedDescription)"
            }
            return
        }

        guard canWrite else {
            errorMessage = WriteError.readOnlyWorkspace.localizedDescription
            return
        }
        beginBusy()
        defer { endBusy() }

        // Пока мы правили файл здесь, его мог переписать кто-то на сервере — тот же Claude.
        // Молча затереть чужую работу хуже, чем спросить: сравниваем то, что лежит на сервере,
        // с тем, что мы оттуда прочитали, когда открывали.
        let onDisk: RemoteFile
        do {
            onDisk = try await RemoteFS.read(conn: conn, path: path)
        } catch {
            // Сверить не с чем — связь оборвалась. Писать вслепую нельзя: правки остаются
            // несохранёнными (isDirty не трогаем), пользователь повторит ⌘S, когда связь вернётся.
            errorMessage = "Не удалось сохранить: \(error.localizedDescription)"
            return
        }
        if let remote = onDisk.displayText, remote != d.baseline {
            let alert = NSAlert()
            alert.messageText = "Файл \(d.title) изменился на сервере"
            alert.informativeText = "Пока вы его правили, файл переписали на сервере."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Отменить")
            alert.addButton(withTitle: "Перезаписать")
            alert.addButton(withTitle: "Перечитать с сервера")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                updateTab(path) { $0.conflict = true }
                return
            case .alertSecondButtonReturn:
                break // пользователь осознанно выбрал свою версию
            default:
                // Перечитываем именно сохраняемую вкладку, а не активную: это не обязательно
                // одна и та же. Сброс isDirty нужен, иначе перечитывание само себя заблокирует.
                updateTab(path) { $0.isDirty = false }
                await reloadContent(path: path)
                return
            }
        }

        do {
            try await RemoteFS.write(conn: conn, path: path, content: content)
            markSaved()
            await refreshChecksum(of: path)
            await refresh(force: true)
        } catch {
            errorMessage = "Не удалось сохранить: \(error.localizedDescription)"
        }
    }

    /// Почему файл открыт только на чтение — это надо объяснить, а не просто не дать печатать.
    func readOnlyReason(for file: RemoteFile) -> String? {
        if !canWrite { return "Проект открыт только для чтения" }
        if case .foreignEncoding = file {
            return "Файл не в UTF-8 — сохранение перекодировало бы его целиком"
        }
        return nil
    }

    // MARK: - Быстрый переход (⌘P)

    func loadQuickOpenIndex() async {
        guard let root = repoRoot else { return }
        quickOpenFiles = (try? await Git.lsFiles(conn: conn, root: root)) ?? []
    }

    func openQuick(_ rel: String) async {
        guard let root = repoRoot else { return }
        await openFile(root + "/" + rel)
    }
}
