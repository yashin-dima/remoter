import AppKit

// Ряд вкладок редактора: открытие рядом, предпросмотр, активация, закрытие с выбором соседа.
// Само содержимое документов (чтение, diff, сохранение) — в WorkspaceModel+Documents.swift.

extension WorkspaceModel {

    /// Активная вкладка. Почти весь код работает с ней, а не со списком.
    var doc: OpenDoc? {
        get { tabs.first { $0.absPath == activePath } }
        set {
            guard let newValue else {
                if let p = activePath { closeTab(path: p) }
                return
            }
            if let i = tabs.firstIndex(where: { $0.absPath == newValue.absPath }) {
                tabs[i] = newValue
            } else {
                tabs.append(newValue)
            }
            activePath = newValue.absPath
        }
    }

    func updateTab(_ path: String, _ mutate: (inout OpenDoc) -> Void) {
        guard let i = tabs.firstIndex(where: { $0.absPath == path }) else { return }
        mutate(&tabs[i])
    }

    func activate(path: String) {
        guard let tab = tabs.first(where: { $0.absPath == path }) else { return }
        activePath = path
        selectedPath = path
        show(tab)
    }

    /// Вкладка перестаёт быть предпросмотром: с файлом начали работать, и он остаётся в ряду.
    /// В VS Code это двойной клик по файлу или по самой вкладке — и первая же правка.
    func pinTab(path: String) {
        updateTab(path) { $0.isPreview = false }
    }

    /// Освобождает место под новый предпросмотр: старый закрывается, а новый встаёт на его место.
    ///
    /// Место важно: прощёлкивая diff'ы, вы смотрите в одну и ту же точку ряда. Прыгай вкладка
    /// каждый раз в конец — глазами пришлось бы искать её заново.
    private func replacePreviewSlot() -> Int? {
        guard let i = tabs.firstIndex(where: { $0.isPreview }) else { return nil }

        // Предпросмотр с несохранёнными правками невозможен: первая же правка делает вкладку
        // постоянной. Значит, закрыть его можно молча — терять нечего.
        let path = tabs[i].absPath
        tabs.remove(at: i)
        monaco.closePane(path: path)
        return i
    }

    /// Кладёт документ в ряд вкладок и показывает его.
    func present(_ doc: OpenDoc) {
        if let i = tabs.firstIndex(where: { $0.absPath == doc.absPath }) {
            tabs[i] = doc
        } else if doc.isPreview, let slot = replacePreviewSlot() {
            tabs.insert(doc, at: slot)
        } else {
            tabs.append(doc)
        }
        activePath = doc.absPath
    }

    /// Закрытие вкладки с несохранёнными правками спрашивает подтверждение — терять
    /// набранное молча нельзя.
    func closeTab(path: String) {
        if let tab = tabs.first(where: { $0.absPath == path }), tab.isDirty {
            let alert = NSAlert()
            alert.messageText = "В файле \(tab.title) есть несохранённые изменения"
            alert.informativeText = "Если закрыть вкладку, они пропадут."
            alert.addButton(withTitle: "Отменить")
            alert.addButton(withTitle: "Закрыть без сохранения")
            guard alert.runModal() != .alertFirstButtonReturn else { return }
        }

        guard let i = tabs.firstIndex(where: { $0.absPath == path }) else { return }
        tabs.remove(at: i)
        monaco.closePane(path: path)
        dirtyEvents[path] = nil

        guard activePath == path else { return }
        // Активной становится соседняя — как в браузере, а не «ничего не выбрано».
        if let next = neighbor(in: tabs, afterRemovalAt: i) {
            activate(path: next.absPath)
        } else {
            activePath = nil
            selectedPath = nil
            monaco.showMessage(placeholderMessage)
        }
    }

    /// «Соседняя» вкладка после закрытия i-й: правая, а если её нет — левая.
    /// Общая для всех рядов: файлы, сессии Claude, терминалы.
    func neighbor<T>(in items: [T], afterRemovalAt i: Int) -> T? {
        items[safe: i] ?? items[safe: i - 1]
    }

    /// Подсказка в пустом редакторе — одна на все места, где вкладок не осталось.
    var placeholderMessage: String {
        repoRoot == nil ? "Выберите файл слева" : "Выберите изменённый файл — увидите diff"
    }

    /// Закрывает вкладки без вопросов — их файлы удалены или переименованы, спасать нечего, —
    /// и чинит активную: соседняя, а если вкладок не осталось — подсказка вместо призрака.
    func dropTabs(where doomed: (OpenDoc) -> Bool) {
        let paths = tabs.filter(doomed).map(\.absPath)
        guard !paths.isEmpty else { return }

        tabs.removeAll(where: doomed)
        for p in paths {
            monaco.closePane(path: p)
            dirtyEvents[p] = nil
        }

        guard let active = activePath, paths.contains(active) else { return }
        if let next = tabs.last {
            activate(path: next.absPath)
        } else {
            activePath = nil
            selectedPath = nil
            monaco.showMessage(placeholderMessage)
        }
    }

    func closeOtherTabs(keeping path: String) {
        for tab in tabs where tab.absPath != path { closeTab(path: tab.absPath) }
    }

    /// Отдаёт вкладку в редактор.
    /// Показать файл — значит и переключиться на него. Открытый в невидимой вкладке diff —
    /// это молчаливое «ничего не произошло» в ответ на клик.
    private func show(_ tab: OpenDoc) {
        pane = .file

        switch tab.mode {
        case .diff:
            monaco.showDiff(title: tab.title, path: tab.absPath,
                            original: tab.original, modified: tab.baseline,
                            editable: tab.editable)
        case .view:
            monaco.showFile(title: tab.title, path: tab.absPath,
                            content: tab.baseline, editable: tab.editable)
        case .image:
            // Картинку рисует ImageViewer поверх редактора (см. EditorPane) — Monaco
            // в этой вкладке не участвует.
            break
        }
    }
}
