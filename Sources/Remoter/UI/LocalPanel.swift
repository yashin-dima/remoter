import SwiftUI
import AppKit

/// Вкладка «Локально»: рабочая папка Claude на Mac (~/Remoter/<проект>).
///
/// Сервер про Claude ничего не знает и знать не должен — поэтому его инструкция, документация
/// и заметки живут здесь, а не там. Заодно тут же видно конфиг доступа: чем именно приложение
/// подключается к серверу.
///
/// У проекта, который и так лежит на этом Mac, этого раздела нет вовсе (`model.sidebarTabs`):
/// его рабочая папка и есть сам проект, и второй раздел с тем же деревом только путал бы.
/// Поэтому всё серверное здесь можно было бы и не проверять — но карточка доступа всё-таки
/// проверяет: показывать хост и сокет проекту, у которого их нет, нельзя ни при каких условиях.
struct LocalPanel: View {
    @ObservedObject var model: WorkspaceModel

    @State private var showAccess = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if showAccess, !model.workspace.isLocal {
                AccessCard(model: model)
                Divider()
            }

            if model.localRows.isEmpty {
                empty
            } else {
                tree
            }
        }
        .onAppear { model.reloadLocalTree() }
        // Drop — на всю панель, включая пустую: в пустую папку первый файл и бросают.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task {
                let urls = await Self.fileURLs(from: providers)
                await MainActor.run { model.importLocal(urls: urls) }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .padding(3)
                    .allowsHitTesting(false)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: D.s(12)))
                .foregroundStyle(Theme.secondary)

            Text((model.localPath as NSString).abbreviatingWithTildeInPath)
                .font(D.Text.mono)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .help(model.localPath)

            Spacer()

            // Ключ — про доступ к серверу. У проекта на этом Mac сервера нет, и кнопка,
            // открывающая пустую карточку, была бы обещанием, которое нечем выполнить.
            if !model.workspace.isLocal {
                Button {
                    showAccess.toggle()
                } label: {
                    Image(systemName: "key.fill")
                        .font(.system(size: D.s(12), weight: .medium))
                        .foregroundStyle(showAccess ? Theme.accent : Theme.secondary)
                        .frame(width: D.hit, height: D.hit)
                        .background(
                            showAccess ? Theme.accentSoft : .clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("Конфиг доступа к серверу")
            }

            Menu {
                Button("Новый файл…") { model.newLocalFile(in: model.selectedPath) }
                Button("Новая папка…") { model.newLocalFolder(in: model.selectedPath) }
                Divider()
                Button("Показать в Finder") { model.revealInFinder(model.localPath) }
                Button("Обновить") { model.reloadLocalTree() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: D.s(13), weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: D.hit, height: D.hit)
        }
        .padding(.horizontal, D.Pad.bar)
        .frame(height: D.s(32))
        .background(Theme.bg)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: D.s(30), weight: .light))
                .foregroundStyle(.tertiary)
            Text("Папка пуста")
                .font(D.Text.title)
                .foregroundStyle(Theme.secondary)
            Button("Создать заметку") { model.newLocalFile(in: nil) }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tree: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.localRows) { row in
                    LocalRow(row: row, model: model)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    @State private var dropTargeted = false

    /// Провайдеры перетаскивания → URL файлов. Асинхронно: NSItemProvider отдаёт их колбэком.
    private static func fileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for p in providers where p.hasItemConformingToTypeIdentifier("public.file-url") {
            let url: URL? = await withCheckedContinuation { cont in
                _ = p.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
            }
            if let url { urls.append(url) }
        }
        return urls
    }
}

private struct LocalRow: View {
    let row: TreeRow
    @ObservedObject var model: WorkspaceModel

    @State private var hovering = false

    /// CLAUDE.md — не просто файл, а то, что Claude читает при каждом запуске.
    /// Отмечаем, чтобы его не приняли за очередную заметку.
    private var isInstruction: Bool { row.entry.name == "CLAUDE.md" }
    private var isScript: Bool { row.entry.name == "remote" }

