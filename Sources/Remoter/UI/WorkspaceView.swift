import SwiftUI
import AppKit

struct WorkspaceHostView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    let workspaceID: UUID?

    @State private var model: WorkspaceModel?

    var body: some View {
        ZStack {
            if let model {
                WorkspaceView(model: model)
            } else {
                Color.clear
            }
        }
        .onAppear(perform: setUp)
    }

    /// Окно без проекта — не окно. Здесь оно закрывается, а вместо него открывается список.
    ///
    /// Так бывает по двум причинам. Первая: проект удалили, а окно осталось. Вторая, неочевидная:
    /// при следующем запуске SwiftUI сам воссоздаёт окно последней сцены — но КАКОЙ это был
    /// проект, не запоминает, и окно приезжает пустым. А поскольку список закрывается сразу после
    /// открытия проекта, последней сценой почти всегда оказывается именно окно проекта. В итоге
    /// приложение стартовало с пустым окном и вообще без списка проектов.
    private func setUp() {
        guard model == nil else { return }

        guard let ws = store.workspace(id: workspaceID) else {
            openWindow(id: "launcher")   // сначала открыть новое окно, потом закрыть это:
            dismiss()                    // иначе на миг не остаётся ни одного и приложение выходит
            return
        }
        model = WorkspaceModel(workspace: ws)
    }
}

struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.openWindow) private var openWindow

    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 300

    // Модификаторы разнесены по нескольким шагам намеренно: одной цепочкой из полутора десятков
    // штук компилятор Swift давится и сдаётся с «unable to type-check in reasonable time».
    var body: some View {
        split
            .background(WindowReader { model.window = $0 })
            .navigationTitle(model.workspace.name)
            .navigationSubtitle(model.workspace.subtitle)
            .toolbar { toolbar }
            .focusedSceneValue(\.workspaceModel, model)
            .overlay(alignment: .bottomTrailing) { NotificationStack(model: model) }
            .modifier(Lifecycle(model: model, settings: settings,
                                colorScheme: colorScheme, activeState: activeState))
            .modifier(Sheets(model: model))
    }

    /// Боковая панель — не отдельное окно, а левая колонка этого же окна.
    ///
    /// Раньше здесь был NavigationSplitView, и он рисовал сайдбар по-своему: полупрозрачный
    /// материал, скруглённый правый край, собственные отступы. Получалась картинка, где панель
    /// будто лежит поверх окна, а не входит в него. Обычная колонка с вертикальной чертой —
    /// такой же разделитель, как между всеми остальными частями интерфейса — читается как одно
    /// целое, ради чего всё и затевалось.
    private var split: some View {
        HStack(spacing: 0) {
            SidebarView(model: model)
                .frame(width: sidebarWidth)
                .background(Theme.bg)
                // Размеры считаются внутри D от масштаба, а он статический — сам по себе
                // перерисовку не вызывает. Смена id перестраивает панель. Терминалы сюда
                // не попадают: их пересоздание убило бы работающего в них Claude.
                .id(settings.scale)

            ColumnHandle(width: $sidebarWidth)

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Всё, что не боковая панель: ряд вкладок, содержимое вкладки — и терминал под ним.
    ///
    /// Терминалы смонтированы ВСЕГДА, просто невидимы: размонтируй их при переключении — и
    /// запущенный в них Claude (или идущая сборка) умрёт вместе с view.
    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            TabBar(model: model)
                .id(settings.scale)
            Divider()

            GeometryReader { geo in
                split(total: geo.size.height)
            }
        }
        .background(Theme.surface)
    }

    /// Высота ручки-разделителя между содержимым и терминалом.
    private let handleHeight: CGFloat = 9

    /// Содержимое вкладки сверху, терминал снизу.
    ///
    /// Устроено ZStack'ом, а не простым VStack, ровно по одной причине: свёрнутая панель не имеет
    /// права убивать терминал. Терминал лежит СНИЗУ и всегда одного размера — а свёрнутая панель
    /// просто накрывается содержимым во весь рост. Собери мы это VStack'ом, «свернуть» означало бы
    /// высоту 0 — то есть терминал на ноль строк и оборванную сборку.
    @ViewBuilder
    private func split(total: CGFloat) -> some View {
        let open = model.isTerminalPanelOpen && model.isTerminalReady
        let panelH = panelHeight(total: total)
        let topH = open ? max(D.s(120), total - panelH - handleHeight) : total

        ZStack(alignment: .top) {
            // Терминал окна — смонтирован всегда, даже когда панель свёрнута.
            if model.isTerminalReady {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    terminalView(model.shellTerminal, isVisible: open)
                        .frame(height: panelH)
                }
            }

            VStack(spacing: 0) {
                panes
                    .frame(height: topH)
                    .background(Theme.surface)   // непрозрачный: свёрнутый терминал под ним не виден
                    .clipped()

                if open {
                    TerminalSplitHandle(fraction: $model.terminalPanelFraction, total: total)
                        .frame(height: handleHeight)
                    // Окно в панель: терминал нарисован под нами, клики уходят к нему.
                    Color.clear
                        .frame(height: panelH)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Высота терминала. Не даём ни ему, ни содержимому схлопнуться в полоску.
    private func panelHeight(total: CGFloat) -> CGFloat {
        let raw = total * model.terminalPanelFraction
        return min(max(raw, D.s(80)), max(D.s(80), total - D.s(140)))
    }

    /// Содержимое вкладки: редактор или разговор с Claude.
    @ViewBuilder
    private var panes: some View {
        ZStack {
            editor
                .opacity(model.pane == .file ? 1 : 0)
                .allowsHitTesting(model.pane == .file)

            if model.isTerminalReady {
                terminals
            }
        }
    }

    private var editor: some View {
        // Смена id безопасна: WKWebView живёт в модели (bridge.webView), пересоздаётся только
        // SwiftUI-обёртка. Без этого шапка редактора после смены масштаба оставалась старого
        // размера рядом с уже перестроенным сайдбаром.
        //
        // Терминалы масштабом НЕ пересоздаются принципиально: вместе с view умер бы работающий
        // в них Claude. У них от масштаба зависит только шрифт, и он меняется на лету
        // в TerminalPane.updateNSView.
        EditorPane(model: model)
            .id(settings.scale)
    }

    @ViewBuilder
    private var terminals: some View {
        // Каждая сессия — свой терминал, и все они смонтированы одновременно: размонтируй
        // невидимую — и работающий в ней Claude умрёт вместе с view.
        ForEach(model.claudeTabs) { tab in
            let active = model.pane == .claude(tab.id)

            VStack(spacing: 0) {
                ClaudeBar(model: model, tab: tab)
                    .id(settings.scale)
                Divider()
                terminalView(tab.terminal, isVisible: active)
            }
            .opacity(active ? 1 : 0)
            .allowsHitTesting(active)
        }
    }

    @ViewBuilder
    private func terminalView(_ side: TerminalID, isVisible: Bool) -> some View {
        TerminalPane(
            side: side,
            launch: model.conn.terminalLaunch,
            remotePath: model.workspace.path,
            localPath: model.localPath,
            attachmentsDir: model.attachmentsDir,
            localEnv: model.localEnv,
            handle: model.terminal,
            fontSize: CGFloat(settings.terminalFontSize),
            isVisible: isVisible,
            onOpenLink: { link in model.openLink(link) }
        )
        // Поменялась папка проекта — терминал пересоздаётся: иначе он остался бы в старой.
        .id(model.localPath + String(describing: side))
    }

    private struct Lifecycle: ViewModifier {
        @ObservedObject var model: WorkspaceModel
        @ObservedObject var settings: AppSettings
        let colorScheme: ColorScheme
        let activeState: ControlActiveState

        // Цепочка разбита надвое намеренно: одной длинной компилятор Swift давится
        // и сдаётся с «unable to type-check in reasonable time».
        func body(content: Content) -> some View {
            let lifecycle = content
                .task { await model.start() }
                .onDisappear { model.stop() }
                // Опрашивать сервер, когда окно неактивно, незачем — встаём на паузу.
                // Вернулись к окну — сессия, на которую смотрим, считается просмотренной.
                .onChange(of: activeState) { _, new in
                    model.setPaused(new == .inactive)
                    if new != .inactive { model.markActiveSessionSeen() }
                }

            return lifecycle
                .onChange(of: colorScheme) { _, new in model.monaco.setTheme(dark: new == .dark) }
                .onChange(of: settings.editorFontSize) { _, new in model.monaco.setFontSize(new) }
                .onAppear {
                    model.monaco.setTheme(dark: colorScheme == .dark)
                    model.monaco.setFontSize(settings.editorFontSize)
                }
        }
    }

    private struct Sheets: ViewModifier {
        @ObservedObject var model: WorkspaceModel

        private var errorBinding: Binding<Bool> {
            Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        }

        private var renamingBinding: Binding<Bool> {
            Binding(
                get: { model.renamingTabID != nil },
                set: { if !$0 { model.renamingTabID = nil } }
            )
        }

        /// Вкладка, чьи картинки показываем. Sheet берёт её по id, а не держит копию: вкладка
        /// живёт своей жизнью (журнал дочитывается, заголовок меняется), и копия быстро протухла бы.
        private var attachmentsTab: ClaudeTab? {
            guard let id = model.attachmentsTabID else { return nil }
            return model.claudeTabs.first { $0.id == id }
        }

        private var attachmentsBinding: Binding<Bool> {
            Binding(
                get: { attachmentsTab != nil },
                set: { if !$0 { model.attachmentsTabID = nil } }
            )
        }

        func body(content: Content) -> some View {
            content
                .sheet(isPresented: $model.isQuickOpenPresented) { QuickOpenView(model: model) }
                .sheet(isPresented: $model.isSessionsPresented) { SessionsView(model: model) }
                .sheet(isPresented: $model.isNewSessionPresented) { NewSessionView(model: model) }
                .sheet(isPresented: attachmentsBinding) {
                    if let tab = attachmentsTab {
                        AttachmentsView(model: model, tab: tab)
                    }
                }
                .alert("Ошибка", isPresented: errorBinding) {
                    Button("OK", role: .cancel) { model.errorMessage = nil }
                } message: {
                    Text(model.errorMessage ?? "")
                }
                .alert("Переименовать сессию", isPresented: renamingBinding) {
                    TextField("Название", text: $model.renameText)
                    Button("Отмена", role: .cancel) { model.renamingTabID = nil }
                    Button("Сохранить") { model.commitRename() }
                } message: {
                    Text("Пустое имя вернёт автоматический заголовок Claude.")
                }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Пока связь есть, показывать зелёную плашку с хостом незачем: он и так написан
        // в подзаголовке окна рядом с путём. Плашка появляется, только когда со связью
        // что-то не так, — то есть ровно тогда, когда о ней хочется знать.
        //
        // У проекта на этом Mac она не появляется никогда: LocalConnection всегда connected —
        // связываться не с чем, и «нет связи» про собственную папку было бы бессмыслицей.
        ToolbarItem(placement: .navigation) {
            if !model.conn.state.isConnected {
                ConnectionBadge(conn: model.conn) {
                    Task { await model.conn.connect() }
                }
            }
        }

        // Название проекта — по центру окна, с его иконкой. Ничего больше: ни рамки, ни пути.
        //
        // Штатный заголовок macOS рисует мелким и прижимает влево, где он теряется среди кнопок.
        // А окон открыто несколько, и первый вопрос к любому из них — «это какой проект?».
        // Ответ на него — имя и картинка; сервер и путь на этот вопрос не отвечают, а шум создают
        // (они и так есть в подсказке и в списке проектов).
        // Своей подложки у заголовка нет. Ту «капсулу», что была вокруг него, рисует сама macOS:
        // в новых версиях элементы тулбара живут в общем стеклянном контейнере (те же капсулы —
        // и вокруг кнопок справа). Прячем её штатно; на старых системах такого API нет, и там
        // заголовок остаётся с системным фоном — это не повод не собраться.
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .principal) {
                ProjectTitle(name: model.workspace.name,
                             icon: model.icon,
                             isLocal: model.workspace.isLocal,
                             subtitle: model.workspace.subtitle)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) {
                ProjectTitle(name: model.workspace.name,
                             icon: model.icon,
                             isLocal: model.workspace.isLocal,
                             subtitle: model.workspace.subtitle)
            }
        }

        ToolbarItemGroup {
            if model.isBusy {
                ProgressView().controlSize(.small)
            }

            // Единственная дверь к списку проектов. Сам он больше нигде и никогда не всплывает:
            // открыв проект, вы работаете, а не отбиваетесь от окна выбора.
            Button {
                openWindow(id: "launcher")
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: D.s(14), weight: .semibold))
            }
            .help("Открыть ещё проект (⇧⌘O)")

            // Терминал теперь не вкладка, а панель под окном — кнопка её сворачивает и разворачивает.
            // Подсвечена, когда панель открыта: видно, что она есть, даже когда свёрнута.
            Button {
                model.toggleTerminalPanel()
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: D.s(14), weight: .medium))
                    .foregroundStyle(model.isTerminalPanelOpen ? Theme.accent : Theme.secondary)
            }
            .disabled(!model.isTerminalReady)
            .help(model.isTerminalPanelOpen
                  ? "Свернуть терминал (⌥⌘T). Он не закрывается — то, что в нём идёт, продолжит идти."
                  : (model.workspace.isLocal
                     ? "Показать терминал в папке проекта (⌥⌘T)"
                     : "Показать терминал на сервере (⌥⌘T)"))

            Button {
                Task { await model.refresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: D.s(14), weight: .medium))
            }
            .help("Обновить (⌘R)")

            // Кнопки «новая сессия» здесь нет: она и так стоит в ряду вкладок, правее всех,
            // где ей и место. Две кнопки на одно действие — это вопрос «а есть ли разница?».
            Button {
                model.isSessionsPresented = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: D.s(14), weight: .medium))
            }
            .disabled(model.localPath.isEmpty)
            .help("Сессии Claude по этому проекту (⇧⌘J)")
        }
    }
}

