import XCTest
@testable import Remoter

/// Настройки приложения.
@MainActor
final class SettingsTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        // Своя полка настроек: трогать настоящие — значит переписать пользователю масштаб
        // и звуки прямо во время прогона тестов.
        defaults = UserDefaults(suiteName: "remoter-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaults.description)
    }

    /// Ползунок масштаба ронял приложение.
    ///
    /// Причина была не в UI: значение подрезалось внутри `didSet` — присваиванием тому же
    /// свойству. У `@Published` свойство вычисляемое (это обёртка), поэтому присваивание снова
    /// звало сеттер, тот снова `didSet`, и так до переполнения стека. Тест ровно об этом:
    /// если он не падает и не виснет, рекурсии нет.
    func testChangingScaleDoesNotRecurseIntoItself() {
        let settings = AppSettings(defaults: defaults)

        settings.scale = 1.3
        XCTAssertEqual(settings.scale, 1.3)
        XCTAssertEqual(D.scale, 1.3, "масштаб не доехал до размеров интерфейса")

        // Много раз подряд — как при перетаскивании ползунка.
        for step in stride(from: 0.8, through: 1.6, by: 0.05) {
            settings.scale = step
        }
        XCTAssertEqual(settings.scale, 1.6, accuracy: 0.001)

        settings.scale = 1
        XCTAssertEqual(D.scale, 1)
    }

    /// Масштаб переживает перезапуск — иначе настройка бессмысленна.
    func testScaleSurvivesRestart() {
        let first = AppSettings(defaults: defaults)
        first.scale = 1.25

        let second = AppSettings(defaults: defaults)
        XCTAssertEqual(second.scale, 1.25)
    }

    /// В файле настроек могло оказаться что угодно (правка руками, старая версия). Интерфейс
    /// в масштабе 500% — это окно, которым нельзя пользоваться и в котором нельзя это исправить.
    func testAbsurdSavedScaleIsBroughtBackIntoRange() {
        defaults.set(12.0, forKey: "ui.scale")
        XCTAssertEqual(AppSettings(defaults: defaults).scale, 1.6)

        defaults.set(0.01, forKey: "ui.scale")
        XCTAssertEqual(AppSettings(defaults: defaults).scale, 0.8)
    }

    /// По умолчанию приложение не навязывает Claude ни модель, ни effort: у него они свои.
    func testByDefaultWeDoNotOverrideClaudesOwnModelAndEffort() {
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.model, .inherit)
        XCTAssertEqual(settings.effort, .inherit)
        XCTAssertNil(settings.model.alias(longContext: true), "модель всё-таки навязана")
        XCTAssertNil(settings.effort.flag, "effort всё-таки навязан")
    }

    /// Звук уведомления: свой файл лежит в ~/Library/Sounds — только там macOS его и ищет.
    func testCustomSoundIsAddressedByFileName() {
        XCTAssertEqual(NotificationSound.system("Glass").fileName, "Glass.aiff")
        XCTAssertEqual(NotificationSound.custom("свой.wav").fileName, "свой.wav")
        XCTAssertNil(NotificationSound.silent.fileName, "тишина всё-таки со звуком")

        // Запись и чтение из настроек не должны терять, какой это был звук.
        for sound: NotificationSound in [.silent, .system("Ping"), .custom("мой звук.aiff")] {
            XCTAssertEqual(NotificationSound(rawValue: sound.rawValue), sound)
        }
    }
}
