import SwiftUI
import AppKit

/// Модели, которые понимает `claude --model`. Алиасы, а не полные id: они короче и не протухают
/// при смене даты в id.
enum ClaudeModel: String, CaseIterable, Identifiable {
    /// Не указывать модель вовсе — пусть Claude возьмёт свою, из `~/.claude/settings.json`.
    ///
    /// Это значение по умолчанию, и это принципиально. Приложение не имеет права решать за Claude:
    /// у вас в его настройках стоит `opus[1m]`, а мы подставляли `--model opus` — и флаг молча
    /// перекрывал настройку, обрезая контекст с миллиона до двухсот тысяч.
    case inherit
    /// Порядок — от самой слабой к самой сильной, как у effort: список читается как шкала,
    /// а не как случайный набор. Меню и пикеры берут порядок отсюда (CaseIterable).
    case haiku, sonnet, opus, fable

    var id: String { rawValue }

    /// Имена с версиями живут в ClaudeConfig.modelTitle — в ОДНОМ месте, а не россыпью по UI:
    /// алиасы указывают на текущее поколение, и с его сменой версии протухают.
    var title: String {
        guard self != .inherit else { return "Как в Claude" }
        return ClaudeConfig.modelTitle(alias: rawValue) ?? ClaudeJournal.modelName(fromID: rawValue)
    }

    /// Что показать в списке: у «как в Claude» видно, что именно оттуда приедет.
    var menuTitle: String {
        guard self == .inherit, let model = ClaudeConfig.model else { return title }
        return "\(title) — \(model)"
    }

    /// Миллион токенов контекста вместо обычных 200k. У Haiku такого варианта нет.
    /// У «как в Claude» переключать нечего: окно задано его же настройками.
    var supportsLongContext: Bool { self != .haiku && self != .inherit }

    /// Алиас для `--model`: `opus` или `opus[1m]`. nil — флага не будет вовсе.
    func alias(longContext: Bool) -> String? {
        guard self != .inherit else { return nil }
        return longContext && supportsLongContext ? rawValue + ClaudeConfig.longContextSuffix : rawValue
    }
}

/// `claude --effort` — уровень reasoning.
enum ClaudeEffort: String, CaseIterable, Identifiable {
    /// Не указывать — у Claude есть свой (`effortLevel` в его настройках, его ставит `/effort`).
    case inherit
    case low, medium, high, xhigh, max
    /// Максимум с оркестрацией: Claude раскладывает работу по подагентам и проверяет сам себя.
    case ultracode

    var id: String { rawValue }

    var title: String {
        self == .inherit ? "Как в Claude" : rawValue
    }

    var menuTitle: String {
        guard self == .inherit, let effort = ClaudeConfig.effort else { return title }
        return "\(title) — \(effort)"
    }

    /// Значение для `--effort`. nil — флага не будет.
    var flag: String? { self == .inherit ? nil : rawValue }
}

/// Режим работы Claude (`--permission-mode`, он же shift+tab внутри сессии).
enum ClaudePermissions: String, CaseIterable, Identifiable {
    case `default`, acceptEdits, plan, bypassPermissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .default:           return "Спрашивать"
        case .acceptEdits:       return "Правки без спроса"
        case .plan:              return "Только план"
        case .bypassPermissions: return "Полный доступ"
        }
    }

    var icon: String {
        switch self {
        case .default:           return "hand.raised"
        case .acceptEdits:       return "checkmark.circle"
        case .plan:              return "list.bullet.rectangle"
        case .bypassPermissions: return "bolt.fill"
        }
    }

    /// Порядок, в котором режимы перебирает shift+tab. Слэш-команды для смены режима у Claude
    /// Code нет — есть только этот круг, и чтобы попасть в нужный режим, надо знать, сколько
    /// шагов до него от текущего.
    static let cycle: [ClaudePermissions] = [.default, .acceptEdits, .plan, .bypassPermissions]
}

