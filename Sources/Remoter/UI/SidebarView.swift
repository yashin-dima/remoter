import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            switcher
            Divider()

            switch model.tab {
            case .changes:
                if model.repoRoot == nil { noRepo } else { ChangesList(model: model) }
            case .files:
                FileTree(model: model)
            case .local:
                LocalPanel(model: model)
            }
        }
    }

    /// Переключатель «что показывать». Крупный и с иконками — предыдущий вариант был настолько
    /// незаметен, что diff в приложении просто не находили.
    ///
    /// Разделы и подписи спрашиваем у модели, а не берём у SidebarTab.allCases: у проекта на этом
    /// Mac раздела «Local» нет вовсе (его рабочая папка и есть сам проект), а «Remote» у папки
    /// на своей же машине читалось бы как ошибка.
    private var switcher: some View {
        SegmentedBar(
            items: model.sidebarTabs,
            selection: $model.tab,
            title: { model.sidebarTitle($0) },
            icon: { icon($0) },
            badge: { $0 == .changes ? model.status.changes.count : nil }
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    /// Серверная стойка на разделе с файлами локального проекта — та же ложь, что и слово
    /// «Remote» в его подписи.
    private func icon(_ tab: SidebarTab) -> String {
        tab == .files && model.workspace.isLocal ? "folder" : tab.icon
    }

    private var noRepo: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: D.s(30), weight: .light))
                .foregroundStyle(.tertiary)
            Text("Здесь нет git-репозитория")
                .font(D.Text.title)
            Text("Diff показывать не из чего. Дерево файлов и просмотр кода работают.")
                .font(D.Text.caption)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Изменения

/// Панель git — по логике расширения VS Code, и это не подражание ради подражания.
///
/// Прежняя панель врала в главном: файл, изменённый и в индексе, и в рабочей копии («MM»),
/// попадал ТОЛЬКО в раздел «В индексе». Его несохранённая правка нигде не показывалась —
/// и коммит уносил не то, что было видно на экране. Здесь такой файл честно стоит в обоих
/// разделах: слева от него две разные правки, и это два разных действия.
///
/// Остальное — про «непонятно, что где»: поле коммита сверху (а не в отдельном окне), кнопка,
/// на которой написано, сколько файлов уйдёт, разделы с итогами и кнопками на весь раздел,
/// и действия строки, которые видно, а не надо угадывать.
struct ChangesList: View {
    @ObservedObject var model: WorkspaceModel

    @State private var message = ""

    private var conflicts: [GitChange] { model.status.changes.filter(\.isConflicted) }
    private var staged: [GitChange] { model.status.changes.filter { $0.stagedKind != nil } }
    private var unstaged: [GitChange] { model.status.changes.filter { $0.worktreeKind != nil } }

    /// Что уйдёт в коммит. Пустой индекс — коммитим всё, как это делает VS Code: иначе кнопка
    /// «Закоммитить» в чистом индексе просто ничего не делала бы, и было бы непонятно, почему.
    private var willCommit: [GitChange] {
        staged.isEmpty ? model.status.changes.filter { !$0.isConflicted } : staged
    }

    var body: some View {
        VStack(spacing: 0) {
            branchBar
            Divider()

            if model.canWrite { commitBox; Divider() }

            if model.status.changes.isEmpty {
                empty
            } else {
                sections
            }
        }
    }

    // MARK: Ветка

