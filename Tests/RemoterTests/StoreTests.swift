import XCTest
@testable import Remoter

/// Список проектов — единственное, что приложение хранит на диске. Потерять его нельзя:
/// это адреса серверов, пути и настройки доступа, набранные руками.
///
/// Проекты уже пропадали (файл со списком стёрли при уборке после отладки), поэтому здесь
/// проверяется не только «сохраняется и читается», но и то, что список переживает беду:
/// битый файл, стёртый файл, вторую копию приложения рядом.
@MainActor
final class StoreTests: XCTestCase {

    private var dir: URL!
    private var file: URL { dir.appendingPathComponent("workspaces.json") }
    private var backup: URL { dir.appendingPathComponent("workspaces.backup.json") }

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("remoter-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func sample(_ name: String) -> Workspace {
        Workspace(name: name, host: "user@example.com", path: "/srv/" + name)
    }

    /// Базовое: добавили — и после перезапуска приложения проект на месте.
    func testProjectSurvivesRestart() throws {
        let first = WorkspaceStore(fileURL: file)
        first.add(sample("Acme"))

        let afterRestart = WorkspaceStore(fileURL: file)
        XCTAssertEqual(afterRestart.workspaces.map(\.name), ["Acme"])
        XCTAssertEqual(afterRestart.workspaces.first?.path, "/srv/Acme")
    }

    /// Настоящий список живёт в Application Support, и тест не должен доставать до него ни при
    /// каких условиях — иначе уборка за тестом уносит проекты. Ровно так однажды и случилось.
    ///
    /// Раньше защита держалась на дисциплине: задал `REMOTER_STORE` — цел, забыл — прогон пошёл
    /// работать с настоящим списком. Забыть оказалось легко: достаточно набрать `swift test`
    /// вместо длинной команды из local-sshd.sh, и тесты насыпали два десятка папок с именами
    /// фикстур прямо в живой каталог проектов. Поэтому теперь путь уводится в песочницу САМ,
    /// как только процесс опознан как тестовый, — забывчивость больше не стоит данных.
    func testStorePathNeverPointsAtRealProjectsUnderTests() {
        let real = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Remoter/workspaces.json")

        setenv("REMOTER_STORE", file.path, 1)
        XCTAssertEqual(WorkspaceStore.defaultURL().path, file.path, "переменную не уважили")
        XCTAssertNotEqual(WorkspaceStore.defaultURL().path, real.path)

        // И даже без переменной — не настоящий список, а песочница этого процесса.
        unsetenv("REMOTER_STORE")
        XCTAssertNotEqual(WorkspaceStore.defaultURL().path, real.path,
                          "тест без REMOTER_STORE дотянулся до настоящих проектов")
        XCTAssertTrue(TestIsolation.isRunningTests, "тестовый процесс не опознан — песочницы не будет")
    }