/// Плашка над терминалом: что у ЭТОЙ сессии происходит на самом деле — и чем этим управлять.
///
/// Показывается не то, с чем сессию запустили, а то, что Claude пишет в свой журнал: набрали
/// внутри `/effort xhigh` — плашка через полторы секунды скажет xhigh.
///
/// И наоборот: клик по плашке не меняет ничего «внутри приложения» — он отправляет в терминал
/// ту же команду, которую вы набрали бы руками (`/model opus`, `/effort high`, shift+tab для
/// режима). Она видна в терминале, её можно прервать, а плашка переключится, только когда смена
/// реально произойдёт. Так не бывает состояния «в приложении одно, у Claude другое».
struct ClaudeBar: View {
    @ObservedObject var model: WorkspaceModel
    let tab: ClaudeTab

    var body: some View {
        HStack(spacing: D.s(8)) {
            ContextRing(tab: tab)
            usageButton

            modelChip
            effortChip
            permissionsChip

            if tab.resumed != nil {
                chip("продолжена", icon: "clock.arrow.circlepath")
            }

            Spacer()

            if !model.claudeInstalled {
                Label("claude не найден на Mac", systemImage: "exclamationmark.triangle.fill")
                    .font(D.Text.caption)
                    .foregroundStyle(Theme.modified)
                    .help("Установите Claude Code локально — на сервер его ставить не нужно.")
            }

            if tab.live.attachments > 0 { attachmentsButton }
            remoteControlButton
            if tab.isBusy { stopButton }
            attachButton
        }
        .padding(.horizontal, D.Pad.bar)
        .frame(height: D.s(36))
        .background(Theme.bg)
        // Изменение видно: набрали `/effort xhigh` — плашка мягко переехала на xhigh, а не
        // подменилась незаметно.
        .animation(.easeOut(duration: 0.2), value: tab.live)
        .animation(.easeOut(duration: 0.2), value: tab.isBusy)
        .animation(.easeOut(duration: 0.2), value: tab.remoteControl)
    }