    private var branchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: D.s(12), weight: .medium))
                .foregroundStyle(Theme.accent)

            Text(model.status.branch ?? "detached HEAD")
                .font(D.Text.bodyMedium)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.status.branch == nil
                      ? "Ветка не выбрана: HEAD стоит на коммите. Коммитить сюда можно, "
                        + "но коммит останется ничьим."
                      : "Текущая ветка")

            // Насколько разошлись с сервером. Молчание здесь означало бы «всё синхронно»,
            // а это не так — просто мы не спрашивали.
            if model.status.ahead > 0 {
                counter("arrow.up", model.status.ahead, "коммитов не отправлено")
            }
            if model.status.behind > 0 {
                counter("arrow.down", model.status.behind, "коммитов не забрано")
            }

            Spacer()

            if !model.canWrite {
                Label("только чтение", systemImage: "lock.fill")
                    .font(D.Text.caption)
                    .foregroundStyle(Theme.modified)
                    // Без слова «сервер»: проект может лежать и на этом же Mac, а запрет один и тот же.
                    .help("Проект открыт только для чтения — изменить в нём ничего нельзя")
            }

            IconButton(icon: "arrow.clockwise", size: 11, help: "Обновить (⌘R)") {
                Task { await model.refresh(force: true) }
            }
        }
        .padding(.leading, D.Pad.bar)
        .padding(.trailing, 4)
        .frame(height: D.s(34))
        .background(Theme.bg)
    }

    private func counter(_ icon: String, _ n: Int, _ help: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: D.s(8), weight: .bold))
            Text("\(n)").font(.system(size: D.s(10), weight: .semibold))
        }
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, D.s(5))
        .padding(.vertical, D.s(2))
        .background(Theme.hover, in: Capsule())
        .help("\(n) \(help)")
    }

    // MARK: Коммит

    /// Сообщение и кнопка — прямо в панели, а не в отдельном окне. Коммит — самое частое действие
    /// здесь, и открывать ради него модальное окно значит спрашивать разрешение на очевидное.
    private var commitBox: some View {
        VStack(spacing: 8) {
            TextEditor(text: $message)
                .font(D.Text.body)
                .scrollContentBackground(.hidden)
                .frame(height: D.s(54))
                .padding(4)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: D.Size.radius))
                .overlay(
                    RoundedRectangle(cornerRadius: D.Size.radius).stroke(Theme.border)
                )
                .overlay(alignment: .topLeading) {
                    if message.isEmpty {
                        Text("Сообщение коммита")
                            .font(D.Text.body)
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }

            Button {
                let text = message
                Task {
                    // Пустой индекс — коммитим всё: то же, что `git commit -a`, и ровно то,
                    // что написано на кнопке. Статус после операций обновляет сам gitOp.
                    if staged.isEmpty { await model.stageAll() }
                    await model.commit(message: text)
                    // Поле очищается только ПОСЛЕ успеха: при ошибке (обрыв связи, отказ
                    // hook'а) gitOp ставит errorMessage — и набранное сообщение не теряется.
                    // Раньше текст стирался до коммита и пропадал вместе с неудачей.
                    if model.errorMessage == nil, message == text { message = "" }
                }
            } label: {
                Label(commitTitle, systemImage: "checkmark")
                    .font(D.Text.bodyMedium)
                    .frame(maxWidth: .infinity)
                    .frame(height: D.s(24))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // isBusy закрывает двойной клик: поле больше не очищается мгновенно,
            // и без этого кнопка оставалась бы нажимаемой, пока коммит уже идёт.
            .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || willCommit.isEmpty || model.isBusy)
            .help(willCommit.isEmpty
                  ? "Коммитить нечего"
                  : (staged.isEmpty
                     ? "Индекс пуст — уйдут все изменения"
                     : "Уйдёт только то, что в индексе"))
        }
        .padding(D.s(10))
        .background(Theme.bg)
    }

    /// На кнопке написано, что она сделает, — включая число файлов. Иначе «Закоммитить» в панели,
    /// где половина правок в индексе, а половина нет, — это лотерея.
    private var commitTitle: String {
        guard !willCommit.isEmpty else { return "Коммитить нечего" }
        let n = willCommit.count
        return staged.isEmpty
            ? "Закоммитить всё (\(n))"
            : "Закоммитить индекс (\(n))"
    }

    // MARK: Разделы

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: D.s(30), weight: .light))
                .foregroundStyle(.tertiary)
            Text("Рабочая копия чистая")
                .font(D.Text.title)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sections: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if !conflicts.isEmpty {
                    Section {
                        ForEach(conflicts) { row($0, section: .conflict) }
                    } header: {
                        SectionHead(title: "Конфликты", count: conflicts.count, actions: [])
                    }
                }

                if !staged.isEmpty {
                    Section {
                        ForEach(staged) { row($0, section: .staged) }
                    } header: {
                        // Второго refresh после операций нет нигде в панели: gitOp внутри
                        // модели обновляет статус сам, и каждый лишний вызов — это ещё один
                        // полный `git status` по ssh на ровном месте.
                        SectionHead(title: "В индексе", count: staged.count, actions: model.canWrite ? [
                            .init(icon: "minus", help: "Убрать из индекса всё") {
                                Task { await model.unstageAll() }
                            },
                        ] : [])
                    }
                }

                if !unstaged.isEmpty {
                    Section {
                        ForEach(unstaged) { row($0, section: .worktree) }
                    } header: {
                        SectionHead(title: "Изменения", count: unstaged.count, actions: model.canWrite ? [
                            .init(icon: "arrow.uturn.backward", help: "Отбросить все изменения",
                                  destructive: true) {
                                Task { await model.discardAll(unstaged) }
                            },
                            .init(icon: "plus", help: "Добавить в индекс всё") {
                                Task { await model.stageAll() }
                            },
                        ] : [])
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func row(_ c: GitChange, section: ChangeRow.Section) -> some View {
        ChangeRow(
            change: c,
            section: section,
            isSelected: model.selectedPath == (model.repoRoot.map { $0 + "/" + c.path }),
            canWrite: model.canWrite,
            onOpen: { Task { await model.openChange(c, preview: true) } },
            onPin: { Task { await model.openChange(c) } },
            onStage: { Task { await model.stage(c) } },
            onUnstage: { Task { await model.unstage(c) } },
            onDiscard: { Task { await model.discard(c) } }
        )
    }
}

/// Заголовок раздела с итогом и кнопками на весь раздел.
private struct SectionHead: View {
    struct Action: Identifiable {
        let id = UUID()
        let icon: String
        let help: String
        var destructive = false
        let run: () -> Void
    }

    let title: String
    let count: Int
    let actions: [Action]

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: D.s(11), weight: .bold))
                .foregroundStyle(Theme.secondary)

            Text("\(count)")
                .font(.system(size: D.s(10), weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, D.s(6))
                .padding(.vertical, 1)
                .background(Theme.hover, in: Capsule())

            Spacer()

            // Кнопки видны под курсором, но место под них есть всегда — иначе заголовок
            // дёргался бы при каждом проходе мыши.
            HStack(spacing: 0) {
                if hovering {
                    ForEach(actions) { a in
                        IconButton(icon: a.icon, size: 11, help: a.help,
                                   role: a.destructive ? .destructive : nil, action: a.run)
                    }
                }
            }
            .frame(width: D.hit * CGFloat(actions.count), alignment: .trailing)
        }
        .padding(.leading, D.Pad.bar)
        .padding(.trailing, 4)
        .frame(height: D.s(26))
        .background(Theme.bg)
        .onHover { hovering = $0 }
    }
}

