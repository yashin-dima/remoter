import SwiftUI

/// Вкладки — как в браузере.
///
/// Сначала разговоры с Claude: их несколько, и они первые, потому что разговор с ним и есть
/// основная работа. Дальше — терминалы на сервере, открытые из раздела Terminal. Дальше — файлы:
/// цветная полоска сверху и буква статуса показывают, что с файлом (M — изменён, A — новый),
/// точка справа — есть несохранённые правки. Курсив — предпросмотр: вкладка открыта одним кликом
/// и будет заменена следующим.
///
/// «+» стоит последней и не двигается: кнопка, которая переезжает по мере того, как открываются
/// вкладки, — это кнопка, в которую надо целиться заново каждый раз.
struct TabBar: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    // Разговоры с Claude. Их может быть несколько: над проектом идут разные задачи,
                    // и открывать новую, обрывая текущую, бессмысленно.
                    ForEach(model.claudeTabs) { tab in
                        LiveTab(
                            title: tab.shownTitle,
                            icon: "sparkle",
                            isBusy: tab.isBusy,
                            isActive: model.pane == .claude(tab.id),
                            closeHelp: "Закрыть сессию. Разговор сохранится — "
                                + "его можно открыть из списка сессий.",
                            onSelect: {
                                model.pane = .claude(tab.id)
                                model.terminal.focus(tab.terminal)
                                model.markActiveSessionSeen()
                            },
                            onClose: { model.closeSession(tab.id) },
                            onRename: { model.startRenaming(tab.id) }
                        )
                        Divider().frame(height: 20)
                    }

                    // Вкладок терминала здесь нет: терминал живёт панелью ПОД окном, а не рядом
                    // с разговором. Вывод команды нужен одновременно с разговором и с diff'ом,
                    // а не вместо них.

                    ForEach(model.tabs, id: \.absPath) { tab in
                        TabItem(
                            tab: tab,
                            isActive: model.pane == .file && tab.absPath == model.activePath,
                            onSelect: { model.activate(path: tab.absPath) },
                            onPin: { model.pinTab(path: tab.absPath) },
                            onClose: { model.closeTab(path: tab.absPath) },
                            onCloseOthers: { model.closeOtherTabs(keeping: tab.absPath) }
                        )
                        .id(tab.absPath)
                        Divider().frame(height: 20)
                    }

                    // Плюс — новая сессия. Спросит параметры и откроется рядом с текущей.
                    // Всегда правее всех вкладок, сколько бы их ни было.
                    Button {
                        model.isNewSessionPresented = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: D.s(13), weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                            .frame(width: D.s(36), height: D.Size.tab)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Новая сессия Claude (⇧⌘T) — рядом с текущей, не прерывая её")

                    Spacer(minLength: 0)
                }
            }
            .onChange(of: model.activePath) { _, new in
                guard let new else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
        .frame(height: D.Size.tab)
        .background(Theme.bg)
    }
}

/// Крестик вкладки — один на все виды вкладок (файлы, сессии, терминалы).
///
/// Занимает своё место всегда, а не появляется под курсором вместо точки: место не должно
/// прыгать под рукой. И нажимается по всему квадрату в 24 точки, а не по самому рисунку —
/// раньше в него приходилось целиться, и промахнуться было проще, чем попасть.
private struct TabCloseButton: View {
    /// Курсор над вкладкой — крестик видно. Без наведения показывается точка `isDirty`.
    let tabHovering: Bool
    var isDirty = false
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(hovering ? Theme.hover : .clear)
                    .frame(width: 20, height: 20)

