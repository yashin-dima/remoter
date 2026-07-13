import SwiftUI
import AppKit

@main
struct RemoterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = WorkspaceStore()
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        Window("Проекты", id: "launcher") {
            LauncherView()
                .environmentObject(store)
                .environmentObject(settings)
                .tint(Theme.accent)
                // Масштаб меняет размеры, посчитанные внутри D — а они статические, и сами по себе
                // перерисовку не вызывают. Смена id перестраивает окно целиком: терминалов здесь
                // нет, поэтому терять нечего.
                .id(settings.scale)
        }
        .defaultSize(width: 640, height: 480)
        .windowResizability(.contentSize)

        // WindowGroup по значению: каждый проект открывается в своём окне со своей моделью,
        // своим ssh-каналом и своим терминалом — то есть со своей сессией Claude. Открыть
        // один и тот же проект дважды нельзя: окно с этим id просто выйдет на передний план.
        WindowGroup(id: "workspace", for: UUID.self) { $id in
            WorkspaceHostView(workspaceID: id)
                .environmentObject(store)
                .environmentObject(settings)
                // Один акцент на всё приложение: системный синий рядом с оранжевым Claude
                // выглядел как две разные программы в одном окне.
                .tint(Theme.accent)
        }
        .defaultSize(width: 1500, height: 980)
        .commands { WorkspaceCommands() }

        // Без .id(settings.scale): слайдер масштаба пишет в scale на каждом шаге перетаскивания,
        // и смена id пересоздавала бы сам слайдер посреди жеста — он обрывался после первого
        // шага. Размеры в окне настроек обновятся при следующем его открытии; это честная цена
        // за работающий слайдер.
        Settings {
            SettingsView(settings: settings)
                .tint(Theme.accent)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ note: Notification) {
        if SelfCheck.isRequested { SelfCheck.run() }
        MainActor.assumeIsolated { Notifications.setUp() }
    }

    /// Список проектов открывается только по кнопке «+» (и ⇧⌘O) — больше ниоткуда.
    /// Клик по иконке в Dock, когда все окна закрыты, — единственное исключение: показать нечего.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !flag
    }

    /// Иначе после выхода на машине остаются висеть фоновые ssh-сессии к серверам.
    func applicationWillTerminate(_ note: Notification) {
        MainActor.assumeIsolated { SSHConnection.disconnectAll() }
    }
}

/// Модель окна, на котором сейчас фокус — через неё пункты меню находят «свой» воркспейс.
private struct WorkspaceModelKey: FocusedValueKey {
    typealias Value = WorkspaceModel
}

extension FocusedValues {
    var workspaceModel: WorkspaceModel? {
        get { self[WorkspaceModelKey.self] }
        set { self[WorkspaceModelKey.self] = newValue }
    }
}

struct WorkspaceCommands: Commands {
    @FocusedValue(\.workspaceModel) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Список проектов закрывается, как только проект открыт, — поэтому нужен способ позвать
        // его обратно, когда захочется открыть рядом ещё один.
        CommandGroup(replacing: .newItem) {
            Button("Проекты…") { openWindow(id: "launcher") }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .saveItem) {
            Button("Сохранить") { model?.requestSave() }
                .keyboardShortcut("s")
                .disabled(model?.doc?.isDirty != true)
        }

        CommandGroup(after: .toolbar) {
            Button("Обновить") {
                if let model { Task { await model.refresh(force: true) } }
            }
            .keyboardShortcut("r")
            .disabled(model == nil)

            Button("Быстрый переход к файлу…") { model?.isQuickOpenPresented = true }
                .keyboardShortcut("p")
                .disabled(model == nil)

            Divider()

            Button((model?.sideBySide ?? true) ? "Diff в одну колонку" : "Diff в две колонки") {
                model?.sideBySide.toggle()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(model?.doc?.mode != .diff)

            Button("Новая сессия Claude") { model?.isNewSessionPresented = true }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(model == nil)

            // Терминал — панель под окном, а не вкладка: пункт её сворачивает и разворачивает.
            Button(model?.isTerminalPanelOpen == true ? "Свернуть терминал" : "Показать терминал") {
                model?.toggleTerminalPanel()
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(model == nil)

            Button("Сессии Claude…") { model?.isSessionsPresented = true }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                .disabled(model == nil)
        }
    }
}
