import SwiftUI
import AppKit

/// Список проектов. Отсюда открываются окна воркспейсов — по окну на проект, у каждого своя
/// сессия Claude.
struct LauncherView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var editing: Workspace?
    @State private var isAdding = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var sections: [WorkspaceStore.Section] { store.sections(matching: query) }

    /// Открыв проект, список себя закрывает: он сделал своё дело и больше не нужен.
    /// Позвать обратно — ⇧⌘O (пункт «Проекты…» в меню).
    private func open(_ ws: Workspace) {
        openWindow(id: "workspace", value: ws.id)
        dismissWindow(id: "launcher")
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.workspaces.isEmpty {
                empty
            } else {
                search
                Divider()
                if sections.isEmpty { nothingFound } else { list }
            }
            Divider()
            footer
        }
        .frame(minWidth: D.s(620), minHeight: D.s(460))
        .onAppear {
            openFromCommandLine()
            searchFocused = true   // окно открылось — можно сразу печатать
        }
        .sheet(item: $editing) { ws in
            WorkspaceEditor(workspace: ws) { store.update($0) }
        }
        .sheet(isPresented: $isAdding) {
            // isNew: только у нового проекта можно выбрать тип. У существующего он уже
            // намертво связан с путём и историей сессий Claude — см. WorkspaceEditor.
            WorkspaceEditor(workspace: Workspace(name: "", host: "", path: ""), isNew: true) {
                store.add($0)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: D.s(48), weight: .light))
                .foregroundStyle(.tertiary)
            Text("Пока нет ни одного проекта")
                .font(.system(size: D.s(17), weight: .semibold))
            Text("Проект может лежать на сервере или прямо на этом Mac — в обоих случаях Remoter покажет дерево файлов, git-diff и запустит рядом Claude.")
                .font(.system(size: D.s(13)))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Добавить проект") { isAdding = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Поиск идёт сразу по всем проектам: по названию, компании, серверу и пути. Помнишь адрес
    /// сервера, а не то, как ты этот проект однажды назвал, — и это нормально.
    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: D.s(13), weight: .medium))
                .foregroundStyle(Theme.secondary)

            TextField("Поиск по проектам, компаниям, серверам", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: D.s(14)))
                .focused($searchFocused)
                .onExitCommand { query = "" }

            if !query.isEmpty {
                IconButton(icon: "xmark.circle.fill", size: 12, help: "Очистить") { query = "" }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var nothingFound: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: D.s(30), weight: .light))
                .foregroundStyle(.tertiary)
            Text("Ничего не нашлось")
                .font(D.Text.title)
                .foregroundStyle(Theme.secondary)
            Text("По запросу «\(query)» нет ни одного проекта.")
                .font(D.Text.caption)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { ws in
                            ProjectCard(
                                workspace: ws,
                                onOpen: { open(ws) },
                                onEdit: { editing = ws },
                                onDelete: { store.remove(ws) }
                            )
                            .padding(.horizontal, 14)
                        }
                    } header: {
                        SectionHeader(title: section.company, count: section.items.count)
                    }
                }
            }
            .padding(.bottom, 14)
        }
    }

    /// `open -a Remoter --args --open <название>` — открыть проект сразу, минуя список.
    /// Удобно повесить на алиас в шелле рядом с тем, которым заходишь на сервер.
    ///
    /// Обрабатывается РОВНО ОДИН РАЗ за жизнь процесса: аргументы не меняются, а `onAppear`
    /// случается при каждом открытии списка (⇧⌘O, «+»). Без флага каждый вызов списка
    /// немедленно открывал бы тот же проект и закрывал список — навсегда, до перезапуска.
    private static var commandLineHandled = false

    private func openFromCommandLine() {
        guard !Self.commandLineHandled else { return }
        Self.commandLineHandled = true

        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--open"), i + 1 < args.count else { return }
        let key = args[i + 1].lowercased()

        guard let ws = store.workspaces.first(where: {
            $0.name.lowercased() == key || $0.id.uuidString.lowercased() == key
        }) else { return }

        open(ws)
    }

    private var footer: some View {
        HStack {
            Button {
                isAdding = true
            } label: {
                Label("Добавить проект", systemImage: "plus")
                    .font(D.Text.bodyMedium)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            Spacer()
        }
        .padding(14)
    }
}