struct ChangeRow: View {
    /// В каком разделе стоит строка. От этого зависит и буква статуса, и что делают кнопки:
    /// один и тот же файл вполне может стоять и в индексе, и в изменениях — с разными правками.
    enum Section { case conflict, staged, worktree }

    let change: GitChange
    let section: Section
    let isSelected: Bool
    let canWrite: Bool
    let onOpen: () -> Void
    let onPin: () -> Void
    let onStage: () -> Void
    let onUnstage: () -> Void
    let onDiscard: () -> Void

    @State private var hovering = false

    /// Буква статуса — из СВОЕГО раздела. Файл, добавленный в индекс и потом ещё правленный,
    /// в индексе стоит как «A», а в изменениях — как «M». Показывать в обоих местах одну букву
    /// значило бы врать в одном из них.
    private var kind: ChangeKind {
        switch section {
        case .conflict: return .conflicted
        case .staged:   return change.stagedKind ?? .modified
        case .worktree: return change.worktreeKind ?? .modified
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(kind.letter)
                .font(D.Text.badge)
                .foregroundStyle(kind.color)
                .frame(width: D.s(14))
                .help(kind.title)

            VStack(alignment: .leading, spacing: 1) {
                Text(change.name)
                    .font(D.Text.body)
                    .strikethrough(kind == .deleted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !change.dir.isEmpty {
                    Text(change.dir)
                        .font(D.Text.caption)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 4)

            // Кнопки появляются под курсором, но место под них есть всегда: иначе имя файла
            // дёргалось бы вбок каждый раз, когда мышь проходит над строкой.
            HStack(spacing: 0) {
                if hovering && canWrite {
                    switch section {
                    case .staged:
                        IconButton(icon: "minus", size: 11,
                                   help: "Убрать из индекса", action: onUnstage)
                    case .worktree:
                        IconButton(icon: "arrow.uturn.backward", size: 11,
                                   help: "Отбросить изменения", role: .destructive, action: onDiscard)
                        IconButton(icon: "plus", size: 11,
                                   help: "Добавить в индекс", action: onStage)
                    case .conflict:
                        IconButton(icon: "checkmark", size: 11,
                                   help: "Конфликт решён — добавить в индекс", action: onStage)
                    }
                }
            }
            .frame(width: canWrite ? D.hit * 2 : 0, alignment: .trailing)
        }
        .padding(.horizontal, D.Pad.row)
        .frame(height: change.dir.isEmpty ? D.Size.row : D.s(40))
        .background(RowBackground(selected: isSelected, hovering: hovering))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onPin)
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Открыть diff", action: onOpen)
            if canWrite {
                Divider()
                switch section {
                case .staged:
                    Button("Убрать из индекса", action: onUnstage)
                case .worktree:
                    Button("Добавить в индекс", action: onStage)
                    Button("Отбросить изменения", role: .destructive, action: onDiscard)
                case .conflict:
                    Button("Конфликт решён — добавить в индекс", action: onStage)
                }
            }
        }
        .help(kind.title + " · " + change.path)
    }
}