    var body: some View {
        HStack(spacing: 5) {
            TreeRowLead(
                depth: row.depth,
                isDir: row.entry.isDir,
                isExpanded: row.isExpanded,
                icon: icon,
                iconColor: iconColor
            )

            Text(row.entry.name)
                .font(isInstruction ? D.Text.bodyMedium : D.Text.body)
                .lineLimit(1)
                .truncationMode(.middle)

            if isInstruction {
                Text("для Claude")
                    .font(.system(size: D.s(10), weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.accentSoft, in: Capsule())
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, D.Pad.row)
        .frame(height: D.Size.row)
        .background(RowBackground(
            selected: model.selectedPath == row.entry.path,
            hovering: hovering
        ))
        .contentShape(Rectangle())
        // Двойной клик — раньше одиночного: иначе SwiftUI отдаёт клик первому обработчику
        // и до второго дело не доходит.
        .onTapGesture(count: 2) {
            guard !row.entry.isDir else { return }
            model.openLocalFile(row.entry.path)   // закрепить вкладку
        }
        .onTapGesture {
            if row.entry.isDir {
                model.selectedPath = row.entry.path
                model.toggleLocal(row.entry)
            } else {
                model.openLocalFile(row.entry.path, preview: true)
            }
        }
        .onHover { hovering = $0 }
        .help(row.entry.path)
        .contextMenu {
            if !row.entry.isDir {
                Button("Открыть") { model.openLocalFile(row.entry.path) }
            }
            Button("Показать в Finder") { model.revealInFinder(row.entry.path) }
            Divider()
            Button("Новый файл…") { model.newLocalFile(in: row.entry.path) }
            Button("Новая папка…") { model.newLocalFolder(in: row.entry.path) }
            Divider()
            Button("Удалить в корзину", role: .destructive) { model.trashLocal(row.entry.path) }
        }
    }

    private var icon: String {
        if row.entry.isDir { return row.isExpanded ? "folder" : "folder.fill" }
        if isInstruction { return "sparkle" }
        if isScript { return "terminal" }
        return "doc.text"
    }

    private var iconColor: Color {
        // Те же цвета, что у серверного дерева: два дерева в одной панели
        // не должны выглядеть по-разному.
        if row.entry.isDir { return Theme.accent }
        if isInstruction { return Theme.accent }
        return Theme.secondary
    }
}

/// Конфиг доступа: чем именно приложение подключается к серверу. Полезно и просто чтобы
/// посмотреть, и чтобы скопировать команду, когда нужно зайти руками откуда-то ещё.
///
/// Карточка целиком про ssh — и потому у проекта на этом Mac не рисуется НИЧЕГО. Хост, порт,
/// опции и сокет у него пусты по определению: нарисуй мы их, вышла бы карточка с пустыми
/// строками и командой `ssh` без хоста — как будто настройки потерялись.
private struct AccessCard: View {
    @ObservedObject var model: WorkspaceModel

    private var sshCommand: String {
        var parts = ["ssh"]
        if let port = model.workspace.port { parts += ["-p", String(port)] }
        parts += model.workspace.extraSSHArgs
        parts.append(model.workspace.host)
        return parts.joined(separator: " ")
    }

    var body: some View {
        if model.workspace.isLocal {
            EmptyView()
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Сервер", model.workspace.host)
            if let port = model.workspace.port {
                row("Порт", String(port))
            }
            row("Каталог", model.repoRoot ?? model.basePath)
            if !model.workspace.extraSSHArgs.isEmpty {
                row("Опции ssh", model.workspace.sshOptions ?? "")
            }
            if let ssh = model.conn as? SSHConnection {
                row("Канал", (ssh.controlSocket as NSString).abbreviatingWithTildeInPath)
            }

            Divider().padding(.vertical, 2)

            HStack(spacing: 6) {
                Text(sshCommand)
                    .font(.system(size: D.s(10), design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sshCommand, forType: .string)
                    model.toast(.success, "Команда скопирована")
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: D.s(10)))
                }
                .buttonStyle(.borderless)
                .help("Скопировать команду подключения")
            }

            if model.workspace.readOnly {
                Label("Только чтение — изменить на сервере ничего нельзя", systemImage: "lock.fill")
                    .font(.system(size: D.s(10)))
                    .foregroundStyle(Theme.modified)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.bg)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: D.s(10)))
                .foregroundStyle(Theme.secondary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(.system(size: D.s(10), design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
                .help(value)
            Spacer(minLength: 0)
        }
    }
}