/// Заголовок раздела — компания. Липнет к верху при прокрутке: пролистав десяток проектов,
/// не должно быть загадкой, чьи они.
///
/// Без иконок и без плашек: это подпись к группе, а не элемент управления. Отступы совпадают
/// с отступами карточек под ним — иначе заголовок «висит» отдельно от своего же списка.
private struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: D.s(12), weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .textCase(.uppercase)
                .kerning(0.5)

            Text("\(count)")
                .font(.system(size: D.s(11), weight: .medium))
                .foregroundStyle(Theme.secondary.opacity(0.7))

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg)
    }
}

/// Проект в списке. Карточка, а не строка таблицы: проектов немного, и каждый — это сервер,
/// путь и режим доступа, которые хочется видеть, а не угадывать.
private struct ProjectCard: View {
    let workspace: Workspace
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    /// Проект на этом Mac видно по иконке, не вчитываясь в путь: в списке они стоят вперемешку
    /// с серверными, а работают с ними по-разному.
    private var icon: String {
        workspace.isLocal ? "laptopcomputer" : "shippingbox.fill"
    }

    /// Безымянный проект называем тем, что о нём известно: сервером или именем папки.
    /// У локального хост пуст — строка заголовка иначе оказалась бы пустой.
    private var title: String {
        if !workspace.name.isEmpty { return workspace.name }
        return workspace.isLocal ? (workspace.path as NSString).lastPathComponent : workspace.host
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: D.s(20)))
                .foregroundStyle(.tint)
                .frame(width: 30)
                .help(workspace.isLocal ? "Папка на этом Mac" : "Проект на сервере")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: D.s(14), weight: .semibold))
                        .lineLimit(1)

                    if workspace.readOnly {
                        Label("только чтение", systemImage: "lock.fill")
                            .font(.system(size: D.s(10), weight: .medium))
                            .foregroundStyle(Theme.modified)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.modified.opacity(0.14), in: Capsule())
                    }
                }

                Text(workspace.subtitle)
                    .font(D.Text.mono)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 8)

            IconButton(icon: "slider.horizontal.3", size: 13, help: "Изменить…", action: onEdit)

            RowActionButton(title: "Открыть", prominent: hovering, height: 30, action: onOpen)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            hovering ? Theme.hover : Theme.bg,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(hovering ? Theme.accent.opacity(0.4) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onOpen)
        .contextMenu {
            Button("Открыть", action: onOpen)
            Button("Изменить…", action: onEdit)
            Divider()
            Button("Удалить", role: .destructive, action: onDelete)
        }
    }
}

