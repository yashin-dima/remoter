import SwiftUI
import AppKit

/// Настройки приложения (⌘,).
///
/// Всё, что у каждого своё: масштаб, шрифты, звуки, с чем открывать Claude. Раньше половина
/// этого была зашита в код, а вторая половина пряталась в окне запуска сессии — то есть
/// «настройки» приходилось задавать заново при каждом запуске.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        TabView {
            appearance
                .tabItem { Label("Внешний вид", systemImage: "textformat.size") }
            claude
                .tabItem { Label("Claude", systemImage: "sparkle") }
            notifications
                .tabItem { Label("Уведомления", systemImage: "bell") }
        }
        .frame(width: D.s(520), height: D.s(400))
    }

    // MARK: - Внешний вид

    private var appearance: some View {
        Form {
            Section {
                // Подписи считаются из того же scaleRange, что и слайдер: поменяется
                // диапазон — подписи не соврут.
                Slider(value: $settings.scale, in: AppSettings.scaleRange, step: 0.05) {
                    Text("Масштаб интерфейса")
                } minimumValueLabel: {
                    Text("\(Int(AppSettings.scaleRange.lowerBound * 100))%")
                        .font(D.Text.caption).foregroundStyle(Theme.secondary)
                } maximumValueLabel: {
                    Text("\(Int(AppSettings.scaleRange.upperBound * 100))%")
                        .font(D.Text.caption).foregroundStyle(Theme.secondary)
                }

                LabeledContent("Сейчас") {
                    HStack(spacing: 10) {
                        Text("\(Int(settings.scale * 100))%")
                            .font(D.Text.bodyMedium)
                            .monospacedDigit()
                        Button("Сбросить") { settings.scale = 1 }
                            .disabled(settings.scale == 1)
                    }
                }
            } header: {
                Text("Размер интерфейса")
            } footer: {
                Text("Меняются и шрифты, и высота строк, и зоны нажатия — целиком, а не только текст.")
                    .font(D.Text.caption)
                    .foregroundStyle(Theme.secondary)
            }

            Section("Шрифты") {
                Stepper(value: $settings.terminalFontSize, in: 9...24, step: 1) {
                    LabeledContent("Терминал") {
                        Text("\(Int(settings.terminalFontSize)) pt").monospacedDigit()
                    }
                }
                Stepper(value: $settings.editorFontSize, in: 9...24, step: 1) {
                    LabeledContent("Редактор кода") {
                        Text("\(Int(settings.editorFontSize)) pt").monospacedDigit()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Claude

    private var claude: some View {
        Form {
            Section {
                Picker("Модель", selection: $settings.model) {
                    ForEach(ClaudeModel.allCases) { Text($0.menuTitle).tag($0) }
                }
                Picker("Уровень reasoning", selection: $settings.effort) {
                    ForEach(ClaudeEffort.allCases) { Text($0.menuTitle).tag($0) }
                }
                Picker("Режим работы", selection: $settings.permissions) {
                    ForEach(ClaudePermissions.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("С чем открывать новую сессию")
            } footer: {
                Text("«Как в Claude» — не подставлять флаг вовсе: он возьмёт своё, из "
                     + "~/.claude/settings.json. Так и надо: это его настройки, а не наши. "
                     + "Выберите модель явно, только если хотите перекрыть их для этого проекта.")
                    .font(D.Text.caption)
                    .foregroundStyle(Theme.secondary)
            }

            Section {
                Toggle("Контекст 1M токенов", isOn: $settings.longContext)
                    .disabled(!settings.model.supportsLongContext)
                Toggle("Продолжать последний разговор при открытии проекта",
                       isOn: $settings.resumeLastSession)
            } footer: {
                Text(longContextNote)
                    .font(D.Text.caption)
                    .foregroundStyle(Theme.secondary)
            }

            Section("Редактор") {
                Toggle("Предпросмотр файла по одиночному клику", isOn: $settings.previewTabs)
            }
        }
        .formStyle(.grouped)
    }

    /// Что означает переключатель именно сейчас — со всеми частными случаями, а не общими словами.
    private var longContextNote: String {
        switch settings.model {
        case .inherit:
            let model = ClaudeConfig.model ?? "не задана"
            return "Модель берётся из настроек Claude (сейчас `\(model)`) — окно задано там же, "
                 + "переключать здесь нечего."
        case .haiku:
            return "Haiku длинного контекста не поддерживает — настройка на неё не влияет."
        default:
            let alias = settings.model.alias(longContext: settings.longContext) ?? ""
            return "В команду уйдёт `--model '\(alias)'`. Без [1m] окно — обычные 200k."
        }
    }

    // MARK: - Уведомления

    private var notifications: some View {
        Form {
            Section {
                SoundPicker(title: "Claude закончил работу", sound: $settings.soundDone)
                SoundPicker(title: "Claude о чём-то спрашивает", sound: $settings.soundAsk)
            } header: {
                Text("Звук уведомления")
            } footer: {
                Text("Разные звуки стоит поставить не для красоты: «он ждёт меня» слышно, "
                     + "не отрываясь от другого окна.")
                    .font(D.Text.caption)
                    .foregroundStyle(Theme.secondary)
            }

            Section {
                Button("Открыть настройки уведомлений macOS") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
                    NSWorkspace.shared.open(url)
                }
            } footer: {
                Text("Если уведомления не приходят вовсе — дело не в звуке, а в разрешении системы.")
                    .font(D.Text.caption)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Выбор звука: системные, свой файл, тишина. С кнопкой «послушать» — выбирать звук по названию
/// в списке бессмысленно, его надо слышать.
private struct SoundPicker: View {
    let title: String
    @Binding var sound: NotificationSound

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Picker("", selection: selection) {
                    Text("Без звука").tag(NotificationSound.silent)

                    Divider()

                    ForEach(NotificationSound.systemSounds, id: \.self) { name in
                        Text(name).tag(NotificationSound.system(name))
                    }

                    // Свой файл виден в списке только когда он выбран — иначе его нечем показать.
                    if case .custom(let name) = sound {
                        Divider()
                        Text((name as NSString).deletingPathExtension).tag(sound)
                    }

                    Divider()
                    Text("Выбрать файл…").tag(NotificationSound.custom(pickMarker))
                }
                .labelsHidden()
                .frame(width: 160)

                Button {
                    sound.play()
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
                .help("Послушать")
            }
        }
    }

    /// Псевдо-звук «выбрать файл…»: выбор в меню — это команда, а не значение.
    private let pickMarker = "…"

    private var selection: Binding<NotificationSound> {
        Binding(
            get: { sound },
            set: { new in
                guard new == .custom(pickMarker) else {
                    sound = new
                    new.play()
                    return
                }
                pickFile()
            }
        )
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Выбрать"
        panel.message = "Звук скопируется в ~/Library/Sounds — иначе macOS его не найдёт."

        let apply: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            guard let adopted = NotificationSound.adopt(url) else {
                NSSound.beep()
                return
            }
            sound = adopted
            adopted.play()
        }

        // Шитом к окну настроек, а не runModal: модальный диалог на всё приложение
        // замораживал бы и окна проектов.
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(panel.runModal())
        }
    }
}