// MARK: - Дерево файлов

struct FileTree: View {
    @ObservedObject var model: WorkspaceModel

    @State private var dropTarget: String?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows) { row in
                    TreeRowView(
                        row: row,
                        model: model,
                        kind: model.kind(for: row.entry),
                        hasChangesInside: model.hasChangesInside(row.entry),
                        isSelected: model.selection.contains(row.entry.path)
                            || (model.selection.isEmpty && model.selectedPath == row.entry.path),
                        isCut: model.clipboard?.isCut == true
                            && model.clipboard?.paths.contains(row.entry.path) == true,
                        isDropTarget: dropTarget == dropDir(for: row)
                    )
                    // Файл можно бросить и на папку, и на файл внутри неё — во втором случае
                    // он ляжет рядом. Целиться в узкую строку папки было бы мучением.
                    .onDrop(
                        of: [.fileURL],
                        delegate: UploadDrop(
                            dir: dropDir(for: row),
                            model: model,
                            highlighted: $dropTarget
                        )
                    )
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Пустое место под деревом — тоже цель: бросок туда кладёт файл в корень проекта.
        .contentShape(Rectangle())
        .onTapGesture { model.selection = [] }
        .onDrop(
            of: [.fileURL],
            delegate: UploadDrop(dir: model.basePath, model: model, highlighted: $dropTarget)
        )
        .overlay {
            if dropTarget != nil {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .padding(3)
                    .allowsHitTesting(false)
            }
        }
        // Горячие клавиши слушаем только когда фокус в дереве: иначе ⌘C перехватывало бы
        // копирование текста в редакторе.
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(action: handleKey)
        .contextMenu {
            Button("Новая папка…") { Task { await model.makeFolder(in: model.selectedPath) } }
                .disabled(!model.canWrite)
            if model.clipboard != nil {
                Button("Вставить") { Task { await model.paste(into: model.selectedPath) } }
                    .disabled(!model.canWrite)
            }
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let target = model.selectedPath

        if press.modifiers.contains(.command) {
            switch press.key {
            case "c": model.copy(target); return .handled
            case "x": model.cut(target); return .handled
            case "v": Task { await model.paste(into: target) }; return .handled
            case "a": model.selection = Set(model.rows.map(\.entry.path)); return .handled
            case .delete: Task { await model.delete(target) }; return .handled
            default: return .ignored
            }
        }

        switch press.key {
        case .delete:
            Task { await model.delete(target) }
            return .handled
        case .return:
            // То же ограничение, что и у пункта меню: read-only проект не переименовывает.
            if let target, model.canWrite { model.renaming = target }
            return .handled
        case .escape:
            model.selection = []
            return .handled
        default:
            return .ignored
        }
    }

    /// Куда положить файл, брошенный на эту строку: в саму папку или в папку, где лежит файл.
    private func dropDir(for row: TreeRow) -> String {
        row.entry.isDir
            ? row.entry.path
            : (row.entry.path as NSString).deletingLastPathComponent
    }
}

