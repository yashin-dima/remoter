import XCTest
@testable import Remoter

/// Управление работающей сессией из плашки: смена модели/effort/режима, /usage, remote-control
/// и переименование вкладки.
///
/// Главное свойство — плашка реагирует на действие СРАЗУ. Интерактивную смену effort Claude
/// в журнал не пишет вовсе, так что дождаться подтверждения оттуда нельзя: единственный источник
/// для плашки — наш оптимистичный снимок. Плюс проверяем, что в терминал уходит ровно та команда,
/// которую набрали бы руками.
@MainActor
final class ClaudeControlsTests: XCTestCase {

    private func model() -> WorkspaceModel {
        WorkspaceModel(workspace: Workspace(name: "п", host: "h", path: "/srv/п"))
    }

    private func tab() -> ClaudeTab {
        ClaudeTab(id: UUID(), title: "", model: .inherit, effort: .inherit,
                  permissions: .default, longContext: false, resumed: nil)
    }

    /// Сменили effort — плашка показывает новый уровень немедленно, не дожидаясь журнала
    /// (которого для интерактивной смены и не будет).
    func testSwitchingEffortUpdatesChipImmediately() {
        let model = model()
        let tab = tab()
        model.claudeTabs.append(tab)

        model.switchEffort(tab, to: .xhigh)

        XCTAssertEqual(model.claudeTabs[0].live.effort, .xhigh, "плашка effort не отреагировала сразу")
        XCTAssertEqual(model.terminal.pendingCommand(for: tab.terminal), "/effort xhigh",
                       "в терминал ушла не та команда")
    }

    /// Сменили модель — и плашка, и команда согласованы. С длинным контекстом алиас несёт `[1m]`,
    /// и он едет в Claude как есть: это ввод в него, а не в шелл.
    func testSwitchingModelUpdatesChipAndSendsCommand() {
        let model = model()
        let tab = ClaudeTab(id: UUID(), title: "", model: .inherit, effort: .inherit,
                            permissions: .default, longContext: true, resumed: nil)
        model.claudeTabs.append(tab)

        model.switchModel(tab, to: .opus)

        XCTAssertEqual(model.claudeTabs[0].live.modelAlias, "opus[1m]")
        XCTAssertEqual(model.claudeTabs[0].shownModel, ClaudeModel.opus.title)
        XCTAssertEqual(model.terminal.pendingCommand(for: tab.terminal), "/model opus[1m]")
    }

    func testSwitchingPermissionsUpdatesChipImmediately() {
        let model = model()
        let tab = tab()   // стартует в .default
        model.claudeTabs.append(tab)

        model.switchPermissions(tab, to: .plan)

        XCTAssertEqual(model.claudeTabs[0].shownPermissions, .plan)
    }

    /// /usage открывает разбивку по лимитам прямо в терминале — наружу Claude её не отдаёт.
    func testUsageSendsSlashCommand() {
        let model = model()
        let tab = tab()
        model.claudeTabs.append(tab)

        model.showUsage(tab)

        XCTAssertEqual(model.terminal.pendingCommand(for: tab.terminal), "/usage")
    }

    /// Remote-control — переключатель: клик шлёт `/remote-control` и инвертирует наш флаг
    /// (надёжно прочитать его из журнала нельзя).
    func testRemoteControlToggles() {
        let model = model()
        let tab = tab()
        model.claudeTabs.append(tab)
        let before = model.claudeTabs[0].remoteControl

        model.toggleRemoteControl(tab)

        XCTAssertEqual(model.claudeTabs[0].remoteControl, !before, "флаг remote-control не переключился")
        XCTAssertEqual(model.terminal.pendingCommand(for: tab.terminal), "/remote-control")
    }

    /// Заданное человеком имя приоритетнее автоматического заголовка вкладки.
    func testCustomTitleWinsOverAutoTitle() {
        var tab = tab()
        tab.title = "Придумано Claude"
        XCTAssertEqual(tab.shownTitle, "Придумано Claude")

        tab.customTitle = "Моё имя"
        XCTAssertEqual(tab.shownTitle, "Моё имя")
    }

    /// Пустое имя возвращает вкладку к автоматическому заголовку.
    func testRenamingWithBlankNameClearsCustomTitle() {
        let model = model()
        var tab = tab()
        tab.title = "Новая сессия"
        model.claudeTabs.append(tab)

        model.renameTab(tab.id, to: "Починить деплой")
        XCTAssertEqual(model.claudeTabs[0].customTitle, "Починить деплой")

        model.renameTab(tab.id, to: "   ")
        XCTAssertNil(model.claudeTabs[0].customTitle, "пустое имя должно снимать кастомный заголовок")
        XCTAssertEqual(model.claudeTabs[0].shownTitle, "Новая сессия")
    }
}