    /// Файл со списком испортился (обрыв записи, кривая правка руками). Пустой список здесь —
    /// худший исход: он молча уехал бы на диск при первом же сохранении и добил бы остатки.
    /// Поэтому список поднимается из резервной копии.
    func testCorruptedFileIsRecoveredFromBackup() throws {
        let store = WorkspaceStore(fileURL: file)
        store.add(sample("Первый"))
        store.add(sample("Второй"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "резервной копии нет")

        try Data("{это не json".utf8).write(to: file)

        let recovered = WorkspaceStore(fileURL: file)
        // Копия не отстаёт: возвращаются оба проекта, включая добавленный последним.
        XCTAssertEqual(recovered.workspaces.map(\.name), ["Первый", "Второй"],
                       "битый файл обнулил или урезал список проектов")

        // Основной файл при этом восстановлен: следующий запуск уже не будет спасательным.
        let reread = WorkspaceStore(fileURL: file)
        XCTAssertEqual(reread.workspaces.map(\.name), ["Первый", "Второй"])
    }

    /// Файл со списком просто исчез. То же самое: поднимаемся из копии, а не начинаем с нуля.
    func testDeletedFileIsRecoveredFromBackup() throws {
        let store = WorkspaceStore(fileURL: file)
        store.add(sample("Первый"))
        store.add(sample("Второй"))

        try FileManager.default.removeItem(at: file)

        let recovered = WorkspaceStore(fileURL: file)
        XCTAssertEqual(recovered.workspaces.count, 2, "после удаления файла проекты не вернулись")
    }

    /// Два окна приложения (или две копии) видят один файл. Второе не должно затирать своим
    /// устаревшим списком то, что добавило первое.
    func testSecondInstanceDoesNotClobberFirst() {
        let a = WorkspaceStore(fileURL: file)
        let b = WorkspaceStore(fileURL: file)   // открылось раньше, чем «a» что-либо добавил

        a.add(sample("Добавлен в первом окне"))
        b.add(sample("Добавлен во втором окне"))

        let final = WorkspaceStore(fileURL: file)
        XCTAssertEqual(final.workspaces.count, 2, "одно окно затёрло проект, добавленный в другом")
        XCTAssertTrue(final.workspaces.contains { $0.name == "Добавлен в первом окне" })
        XCTAssertTrue(final.workspaces.contains { $0.name == "Добавлен во втором окне" })
    }

    /// Удаление проекта — осознанное действие, оно обязано доезжать до диска.
    func testRemoveIsPersisted() {
        let store = WorkspaceStore(fileURL: file)
        let ws = sample("Лишний")
        store.add(ws)
        store.add(sample("Нужный"))

        store.remove(ws)

        let reread = WorkspaceStore(fileURL: file)
        XCTAssertEqual(reread.workspaces.map(\.name), ["Нужный"])
    }

    // MARK: - Разделы по компаниям и поиск

    /// Проекты, сохранённые ДО появления компаний, никуда не деваются и не ломают чтение файла.
    /// Новое поле не имеет права стоить старых данных.
    func testProjectsSavedBeforeCompaniesExistedStillLoad() throws {
        let old = """
        [{"id":"361104CE-2350-4201-BEA0-5405D1289E24","name":"Acme",
          "host":"user@example.com","path":"/home/user/www","readOnly":false}]
        """
        try Data(old.utf8).write(to: file)

        let store = WorkspaceStore(fileURL: file)
        XCTAssertEqual(store.workspaces.map(\.name), ["Acme"], "старые проекты не прочитались")
        XCTAssertNil(store.workspaces.first?.company)

        // И попадают в общий раздел, а не пропадают из списка.
        XCTAssertEqual(store.sections().map(\.company), [Workspace.noCompany])
    }

    private func project(_ name: String, company: String? = nil,
                         host: String = "user@example.com", path: String = "/srv/app") -> Workspace {
        Workspace(name: name, host: host, path: path, company: company)
    }

    /// Разделы — по компаниям, по алфавиту. «Без компании» внизу: это не компания, а её
    /// отсутствие, и стоять первой в списке у неё оснований нет.
    func testSectionsAreGroupedByCompanyWithNamelessOnesLast() {
        let store = WorkspaceStore(fileURL: file)
        store.add(project("Сайт", company: "Nimbus"))
        store.add(project("Личное"))
        store.add(project("Бот", company: "Aurora"))
        store.add(project("Админка", company: "Nimbus"))

        let sections = store.sections()
        XCTAssertEqual(sections.map(\.company), ["Aurora", "Nimbus", Workspace.noCompany])

        // Внутри раздела — тоже по алфавиту.
        XCTAssertEqual(sections[1].items.map(\.name), ["Админка", "Сайт"])
    }

    /// Поиск идёт по всем проектам сразу и не только по названию: помнишь сервер или компанию,
    /// а не то, как ты этот проект однажды назвал.
    func testSearchLooksAtNameCompanyHostAndPath() {
        let store = WorkspaceStore(fileURL: file)
        store.add(project("Сайт", company: "Nimbus", host: "user@192.0.2.1", path: "/srv/site"))
        store.add(project("Бот", company: "Aurora", host: "root@bot.example.com", path: "/opt/bot"))

        func found(_ q: String) -> [String] {
            store.sections(matching: q).flatMap(\.items).map(\.name)
        }

        XCTAssertEqual(found("сайт"), ["Сайт"], "поиск по названию, без учёта регистра")
        XCTAssertEqual(found("aurora"), ["Бот"], "поиск по компании, без учёта регистра")
        XCTAssertEqual(found("192.0.2.1"), ["Сайт"], "поиск по серверу")
        XCTAssertEqual(found("/opt"), ["Бот"], "поиск по пути")
        XCTAssertEqual(found("").sorted(), ["Бот", "Сайт"], "пустой запрос показывает всё")
        XCTAssertTrue(found("несуществующее").isEmpty)
    }

    /// Пустые после фильтрации разделы исчезают: заголовок компании, под которым ни одного
    /// проекта, — это мусор на экране.
    func testEmptySectionsDisappearWhenSearching() {
        let store = WorkspaceStore(fileURL: file)
        store.add(project("Сайт", company: "Nimbus"))
        store.add(project("Бот", company: "Aurora"))

        XCTAssertEqual(store.sections(matching: "Сайт").map(\.company), ["Nimbus"])
    }

    /// Список компаний — для выбора в форме: чтобы не набирать заново и не разводить дубликаты.
    func testCompaniesAreUniqueAndSorted() {
        let store = WorkspaceStore(fileURL: file)
        store.add(project("а", company: "Nimbus"))
        store.add(project("б", company: "Aurora"))
        store.add(project("в", company: "Nimbus"))
        store.add(project("г", company: "   "))   // пробелы — это не компания
        store.add(project("д"))

        XCTAssertEqual(store.companies, ["Aurora", "Nimbus"])
    }

    /// Правка проекта (сменился хост, путь, порт) сохраняется, а не теряется при перезапуске.
    func testUpdateIsPersisted() {
        let store = WorkspaceStore(fileURL: file)
        var ws = sample("Проект")
        store.add(ws)

        ws.host = "user@новый-сервер"
        ws.port = 2222
        store.update(ws)

        let reread = WorkspaceStore(fileURL: file)
        XCTAssertEqual(reread.workspaces.first?.host, "user@новый-сервер")
        XCTAssertEqual(reread.workspaces.first?.port, 2222)
    }
}