/// Приём файлов с Mac. Показывает подсветку цели и отдаёт модели список URL'ов.
struct UploadDrop: DropDelegate {
    let dir: String
    let model: WorkspaceModel
    @Binding var highlighted: String?

    func validateDrop(info: DropInfo) -> Bool {
        model.canWrite && info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) { highlighted = dir }
    func dropExited(info: DropInfo) { if highlighted == dir { highlighted = nil } }

    func performDrop(info: DropInfo) -> Bool {
        highlighted = nil
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }

        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await loadURL(from: provider) { urls.append(url) }
            }
            guard !urls.isEmpty else { return }
            await model.upload(urls: urls, to: dir)
        }
        return true
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                cont.resume(returning: url)
            }
        }
    }
}

/// Общее начало строки дерева: отступ по глубине, шеврон папки, иконка.
/// Один каркас на оба дерева — серверное (TreeRowView) и локальное (LocalRow),
/// чтобы их строки не расползались по отступам и размерам.
struct TreeRowLead: View {
    let depth: Int
    let isDir: Bool
    let isExpanded: Bool
    let icon: String
    let iconColor: Color

    var body: some View {
        HStack(spacing: 5) {
            // Отступ рисуем сами: так строки остаются плоским списком и дерево на 5000 файлов
            // не превращается в 5000 вложенных View.
            Color.clear.frame(width: CGFloat(depth) * 14, height: 1)

            Group {
                if isDir {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: D.s(9), weight: .bold))
                        .foregroundStyle(Theme.secondary)
                } else {
                    Color.clear
                }
            }
            .frame(width: 11)

            Image(systemName: icon)
                .font(.system(size: D.Size.icon))
                .foregroundStyle(iconColor)
                .frame(width: 16)
        }
    }
}

struct TreeRowView: View {
    let row: TreeRow
    @ObservedObject var model: WorkspaceModel
    let kind: ChangeKind?
    let hasChangesInside: Bool
    let isSelected: Bool
    let isCut: Bool
    let isDropTarget: Bool

    @State private var hovering = false
    @State private var newName = ""
    @FocusState private var renameFocused: Bool

    private var isRenaming: Bool { model.renaming == row.entry.path }

