import XCTest
@testable import Remoter

/// Разделы панели git.
///
/// Главное здесь — файл, изменённый И в индексе, И в рабочей копии («MM»). Он должен стоять
/// в ОБОИХ разделах: это две разные правки, и делать с ними надо разное. Прежняя панель
/// показывала такой файл только в индексе — и коммит уносил не то, что было видно на экране.
final class GitSectionsTests: XCTestCase {

    private func change(_ path: String, _ x: Character, _ y: Character) -> GitChange {
        // kind нас здесь не интересует: разделы смотрят на stagedKind/worktreeKind, а не на него.
        GitChange(path: path, origPath: nil, x: x, y: y, kind: .modified)
    }

    /// «MM» — правка в индексе и ещё одна поверх неё, не добавленная. Два разных изменения.
    func testFileChangedBothInIndexAndInWorktreeIsInBothSections() {
        let c = change("src/main.py", "M", "M")

        XCTAssertEqual(c.stagedKind, .modified, "правка в индексе не показана")
        XCTAssertEqual(c.worktreeKind, .modified,
                       "несохранённая правка не показана — коммит унесёт не то, что видно")
    }

    /// «M.» — всё уехало в индекс, рабочая копия ему равна. В «Изменениях» файлу делать нечего.
    func testFullyStagedFileIsOnlyInTheIndexSection() {
        let c = change("a.txt", "M", ".")

        XCTAssertEqual(c.stagedKind, .modified)
        XCTAssertNil(c.worktreeKind, "файл без правок вне индекса попал в «Изменения»")
    }

    /// «.M» — правка есть, в индекс не добавлена.
    func testUnstagedFileIsOnlyInTheChangesSection() {
        let c = change("a.txt", ".", "M")

        XCTAssertNil(c.stagedKind, "пустой индекс показан как непустой")
        XCTAssertEqual(c.worktreeKind, .modified)
    }

    /// Новый файл git не отслеживает вовсе — он в «Изменениях», и его буква «?».
    func testUntrackedFileIsAChangeNotAnIndexEntry() {
        let c = change("новый.txt", "?", "?")

        XCTAssertNil(c.stagedKind)
        XCTAssertEqual(c.worktreeKind, .untracked)
        XCTAssertEqual(c.worktreeKind?.letter, "?")
    }

    /// Файл добавлен в индекс, а потом ещё правлен. В индексе он «A», в изменениях — «M»:
    /// одна буква на оба раздела соврала бы в одном из них.
    func testAddedThenEditedShowsDifferentLettersInEachSection() {
        let c = change("новый.py", "A", "M")

        XCTAssertEqual(c.stagedKind, .added)
        XCTAssertEqual(c.worktreeKind, .modified)
        XCTAssertEqual(c.stagedKind?.letter, "A")
        XCTAssertEqual(c.worktreeKind?.letter, "M")
    }

    /// Переименование живёт в индексе — иначе о нём нельзя узнать: git видит переименование
    /// только там.
    func testRenameIsAnIndexEntry() {
        let c = GitChange(path: "новое.txt", origPath: "старое.txt", x: "R", y: ".", kind: .renamed)

        XCTAssertEqual(c.stagedKind, .renamed)
        XCTAssertNil(c.worktreeKind)
    }

    /// Конфликт — не «изменение» и не «в индексе». С ним сначала разбираются, и он стоит
    /// отдельным разделом, наверху.
    func testConflictIsNeitherStagedNorAChange() {
        let c = change("src/main.py", "U", "U")

        XCTAssertTrue(c.isConflicted)
        XCTAssertNil(c.stagedKind, "конфликт показан как обычная правка в индексе")
        XCTAssertNil(c.worktreeKind, "конфликт показан как обычное изменение")
    }

    /// Удаление видно с обеих сторон: удалили в рабочей копии (`.D`) — или удаление уже в индексе.
    func testDeletionIsVisibleFromWhicheverSideItHappened() {
        let inWorktree = change("удалённый.txt", ".", "D")
        XCTAssertEqual(inWorktree.worktreeKind, .deleted)
        XCTAssertNil(inWorktree.stagedKind)

        let inIndex = change("удалённый.txt", "D", ".")
        XCTAssertEqual(inIndex.stagedKind, .deleted)
        XCTAssertNil(inIndex.worktreeKind)
    }
}