/// Название проекта по центру заголовка окна — только имя и иконка.
///
/// Своей подложки мы не рисуем. Ту «капсулу», что была видна вокруг заголовка, рисует сама macOS:
/// в новых версиях элементы тулбара живут в общем стеклянном контейнере (те же капсулы видны и
/// вокруг кнопок справа). Прячем её штатно — `sharedBackgroundVisibility(.hidden)`; на системах,
/// где такого API нет, заголовок просто останется с системной подложкой, и это не повод не собраться.
struct ProjectTitle: View {
    let name: String
    let icon: NSImage?
    let isLocal: Bool
    let subtitle: String

    var body: some View {
        HStack(spacing: D.s(8)) {
            ProjectIconView(image: icon, isLocal: isLocal, size: D.s(20))

            Text(name)
                .font(.system(size: D.s(14), weight: .semibold))
                .lineLimit(1)
        }
        .help(subtitle)   // сервер и путь — в подсказке: в заголовке они только шумят
    }
}

/// Иконка проекта: та, что вы ему задали (файлом или favicon сайта), иначе штатная.
///
/// Одна на список проектов и на заголовок окна — чтобы проект выглядел одинаково там и там.
struct ProjectIconView: View {
    let image: NSImage?
    let isLocal: Bool
    var size: CGFloat = 18

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                // Favicon'ы бывают квадратные и без скруглений — лёгкая маска роднит их
                // с остальными иконками macOS.
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        } else {
            Image(systemName: isLocal ? "laptopcomputer" : "server.rack")
                .font(.system(size: size * 0.8, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Уведомления

/// Всплывашки в углу: что грузится и что загрузилось. Не модальные — работать не мешают,
/// клики сквозь них проходят.
struct NotificationStack: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(model.uploads) { job in
                HStack(spacing: 10) {
                    ProgressView(value: job.fraction)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.name)
                            .font(.system(size: D.s(12), weight: .medium))
                            .lineLimit(1)
                        Text("\(byteString(job.sent)) из \(byteString(job.total))")
                            .font(.system(size: D.s(10)))
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
            }

            ForEach(model.toasts) { toast in
                HStack(spacing: 8) {
                    Image(systemName: toast.kind == .success
                          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(toast.kind == .success ? Theme.added : Theme.modified)
                    Text(toast.text)
                        .font(.system(size: D.s(12)))
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: 340, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(16)
        .animation(.spring(duration: 0.28), value: model.toasts)
        .animation(.spring(duration: 0.28), value: model.uploads)
        .allowsHitTesting(false)
    }
}

/// Состояние соединения. Живёт в тулбаре, потому что это первое, что хочется знать,
/// когда «ничего не обновляется».
struct ConnectionBadge: View {
    @ObservedObject var conn: Connection
    let reconnect: () -> Void

    var body: some View {
        switch conn.state {
        case .connected:
            // Недостижимо: тулбар рендерит бейдж только когда связи НЕТ (см. toolbar выше).
            // Ветка нужна лишь для полноты switch.
            EmptyView()
        case .connecting:
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("Подключение…").font(.system(size: D.s(11))).foregroundStyle(Theme.secondary)
            }
        case .idle:
            // Хост есть только у ssh-проекта; у локального бейдж вообще не показывается,
            // но подпись должна быть осмысленной в любом случае.
            Label((conn as? SSHConnection)?.host ?? "Не подключено", systemImage: "circle.dashed")
                .font(.system(size: D.s(11)))
                .foregroundStyle(Theme.secondary)
        case .failed(let msg):
            Button(action: reconnect) {
                Label("Нет связи", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: D.s(11)))
                    .foregroundStyle(Theme.modified)
            }
            .buttonStyle(.plain)
            .help(msg + "\nНажмите, чтобы переподключиться.")
        }
    }
}

/// Достаёт NSWindow, в котором нарисовано окно проекта.
///
/// Нужно ровно для одного: по клику на уведомлении поднять окно ИМЕННО того проекта, из которого
/// оно пришло. Окон открыто несколько, и «просто вывести приложение вперёд» — это попасть не туда.
/// Изнутри SwiftUI до NSWindow дотянуться больше нечем.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // В момент создания view ещё не в окне — ждём, пока его туда вставят.
        DispatchQueue.main.async { if let w = view.window { onWindow(w) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let w = view.window { onWindow(w) } }
    }
}

/// Перетаскиваемая граница между содержимым окна и терминалом под ним.
///
/// Тянется вверх и вниз, доля запоминается. Границы у доли есть (см. AppSettings): схлопнуть
/// терминал в полоску можно только кнопкой — тогда это осознанное «свернуть», а не случайный
/// промах мышью, после которого не понять, куда делся терминал.
struct TerminalSplitHandle: View {
    @Binding var fraction: Double
    let total: CGFloat

    @State private var startFraction: Double?
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.border).frame(height: 1)
            // Полоска-«ручка» под курсором: показывает, что за границу можно взяться.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(hovering ? Theme.accent : .clear)
                .frame(width: 36, height: 3)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering = $0; if $0 { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() } }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { g in
                    guard total > 0 else { return }
                    let start = startFraction ?? fraction
                    if startFraction == nil { startFraction = start }
                    // Тянем вниз — терминал меньше, вверх — больше. Отсюда минус.
                    let delta = -Double(g.translation.height) / Double(total)
                    let range = AppSettings.terminalFractionRange
                    fraction = min(max(start + delta, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in startFraction = nil }
        )
        .animation(.none, value: fraction)
    }
}

/// Перетаскиваемая граница между боковой панелью и остальным окном. Та же вертикальная черта,
/// что разделяет всё прочее, просто за неё можно потянуть.
struct ColumnHandle: View {
    @Binding var width: Double
    @State private var startWidth: Double?

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.border).frame(width: 1)
            Rectangle().fill(.clear).frame(width: 9).contentShape(Rectangle())
        }
        .frame(width: 9)
        .onHover { NSCursor.resizeLeftRight.set(); if !$0 { NSCursor.arrow.set() } }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { g in
                    let start = startWidth ?? width
                    if startWidth == nil { startWidth = start }
                    width = min(max(start + g.translation.width, 220), 560)
                }
                .onEnded { _ in startWidth = nil }
        )
    }
}

