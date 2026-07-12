import SwiftUI
import AppKit

/// Прошлые разговоры с Claude по этому проекту.
///
/// Журнал сессий ведёт сам Claude Code — мы его только читаем и показываем. Вернуться в любой
/// разговор можно одним нажатием: в терминал уйдёт обычный `claude --resume <id>`, видимый
/// целиком, без скрытых действий.
struct SessionsView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss

    @State private var renamingSession: ClaudeSession?
    @State private var renameText = ""

    private var renamingBinding: Binding<Bool> {
        Binding(
            get: { renamingSession != nil },
            set: { if !$0 { renamingSession = nil } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.isLoadingSessions && model.sessions.isEmpty {
                loading
            } else if model.sessions.isEmpty {
                empty
            } else {
                list
            }

            Divider()
            footer
        }
        .frame(width: D.s(620), height: D.s(520))
        .task { await model.loadSessions() }
        .alert("Переименовать сессию", isPresented: renamingBinding) {
            TextField("Название", text: $renameText)
            Button("Отмена", role: .cancel) { renamingSession = nil }
            Button("Сохранить") {
                if let s = renamingSession { model.renameSession(s.id, to: renameText) }
                renamingSession = nil
            }
        } message: {
            Text("Пустое имя вернёт автоматический заголовок Claude.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: D.s(16), weight: .medium))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("Сессии Claude")
                    .font(.system(size: D.s(15), weight: .semibold))
                Text(model.workspace.name)
                    .font(D.Text.caption)
                    .foregroundStyle(Theme.secondary)
            }

            Spacer()

            if model.isLoadingSessions {
                ProgressView().controlSize(.small)
            }

            IconButton(icon: "arrow.clockwise", size: 13, help: "Обновить") {
                Task { await model.loadSessions() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(model.sessions) { session in
                    SessionRow(
                        title: model.displayTitle(for: session),
                        session: session,
                        onResume: {
                            // Открывается ОТДЕЛЬНОЙ вкладкой, рядом с текущими: вернуться к старому
                            // разговору не значит оборвать тот, что идёт сейчас.
                            model.openSession(resuming: session)
                            dismiss()
                        },
                        onRename: {
                            renameText = model.displayTitle(for: session)
                            renamingSession = session
                        }
                    )
                }
            }
            .padding(12)
        }
    }

    private var loading: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Читаю журнал…")
                .font(D.Text.caption)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: D.s(34), weight: .light))
                .foregroundStyle(.tertiary)
            Text("Пока ни одной сессии")
                .font(D.Text.title)
            Text("Запустите Claude — и разговор появится здесь. Вернуться в него можно будет одним нажатием.")
                .font(D.Text.caption)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Журнал ведёт сам Claude Code. Приложение его только читает.")
                .font(D.Text.caption)
                .foregroundStyle(Theme.secondary)

            Spacer()

            Button("Новая сессия") {
                model.openSession()
                dismiss()
            }
            .controlSize(.large)
            .disabled(!model.claudeInstalled || model.localPath.isEmpty)

            Button("Закрыть") { dismiss() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct SessionRow: View {
    let title: String
    let session: ClaudeSession
    let onResume: () -> Void
    let onRename: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: D.s(15)))
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: D.s(13), weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 6) {
                    Text(relativeTime(session.updated))
                    Text("·")
                    Text("\(session.messages) сообщений")
                }
                .font(D.Text.caption)
                .foregroundStyle(Theme.secondary)

                if !session.lastPrompt.isEmpty {
                    Text(session.lastPrompt)
                        .font(D.Text.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            RowActionButton(title: "Продолжить", prominent: hovering, action: onResume)
                .help("claude --resume \(session.id)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            hovering ? Theme.hover : Theme.bg,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(hovering ? Theme.accent.opacity(0.4) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onResume)
        .contextMenu {
            Button("Продолжить", action: onResume)
            Button("Переименовать…", action: onRename)
            Divider()
            Button("Копировать id сессии") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.id, forType: .string)
            }
        }
    }
}