    /// Разбивка по лимитам — рядом с кольцом контекста, потому что об одном и том же: сколько
    /// израсходовано. `/usage` открывает её прямо в терминале Claude.
    private var usageButton: some View {
        Button {
            model.showUsage(tab)
        } label: {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: D.s(11), weight: .medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: D.s(22), height: D.s(22))
                .background(Theme.hover, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Показать расход лимитов (/usage) — откроется в терминале сессии.")
    }

    /// Картинки, которые есть в разговоре. Терминал их показать не может — бросили Claude
    /// скриншот, и он для вас исчез, остался «[Image #1]». Здесь их видно.
    private var attachmentsButton: some View {
        Button {
            model.showAttachments(tab)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: D.s(11), weight: .medium))
                Text("\(tab.live.attachments)")
                    .font(.system(size: D.s(12), weight: .medium))
            }
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 10)
            .frame(height: D.s(26))
            .background(Theme.hover, in: RoundedRectangle(cornerRadius: D.Size.radius))
            .contentShape(RoundedRectangle(cornerRadius: D.Size.radius))
        }
        .buttonStyle(.plain)
        .help("Картинки в этом разговоре — терминал их показать не может, а посмотреть иногда нужно.")
    }

    /// Управление сессией с телефона и push-уведомления через приложение Claude. Подсвечена,
    /// когда режим включён; клик шлёт `/remote-control`, как если бы команду набрали руками.
    private var remoteControlButton: some View {
        Button {
            model.toggleRemoteControl(tab)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: D.s(11), weight: .medium))
                Text("Телефон")
                    .font(.system(size: D.s(12), weight: .medium))
            }
            .foregroundStyle(tab.remoteControl ? Theme.accent : Theme.secondary)
            .padding(.horizontal, 10)
            .frame(height: D.s(26))
            .background(
                tab.remoteControl ? Theme.accent.opacity(0.14) : Theme.hover,
                in: RoundedRectangle(cornerRadius: D.Size.radius)
            )
            .contentShape(RoundedRectangle(cornerRadius: D.Size.radius))
        }
        .buttonStyle(.plain)
        .help(tab.remoteControl
              ? "Remote-control включён: сессией можно управлять с телефона, а приложение Claude "
                + "шлёт push, когда сессия закончила или ждёт ответа. Нажмите, чтобы выключить."
              : "Включить remote-control: управление сессией с телефона и push-уведомления через "
                + "приложение Claude (нужен вход в тот же аккаунт на телефоне).")
    }

    // MARK: - Параметры

    private var modelChip: some View {
        Menu {
            // «Как в Claude» здесь нет: работающей сессии нельзя сказать «возьми своё по
            // умолчанию» — `/model` требует конкретную модель. Это выбор ДО запуска.
            ForEach(ClaudeModel.allCases.filter { $0 != .inherit }) { m in
                Button {
                    model.switchModel(tab, to: m)
                } label: {
                    // Галочка — через if: пустое имя SF Symbol невалидно и сыпет
                    // предупреждениями в консоль на каждую отрисовку меню.
                    if m.title == tab.shownModel {
                        Label(m.title, systemImage: "checkmark")
                    } else {
                        Text(m.title)
                    }
                }
            }
        } label: {
            chip(tab.shownModel, trailing: true)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Модель. Выбор уходит в терминал командой /model — как если бы вы набрали её сами.")
    }

    private var effortChip: some View {
        Menu {
            ForEach(ClaudeEffort.allCases.filter { $0 != .inherit }) { e in
                Button {
                    model.switchEffort(tab, to: e)
                } label: {
                    if e == tab.shownEffort {
                        Label(e.title, systemImage: "checkmark")
                    } else {
                        Text(e.title)
                    }
                }
            }
        } label: {
            chip("effort " + tab.shownEffort.title, trailing: true)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Уровень reasoning. Выбор уходит в терминал командой /effort.")
    }

    private var permissionsChip: some View {
        Menu {
            ForEach(ClaudePermissions.allCases) { p in
                Button {
                    model.switchPermissions(tab, to: p)
                } label: {
                    Label(p.title, systemImage: p == tab.shownPermissions ? "checkmark" : p.icon)
                }
            }
        } label: {
            chip(tab.shownPermissions.title, icon: tab.shownPermissions.icon, trailing: true)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Режим работы. Слэш-команды для него нет — уйдёт столько shift+tab, "
              + "сколько шагов до нужного режима.")
    }

    /// Остановить то, что Claude делает прямо сейчас. Сессия при этом жива: это Escape,
    /// а не Ctrl+C — тот, нажатый дважды, из Claude выходит.
    private var stopButton: some View {
        Button {
            model.stopSession(tab)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "stop.fill")
                    .font(.system(size: D.s(10), weight: .bold))
                Text("Стоп")
                    .font(.system(size: D.s(12), weight: .medium))
            }
            .foregroundStyle(Theme.removed)
            .padding(.horizontal, D.s(10))
            .frame(height: D.s(26))
            .background(Theme.removed.opacity(0.12), in: RoundedRectangle(cornerRadius: D.Size.radius))
            .contentShape(RoundedRectangle(cornerRadius: D.Size.radius))
        }
        .buttonStyle(.plain)
        .transition(.opacity)
        .help("Прервать работу Claude (Escape). Разговор останется — прервётся только текущий ответ.")
    }

    private func chip(_ text: String, icon: String? = nil, trailing: Bool = false) -> some View {
        HStack(spacing: D.s(4)) {
            if let icon {
                Image(systemName: icon).font(.system(size: D.s(9)))
            }
            Text(text)
                .font(.system(size: D.s(11), weight: .medium))
            if trailing {
                Image(systemName: "chevron.down")
                    .font(.system(size: D.s(7), weight: .bold))
                    .opacity(0.6)
            }
        }
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, D.s(8))
        .padding(.vertical, D.s(3))
        .background(Theme.hover, in: Capsule())
        .contentShape(Capsule())
    }

    /// Прикрепить файл к запросу. Claude читает картинки и файлы по пути — путь и подставляем.
    /// То же самое делает перетаскивание файла прямо в окно терминала и ⌘V со скриншотом.
    private var attachButton: some View {
        Button {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.prompt = "Прикрепить"
            // Шитом к СВОЕМУ окну, а не runModal: модальный диалог на всё приложение
            // замораживал бы и соседние окна проектов.
            if let window = model.window {
                panel.beginSheetModal(for: window) { response in
                    guard response == .OK else { return }
                    model.attach(panel.urls)
                }
            } else {
                guard panel.runModal() == .OK else { return }
                model.attach(panel.urls)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "paperclip")
                    .font(.system(size: D.s(11), weight: .medium))
                Text("Файл")
                    .font(.system(size: D.s(12), weight: .medium))
            }
            .padding(.horizontal, 10)
            .frame(height: D.s(26))
            .background(Theme.hover, in: RoundedRectangle(cornerRadius: D.Size.radius))
            .contentShape(RoundedRectangle(cornerRadius: D.Size.radius))
        }
        .buttonStyle(.plain)
        .help("Подставить путь к файлу в запрос. То же — перетаскиванием в окно или ⌘V со скриншотом.")
    }
}