    var body: some View {
        HStack(spacing: 5) {
            TreeRowLead(
                depth: row.depth,
                isDir: row.entry.isDir,
                isExpanded: row.isExpanded,
                icon: icon,
                iconColor: row.entry.isDir ? Theme.accent : Theme.secondary
            )

            if isRenaming {
                TextField("", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .font(D.Text.body)
                    .focused($renameFocused)
                    .onAppear { newName = row.entry.name; renameFocused = true }
                    .onSubmit {
                        let name = newName
                        model.renaming = nil
                        Task { await model.rename(row.entry.path, to: name) }
                    }
                    .onExitCommand { model.renaming = nil }
            } else {
                Text(row.entry.name)
                    .font(D.Text.body)
                    .foregroundStyle(kind == .untracked ? Theme.added : Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if row.isLoading {
                ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 14, height: 14)
            }

            Spacer(minLength: 4)

            if let kind {
                Text(kind.letter)
                    .font(D.Text.badge)
                    .foregroundStyle(kind.color)
            } else if hasChangesInside {
                Circle()
                    .fill(Theme.modified.opacity(0.7))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, D.Pad.row)
        .frame(height: D.Size.row)
        .background(background)
        // Вырезанное показываем блёклым — как в Finder: видно, что оно «в пути».
        .opacity(isCut ? 0.45 : 1)
        .contentShape(Rectangle())
        // Двойной клик объявлен ПЕРЕД одиночным: иначе SwiftUI съедает его первым же
        // обработчиком, и до двойного дело не доходит.
        .onTapGesture(count: 2) { handleTap(preview: false) }
        .onTapGesture { handleTap(preview: true) }
        .onHover { hovering = $0 }
        .help(row.entry.path)
        .contextMenu { menu }
    }

    /// Одиночный клик открывает файл на предпросмотр — вкладкой, которую заменит следующий такой
    /// же клик. Двойной оставляет его в ряду насовсем. Так в VS Code, и не от лени: просматривая
    /// diff, за минуту прощёлкиваешь два десятка файлов, и все двадцать оставались бы висеть.
    private func handleTap(preview: Bool) {
        let flags = NSEvent.modifierFlags
        let toggling = flags.contains(.command)
        let extending = flags.contains(.shift)

        if toggling || extending {
            model.select(row.entry.path, extending: extending, toggling: toggling)
            return
        }

        model.selection = []
        model.selectedPath = row.entry.path

        if row.entry.isDir {
            // Папку двойным кликом не сворачиваем обратно: одиночный уже её раскрыл, и второй
            // щелчок выглядел бы как «ничего не произошло».
            if preview { model.toggle(row.entry) }
        } else {
            Task { await model.openFile(row.entry.path, preview: preview) }
        }
    }

    @ViewBuilder
    private var menu: some View {
        let count = model.selection.count
        let many = count > 1 && model.selection.contains(row.entry.path)
        let suffix = many ? " (\(count))" : ""

        Button("Открыть") { Task { await model.openFile(row.entry.path) } }
            .disabled(row.entry.isDir)

        Divider()

        Button("Копировать" + suffix) { model.copy(row.entry.path) }
        Button("Вырезать" + suffix) { model.cut(row.entry.path) }
            .disabled(!model.canWrite)
        Button("Вставить") { Task { await model.paste(into: row.entry.path) } }
            .disabled(model.clipboard == nil || !model.canWrite)

        Divider()

        Button("Переименовать…") { model.renaming = row.entry.path }
            .disabled(!model.canWrite || many)
        Button("Новая папка…") { Task { await model.makeFolder(in: row.entry.path) } }
            .disabled(!model.canWrite)
        Button("Копировать путь") { model.copyPathToPasteboard(row.entry.path) }

        Divider()

        Button("Удалить" + suffix, role: .destructive) {
            Task { await model.delete(row.entry.path) }
        }
        .disabled(!model.canWrite)
    }

    private var background: some View {
        RowBackground(selected: isSelected, hovering: hovering, target: isDropTarget)
    }

    private var icon: String {
        row.entry.isDir ? (row.isExpanded ? "folder" : "folder.fill") : "doc.text"
    }
}
