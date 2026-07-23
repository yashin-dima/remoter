import SwiftUI

/// Обзор папок на сервере: путь выбирается кликами, а не вспоминается наизусть.
///
/// Начинаем с домашнего каталога — там почти всегда и лежит то, что нужно. Папки с git-репозиторием
/// помечены: обычно ищут именно их.
struct RemotePathPicker: View {
    let host: String
    let port: Int?
    let extraArgs: [String]
    /// Пароль, набранный в форме проекта: обзор открывают ДО сохранения, и в связке ключей
    /// пароля ещё нет. Пусто — соединение возьмёт сохранённый, если он есть.
    var password: String?
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var conn: SSHConnection?
    @State private var status = "Подключение…"
    @State private var current = "/"
    @State private var entries: [RemoteEntry] = []
    @State private var repoDirs: Set<String> = []
    @State private var isLoading = false
    @State private var failed: String?

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            Divider()

            if let failed {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: D.s(28), weight: .light))
                        .foregroundStyle(.orange)
                    Text(failed)
                        .font(.callout)
                        .foregroundStyle(Theme.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty && !isLoading {
                Text("Внутри нет папок")
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }

            Divider()
            footer
        }
        .frame(width: D.s(620), height: D.s(460))
        .task { await start() }
        .onDisappear { conn?.disconnect() }
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Button {
                Task { await go(to: (current as NSString).deletingLastPathComponent) }
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(current == "/" || isLoading)
            .help("На уровень выше")

            Image(systemName: "server.rack")
                .font(.system(size: D.s(11)))
                .foregroundStyle(Theme.secondary)

            Text(current)
                .font(.system(size: D.s(12), design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)

            Spacer()

            if isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: repoDirs.contains(entry.path) ? "folder.fill.badge.gearshape" : "folder.fill")
                            .font(.system(size: D.s(12)))
                            .foregroundStyle(repoDirs.contains(entry.path) ? Theme.accent : Theme.secondary)
                            .frame(width: 16)

                        Text(entry.name)
                            .font(.system(size: D.s(13)))

                        if repoDirs.contains(entry.path) {
                            Text("git")
                                .font(.system(size: D.s(9), weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Theme.accent, in: Capsule())
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: D.s(9)))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    // Пока грузится один каталог, второй не открываем: два параллельных go()
                    // гонялись бы за current/entries, и git-метки прошлой папки доезжали бы в новую.
                    .onTapGesture {
                        guard !isLoading else { return }
                        Task { await go(to: entry.path) }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var footer: some View {
        HStack {
            Text(status)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            Spacer()
            Button("Отмена") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Выбрать эту папку") {
                onPick(current)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(conn?.state.isConnected != true)
        }
        .padding(12)
    }

    // MARK: -

    private func start() async {
        let c = SSHConnection(host: host, port: port, extraArgs: extraArgs, password: password)
        // Сохранить ДО connect(): закрыли окно, пока подключение шло, — onDisappear всё равно
        // должен его разорвать. Иначе установившийся ssh-канал повисал бы сиротой до выхода
        // из приложения.
        conn = c
        await c.connect()

        guard c.state.isConnected else {
            if case .failed(let msg) = c.state { failed = msg } else { failed = "Не удалось подключиться" }
            return
        }
        await go(to: await RemoteFS.home(conn: c))
    }

    private func go(to path: String) async {
        guard let conn else { return }
        let target = path.isEmpty ? "/" : path

        isLoading = true
        defer { isLoading = false }

        do {
            let dirs = try await RemoteFS.listDirs(conn: conn, dir: target)
            current = target
            entries = dirs
            status = "Папок: \(dirs.count)"

            // Метки git ставим после отрисовки: ждать проверки каждой папки перед показом
            // списка — значит подвесить окно на ровном месте.
            repoDirs = []
            await withTaskGroup(of: (String, Bool).self) { group in
                for d in dirs {
                    group.addTask { (d.path, await RemoteFS.isGitRepo(conn: conn, path: d.path)) }
                }
                for await (path, isRepo) in group where isRepo {
                    repoDirs.insert(path)
                }
            }
        } catch {
            status = "Не удалось открыть \(target)"
        }
    }
}