/// Кольцо заполненности контекста.
///
/// Контекст кончается внезапно и всегда некстати: Claude уходит на авто-сжатие посреди задачи
/// и теряет половину того, что вы ему объясняли. Видя, что окно подходит к концу, можно сжать
/// его самому (`/compact`) — в удобный момент, а не в случайный.
///
/// Считается по последнему ответу Claude: его вход (вместе с прочитанным из кэша — в окне оно
/// занимает место наравне с остальным) плюс выход.
struct ContextRing: View {
    let tab: ClaudeTab

    private var fill: Double { tab.contextFill ?? 0 }

    /// Красным — не «много», а «пора»: около 90% Claude сжимает контекст сам.
    private var color: Color {
        switch fill {
        case ..<0.6:  return Theme.added
        case ..<0.85: return Theme.modified
        default:      return Theme.removed
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.hover, lineWidth: D.s(3))

            Circle()
                .trim(from: 0, to: fill)
                .stroke(color, style: StrokeStyle(lineWidth: D.s(3), lineCap: .round))
                // С двенадцати часов, по часовой — иначе заполнение читается как обратный отсчёт.
                .rotationEffect(.degrees(-90))

            // Процент внутри кольца не пишем: в 18 точках он превратится в грязь. Число — в подсказке.
            if fill >= 0.85 {
                Circle()
                    .fill(color)
                    .frame(width: D.s(4), height: D.s(4))
            }
        }
        .frame(width: D.s(18), height: D.s(18))
        .opacity(tab.contextFill == nil ? 0.35 : 1)
        .animation(.easeOut(duration: 0.4), value: fill)
        .help(helpText)
    }

    private var helpText: String {
        guard let used = tab.live.contextTokens else {
            return "Контекст: Claude ещё не отвечал — считать нечего"
        }
        let percent = Int((fill * 100).rounded())
        let window = tab.contextWindow == 1_000_000 ? "1M" : "\(tab.contextWindow / 1000)k"
        let hint = fill >= 0.85
            ? "\nПора сжимать: наберите /compact, пока Claude не сделал это сам посреди задачи."
            : ""
        return "Контекст занят на \(percent)% — \(thousands(used)) из \(window) токенов." + hint
    }

    private func thousands(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }
}

/// Окно запуска новой сессии: с чем её открыть.
///
/// Спрашиваем ДО запуска, а не после: поменять модель у уже работающего Claude нельзя.
struct NewSessionView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.system(size: D.s(16), weight: .medium))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Новая сессия")
                        .font(.system(size: D.s(15), weight: .semibold))
                    Text("Откроется рядом с текущей, не прерывая её")
                        .font(D.Text.caption)
                        .foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Form {
                Picker("Модель", selection: $model.claudeModel) {
                    ForEach(ClaudeModel.allCases) { Text($0.menuTitle).tag($0) }
                }
                Picker("Уровень reasoning", selection: $model.claudeEffort) {
                    ForEach(ClaudeEffort.allCases) { Text($0.menuTitle).tag($0) }
                }
                Picker("Режим работы", selection: $model.claudePermissions) {
                    ForEach(ClaudePermissions.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Контекст 1M токенов", isOn: $model.claudeLongContext)
                    .disabled(!model.claudeModel.supportsLongContext)
                    .help(model.claudeModel == .inherit
                          ? "Модель берётся из настроек Claude — окно задано там же"
                          : (model.claudeModel.supportsLongContext
                             ? "Без этого Claude получит обычные 200k"
                             : "\(model.claudeModel.title) длинный контекст не поддерживает"))
            }
            .formStyle(.grouped)

            // Команда видна целиком: никакой магии, в терминал уйдёт ровно это.
            Text(model.claudeCommand)
                .font(D.Text.mono)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.horizontal, 20)

            Spacer(minLength: 12)

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                Button("Открыть") {
                    model.openSession()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.claudeInstalled || model.localPath.isEmpty)
            }
            .padding(20)
        }
        .frame(width: D.s(480), height: D.s(380))
    }
}