                if tabHovering || hovering {
                    Image(systemName: "xmark")
                        .font(.system(size: D.s(9), weight: .bold))
                        .foregroundStyle(hovering ? Theme.text : Theme.secondary)
                } else if isDirty {
                    Circle()
                        .fill(Theme.modified)
                        .frame(width: 7, height: 7)
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Вкладка с живым процессом: разговор с Claude или терминал на сервере.
///
/// Закрыть можно и то, и другое. Разговор при этом не пропадает: он записан в журнал Claude
/// и открывается заново из списка сессий.
private struct LiveTab: View {
    let title: String
    let icon: String
    /// Claude сейчас отвечает. Открыто несколько сессий — и без этого непонятно, которая работает,
    /// а которая ждёт вас.
    let isBusy: Bool
    let isActive: Bool
    let closeHelp: String
    let onSelect: () -> Void
    let onClose: () -> Void
    /// Переименование доступно только у сессий Claude; у терминалов на сервере — nil.
    var onRename: (() -> Void)? = nil

    @State private var hovering = false
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            // Пока Claude отвечает — кружок вместо иконки: моргающая иконка читалась как «что-то
            // сломалось», а спокойно пульсирующая точка — как «идёт работа». В покое возвращается
            // обычная иконка сессии. Ширина одна и та же, чтобы текст рядом не прыгал.
            ZStack {
                if isBusy {
                    Circle()
                        .fill(isActive ? Theme.accent : Theme.secondary)
                        .frame(width: D.s(9), height: D.s(9))
                        .scaleEffect(pulse ? 1 : 0.55)
                        .opacity(pulse ? 1 : 0.5)
                        .onAppear { pulse = true }
                        .onDisappear { pulse = false }
                } else {
                    Image(systemName: icon)
                        .font(.system(size: D.s(12), weight: .medium))
                        .foregroundStyle(isActive ? Theme.accent : Theme.secondary)
                }
            }
            .frame(width: D.s(14))
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)

            Text(title)
                .font(isActive ? D.Text.bodyMedium : D.Text.body)
                .foregroundStyle(isActive ? Theme.text : Theme.secondary)
                .lineLimit(1)
                .frame(maxWidth: D.s(160))

            TabCloseButton(tabHovering: hovering, help: closeHelp, action: onClose)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: D.Size.tab)
        .background(alignment: .top) {
            if isActive {
                Rectangle().fill(Theme.accent).frame(height: 2)
            }
        }
        .background(isActive ? Theme.surface : (hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(title)
        .contextMenu {
            if let onRename {
                Button("Переименовать…", action: onRename)
                Divider()
            }
            Button("Закрыть", action: onClose)
        }
    }
}

private struct TabItem: View {
    let tab: OpenDoc
    let isActive: Bool
    let onSelect: () -> Void
    /// Оставить вкладку насовсем — двойной клик по ней. Так же, как в VS Code.
    let onPin: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            if let kind = tab.kind {
                Text(kind.letter)
                    .font(D.Text.badge)
                    .foregroundStyle(kind.color)
            }

            // Курсив — предпросмотр: файл открыт «на посмотреть», и следующий одиночный клик
            // в дереве заменит его. Двойной клик по вкладке оставляет её насовсем.
            Text(tab.title)
                .font(isActive ? D.Text.bodyMedium : D.Text.body)
                .italic(tab.isPreview)
                .foregroundStyle(isActive ? Theme.text : Theme.secondary)
                .lineLimit(1)

            TabCloseButton(
                tabHovering: hovering,
                isDirty: tab.isDirty,
                help: tab.isDirty ? "Закрыть (есть несохранённые правки)" : "Закрыть",
                action: onClose
            )
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: D.Size.tab)
        .background(alignment: .top) {
            if isActive {
                Rectangle()
                    .fill(tab.kind?.color ?? Theme.accent)
                    .frame(height: 2)
            }
        }
        .background(isActive ? Theme.surface : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onPin() }
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(tab.isPreview
              ? (tab.relPath ?? tab.absPath) + "\nПредпросмотр — двойной клик оставит вкладку"
              : (tab.relPath ?? tab.absPath))
        .contextMenu {
            if tab.isPreview {
                Button("Оставить вкладку", action: onPin)
                Divider()
            }
            Button("Закрыть", action: onClose)
            Button("Закрыть остальные", action: onCloseOthers)
        }
    }
}

extension ChangeKind {
    var color: Color {
        switch self {
        case .modified:          return Theme.modified
        case .added, .untracked: return Theme.added
        case .deleted:           return Theme.removed
        case .renamed:           return Theme.renamed
        case .conflicted:        return Theme.conflicted
        }
    }
}