/// Форма проекта. Проект бывает двух видов, и это первое, что здесь выбирают:
///
/// - **на сервере** — хост это всё, что понимает системный ssh: алиас из ~/.ssh/config или
///   user@host, плюс путь, порт и опции;
/// - **на этом Mac** — обычная папка на диске. Ни хоста, ни порта, ни ssh-опций у неё нет,
///   и спрашивать их было бы издевательством.
///
/// У СУЩЕСТВУЮЩЕГО проекта вид не меняется. Не из вредности: к пути проекта привязана история
/// разговоров Claude (он хранит журналы в каталоге, имя которого собрано из пути рабочей папки),
/// и превращение серверного проекта в локальный оторвало бы её всю разом.
struct WorkspaceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: WorkspaceStore
    @State var workspace: Workspace
    /// Проект только заводят — значит, вид ещё можно выбрать.
    let isNew: Bool
    let onSave: (Workspace) -> Void

    init(workspace: Workspace, isNew: Bool = false, onSave: @escaping (Workspace) -> Void) {
        _workspace = State(initialValue: workspace)
        self.isNew = isNew
        self.onSave = onSave
    }

    private var knownCompanies: [String] { store.companies }

    /// Компания вписывается руками. Так же и у проекта, у которого компания уже есть, но её нет
    /// в списке (её могли переименовать в другом проекте) — иначе выбор молча стёр бы её.
    @State private var isNewCompany = false

    @State private var checking = false
    @State private var checkResult: String?
    @State private var checkOK = false
    @State private var browsing = false

    /// Путь, как его набрали, — но с раскрытой тильдой: `~/Projects/app` набирают по привычке,
    /// а на диске такой папки нет, есть `/Users/…/Projects/app`. Раскрываем только у локального:
    /// на сервере `~` означает домашний каталог ТАМ, и подставлять в него свой было бы враньём
    /// (серверный путь и так обязан быть абсолютным — см. isValid).
    private var trimmedPath: String {
        let raw = workspace.path.trimmingCharacters(in: .whitespaces)
        return workspace.isLocal ? (raw as NSString).expandingTildeInPath : raw
    }

    /// Папка на диске есть и это именно папка. Проверяется на каждой перерисовке — стоит это
    /// одного stat'а, а цена молчания высока: проект с несуществующим путём не откроется вовсе,
    /// и выяснится это уже в пустом окне.
    private var localFolderExists: Bool {
        var isDir: ObjCBool = false
        let found = FileManager.default.fileExists(atPath: trimmedPath, isDirectory: &isDir)
        return found && isDir.boolValue
    }

    private var isValid: Bool {
        guard trimmedPath.hasPrefix("/") else { return false }
        // У локального проекта хоста нет и быть не может — вместо него смотрим, существует ли
        // папка. У серверного наоборот: проверить путь отсюда нельзя, а вот хост обязателен.
        return workspace.isLocal
            ? localFolderExists
            : !workspace.host.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Переключение вида проекта. Заодно чистит то, что от прежнего вида осталось: путь `/srv/app`
    /// на Mac не существует, а `/Users/…` на сервере укажет в никуда — сохранить такую пару
    /// значило бы завести заведомо мёртвый проект.
    private var kind: Binding<Bool> {
        Binding(
            get: { workspace.isLocal },
            set: { local in
                // Пикер у существующего проекта и так выключен; проверка — на случай, если
                // сюда однажды придут не оттуда: сменить вид — значит стереть путь, а с ним
                // и всю привязку к истории сессий Claude.
                guard isNew, local != workspace.isLocal else { return }
                workspace.isLocal = local
                workspace.path = ""
                checkResult = nil
                if local {
                    // Сервера у локального проекта нет — ни хоста, ни порта, ни опций ssh.
                    // Оставь мы их «на всякий случай», они уехали бы в сохранённый проект.
                    workspace.host = ""
                    workspace.port = nil
                    workspace.sshOptions = nil
                }
            }
        )
    }

    /// Пустое поле = порт по умолчанию, то есть тот, что решит сам ssh (22 или из ssh config).
    ///
    /// Невалидный ввод сохранённый порт НЕ трогает: раньше одна опечатка («22a») превращала
    /// порт в nil, `get` возвращал пустую строку — и поле стирало само себя под руками.
    private var portText: Binding<String> {
        Binding(
            get: { workspace.port.map(String.init) ?? "" },
            set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    workspace.port = nil
                } else if let port = Int(trimmed) {
                    workspace.port = port
                }
            }
        )
    }

    private static let newCompanyTag = "\u{0}новая"

    /// Что выбрано в списке: существующая компания, «без компании» или «новая» (тогда рядом
    /// появляется поле для названия).
    private var companyChoice: Binding<String> {
        Binding(
            get: {
                if isNewCompany { return Self.newCompanyTag }
                let c = workspace.company ?? ""
                return knownCompanies.contains(c) ? c : ""
            },
            set: { choice in
                if choice == Self.newCompanyTag {
                    isNewCompany = true
                    workspace.company = nil
                } else {
                    isNewCompany = false
                    workspace.company = choice.isEmpty ? nil : choice
                }
            }
        )
    }

    private var companyText: Binding<String> {
        Binding(
            get: { workspace.company ?? "" },
            set: { workspace.company = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        )
    }

    private var optionsText: Binding<String> {
        Binding(
            get: { workspace.sshOptions ?? "" },
            set: { workspace.sshOptions = $0.isEmpty ? nil : $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Проект")
                .font(.headline)
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 14)

            Form {
                TextField("Название", text: $workspace.name, prompt: Text("Мой проект"))
                company
                kindPicker
                // Поля у двух видов проекта разные вплоть до последнего: у папки на Mac нет ни
                // хоста, ни порта, ни опций ssh — показывать их «серыми» значило бы намекать,
                // что они когда-нибудь пригодятся.
                if workspace.isLocal { localFields } else { serverFields }
                access
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)

            Text(hint)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)

            if let checkResult {
                Label(checkResult, systemImage: checkOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(checkOK ? Theme.added : Theme.modified)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }

            Spacer(minLength: 12)

            HStack {
                Button(workspace.isLocal ? "Проверить папку" : "Проверить подключение") {
                    Task { await check() }
                }
                .disabled(!isValid || checking)
                if checking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding(20)
        }
        // Высота с запасом на выбор вида проекта: без него серверная форма ровно упиралась
        // в нижний край и начинала скроллиться на ровном месте.
        .frame(width: D.s(560), height: D.s(560))
        .onAppear {
            let c = workspace.company ?? ""
            isNewCompany = !c.isEmpty && !knownCompanies.contains(c)
        }
        .sheet(isPresented: $browsing) {
            RemotePathPicker(
                host: workspace.host.trimmingCharacters(in: .whitespaces),
                port: workspace.port,
                extraArgs: workspace.extraSSHArgs
            ) { picked in
                workspace.path = picked
                nameFromFolder(picked)
            }
        }
    }

    // MARK: - Поля формы

    /// Компания выбирается из уже заведённых — обычным выпадающим списком, как и положено выбору
    /// из списка. Печатать её руками нужно ровно один раз, когда компания новая; иначе через месяц
    /// в списке живут «Acme» и «acme».
    @ViewBuilder
    private var company: some View {
        Picker("Компания", selection: companyChoice) {
            Text("Без компании").tag("")
            ForEach(knownCompanies, id: \.self) { Text($0).tag($0) }
            Divider()
            Text("Новая компания…").tag(Self.newCompanyTag)
        }

        if isNewCompany {
            TextField("Название компании", text: companyText,
                      prompt: Text("например, Acme"))
        }
    }

    @ViewBuilder
    private var kindPicker: some View {
        Picker("Где проект", selection: kind) {
            Text("На сервере").tag(false)
            Text("На этом Mac").tag(true)
        }
        .pickerStyle(.segmented)
        .disabled(!isNew)

        if !isNew {
            Text("Вид проекта менять нельзя: к его пути привязана история разговоров Claude — сменив вид, вы оторвали бы её. Заведите проект заново, если он переехал.")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
        }
    }

    @ViewBuilder
    private var serverFields: some View {
        TextField("Сервер", text: $workspace.host, prompt: Text("my-server или user@1.2.3.4"))
        HStack {
            TextField("Путь к проекту", text: $workspace.path, prompt: Text("/srv/app"))
            Button("Обзор…") { browsing = true }
                .disabled(workspace.host.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Выбрать папку прямо на сервере")
        }
        TextField("Порт", text: portText, prompt: Text("22 (по умолчанию)"))
        TextField("Опции ssh", text: optionsText, prompt: Text("необязательно: -J bastion -i ~/.ssh/ключ"))
    }

    @ViewBuilder
    private var localFields: some View {
        HStack {
            TextField("Папка проекта", text: $workspace.path,
                      prompt: Text("~/Projects/мой-проект"))
            Button("Обзор…", action: chooseFolder)
                .help("Выбрать папку на этом Mac")
        }

        // Молча запретить «Сохранить» мало: надо сказать, ЧТО не так. Путь могли набрать руками
        // или папку успели переименовать после выбора.
        if !trimmedPath.isEmpty, !localFolderExists {
            Label("Такой папки нет — выберите её кнопкой «Обзор…»",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Theme.modified)
        }
    }

    @ViewBuilder
    private var access: some View {
        Toggle("Только чтение", isOn: $workspace.readOnly)
        Text(workspace.isLocal
             ? "Приложение не выполнит в папке проекта ни одной изменяющей команды: ни записи файла, ни git. Смотреть diff и код можно, изменить что-либо — нет."
             : "Приложение не выполнит на сервере ни одной изменяющей команды: ни записи файла, ни git. Смотреть diff и код можно, изменить что-либо — нет.")
            .font(.caption)
            .foregroundStyle(Theme.secondary)
    }

    private var hint: String {
        workspace.isLocal
            ? "Claude запускается прямо в этой папке — как если бы вы позвали его из терминала. Ничего своего приложение в неё не кладёт: только хуки уведомлений в .claude/settings.local.json, чтобы знать, когда Claude закончил или ждёт ответа."
            : "Сервер берётся из вашего ~/.ssh/config — алиасы, ключи, ProxyJump и agent работают как в обычном ssh. На сервер ничего устанавливать не нужно."
    }

    // MARK: - Действия

    /// Выбор папки на Mac. Системная панель, а не поле для ввода пути: путь к папке никто
    /// не помнит наизусть, а опечатка в нём — это проект, который не откроется.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Выберите папку проекта на этом Mac"
        panel.prompt = "Выбрать"
        if localFolderExists { panel.directoryURL = URL(fileURLWithPath: trimmedPath) }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.path = url.path
        nameFromFolder(url.path)
        checkResult = nil
    }

    /// Имя проекта = имя папки. Только пока поле пустое: своё название, если его уже вписали,
    /// перебивать выбором папки нельзя.
    private func nameFromFolder(_ path: String) {
        guard workspace.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        workspace.name = (path as NSString).lastPathComponent
    }

    private func save() {
        workspace.path = trimmedPath
        nameFromFolder(workspace.path)
        onSave(workspace)
        dismiss()
    }

    /// Быстрая проверка «а есть ли вообще такой путь и репозиторий» — чтобы не выяснять это
    /// уже в открытом окне.
    ///
    /// Проверка одна на оба вида проекта, и это не экономия строк: и «есть ли каталог», и «есть ли
    /// git» спрашиваются одними и теми же POSIX-скриптами через Connection — разница только в том,
    /// кто их исполнит (см. Connection).
    private func check() async {
        checking = true
        checkResult = nil
        defer { checking = false }

        let conn: Connection = workspace.isLocal
            ? LocalConnection()
            : SSHConnection(
                host: workspace.host.trimmingCharacters(in: .whitespaces),
                port: workspace.port,
                extraArgs: workspace.extraSSHArgs
            )
        await conn.connect()

        guard conn.state.isConnected else {
            checkOK = false
            if case .failed(let msg) = conn.state {
                checkResult = msg
            } else {
                checkResult = "Не удалось подключиться"
            }
            return
        }
        defer { conn.disconnect() }

        let path = trimmedPath
        guard await RemoteFS.isDir(conn: conn, path: path) else {
            checkOK = false
            checkResult = workspace.isLocal
                ? "Папки \(path) нет"
                : "Подключились, но каталога \(path) на сервере нет"
            return
        }
        if let root = await Git.repoRoot(conn: conn, path: path) {
            checkOK = true
            checkResult = "Готово. Git-репозиторий: \(root)"
        } else {
            checkOK = true
            checkResult = "Готово. Git-репозитория нет — будет только дерево файлов, без diff."
        }
    }
}
