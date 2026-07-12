import XCTest
@testable import Remoter

/// Проект на этом же Mac: папка на диске, без ssh и без сервера.
///
/// Этот файл — единственный, который обязан проходить на ГОЛОЙ машине: ни sshd, ни стенда из
/// `Tests/local-sshd.sh` здесь не нужно. В этом и смысл локального проекта — он работает там,
/// где нет вообще ничего, и проверка его работоспособности не имеет права зависеть от того,
/// подняли ли рядом демон.
///
/// Проверяется ровно то, что при переходе с ssh на `/bin/sh` ломается тише всего:
///
/// - те же самые POSIX-скрипты (дерево, чтение, атомарная запись, git) исполняются локально;
/// - `WorkspaceModel` поднимает проект без единого обращения к сети;
/// - папка без git не роняет приложение;
/// - **provision не мусорит в чужом репозитории** — ни CLAUDE.md, ни `remote`, ни `docs/`;
/// - старый список проектов (без `isLocal`/`readOnly`) по-прежнему читается.
///
/// Всё живёт в своей временной папке (`NSTemporaryDirectory`) и убирается в `tearDown`.
/// Ни `~/Remoter`, ни настоящий список проектов тесты не видят — ни на запись, ни на чтение.
/// Однажды уборка после прогона уже стёрла все проекты пользователя; больше такой возможности
/// у тестов просто нет (см. TestIsolation).
final class LocalProjectTests: XCTestCase {

    /// Своя временная папка на каждый тест: фикстуры не пересекаются, а порядок тестов
    /// ни на что не влияет.
    private var root: URL!

    override func setUpWithError() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("remoter-local-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Путь разрешаем ЧЕРЕЗ realpath, а не через `URL.resolvingSymlinksInPath()`: у последнего
        // на маке ровно обратное поведение — он не разворачивает `/var` → `/private/var`, а срезает
        // `/private`. А `pwd -P` и git отдают путь развёрнутым. Оставь мы `/var/...` — корень
        // репозитория и пути дерева оказались бы разными строками, и приложение не сопоставило бы
        // ни одного файла со списком изменений. Ровно этой граблей и посвящён комментарий
        // про `pwd -P` в Tests/local-sshd.sh.
        guard let resolved = realpath(dir.path, nil) else {
            throw XCTSkip("не удалось разрешить путь временной папки")
        }
        defer { free(resolved) }
        root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    override func tearDownWithError() throws {
        // Убираем только СВОЮ временную папку — по явному пути, который сами и завели.
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    // MARK: - Стенд

    /// Тестовый репозиторий: по одному файлу на каждый вид изменения, плюс имя с пробелом
    /// и юникодом и бинарник — ровно то, на чём ломается наивный разбор вывода git.
    /// Повторяет стенд из `Tests/local-sshd.sh`, но без sshd: папка и есть проект.
    @discardableResult
    private func makeRepo() throws -> String {
        let repo = root.appendingPathComponent("repo", isDirectory: true).path
        try sh("""
        set -e
        mkdir -p \(shq(repo))/src/utils \(shq(repo))/docs
        cd \(shq(repo))

        git init -q -b main
        git config user.email test@remoter
        git config user.name Test
        # Чужие глобальные настройки не должны решать судьбу теста: подпись коммитов уронила бы
        # его на ровном месте, а глобальный gitignore мог бы спрятать файлы фикстуры.
        git config commit.gpgsign false
        git config core.excludesFile /dev/null

        printf 'def hello():\\n    print("hi")\\n    return 1\\n' > src/main.py
        printf 'export const a = 1;\\nexport const b = 2;\\n' > src/utils/helper.ts
        printf 'old file\\n' > src/old_name.py
        printf 'to be deleted\\n' > docs/gone.md
        printf '# Docs\\n' > docs/readme.md
        printf 'имя с пробелом\\n' > 'docs/файл с пробелом.md'
        # Заголовок PNG: в нём есть нулевые байты, поэтому бинарник определяется детерминированно —
        # именно по NUL (как и в самом git) мы отличаем его от текста.
        printf '\\211PNG\\r\\n\\032\\n\\0\\0\\0\\rIHDR\\0\\0\\0\\1\\0\\0\\0\\1' > docs/blob.bin
        git add -A && git commit -qm init

        printf 'def hello():\\n    print("HELLO WORLD")\\n    print("new line")\\n    return 42\\n' > src/main.py
        printf 'export const a = 1;\\nexport const b = 99;\\nexport const c = 3;\\n' > src/utils/helper.ts
        git add src/utils/helper.ts
        printf 'brand new\\nsecond line\\n' > src/brand_new.py
        rm docs/gone.md
        git mv src/old_name.py src/new_name.py
        printf 'old file\\nplus a change\\n' > src/new_name.py
        """)
        return repo
    }

    /// Проект БЕЗ git — просто папка с файлами. Так выглядит половина реальных «проектов»:
    /// каталог с заметками, скриптами, чем угодно.
    private func makePlainFolder() throws -> String {
        let dir = root.appendingPathComponent("plain", isDirectory: true).path
        try sh("""
        set -e
        mkdir -p \(shq(dir))/src
        cd \(shq(dir))
        printf 'просто файл\\n' > src/main.py
        printf 'без всякого git\\n' > 'заметка с пробелом.md'
        """)
        return dir
    }

    /// Скрипты стенда гоняем мимо `LocalConnection` — тем самым он остаётся тем, что ПРОВЕРЯЕТСЯ,
    /// а не тем, чем проверку готовят. Сломайся он — стенд об этом не соврёт.
    private func sh(_ script: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let r = try Proc.runSync("/bin/sh", ["-c", script], timeout: 60)
        XCTAssertTrue(r.ok, "скрипт стенда не отработал (\(r.code)): \(r.err)", file: file, line: line)
    }

    private func workspace(_ path: String, name: String = "локальный") -> Workspace {
        // Хост пуст, ssh-опций нет: у локального проекта нет ни того, ни другого.
        Workspace(name: name, path: path, isLocal: true)
    }

    @MainActor
    private func started(_ path: String, name: String = "локальный") async -> WorkspaceModel {
        let model = WorkspaceModel(workspace: workspace(path, name: name))
        await model.start()
        return model
    }

    // MARK: - 1. Те же скрипты, только исполняет их /bin/sh

    /// Дерево файлов локального проекта. Имя с пробелом и юникодом — не экзотика, а норма
    /// (`docs/файл с пробелом.md`), и разъехавшееся экранирование увидели бы именно здесь:
    /// файл либо пропал бы из списка, либо приехал разорванным на два.
    @MainActor
    func testLocalConnectionListsFilesIncludingSpacesAndUnicode() async throws {
        let repo = try makeRepo()
        let conn = LocalConnection()

        // Локальному каналу подключаться не к чему — связь есть с самого начала. Остальной код
        // проверяет `isConnected` перед КАЖДОЙ операцией: соври он здесь — не заработало бы ничего.
        XCTAssertTrue(conn.state.isConnected, "локальный проект обязан считаться подключённым сразу")

        let top = try await RemoteFS.list(conn: conn, dir: repo)
        let names = top.map(\.name)
        XCTAssertTrue(names.contains("src"), "дерево не увидело папку: \(names)")
        XCTAssertTrue(names.contains("docs"))
        XCTAssertTrue(names.contains(".git"), "скрытые файлы пропали из дерева: \(names)")

        // Папки сверху — сортировка одна и та же у сервера и у локальной папки.
        XCTAssertTrue(top.first?.isDir == true, "папки не подняты наверх: \(names)")

        let docs = try await RemoteFS.list(conn: conn, dir: repo + "/docs")
        XCTAssertEqual(
            Set(docs.map(\.name)),
            ["blob.bin", "readme.md", "файл с пробелом.md"],
            "имя с пробелом и юникодом не пережило дорогу через шелл"
        )

        // И путь у него собран так, что по нему файл действительно открывается.
        let tricky = try XCTUnwrap(docs.first { $0.name == "файл с пробелом.md" })
        XCTAssertFalse(tricky.isDir)
        let file = try await RemoteFS.read(conn: conn, path: tricky.path)
        XCTAssertEqual(file.displayText, "имя с пробелом\n")
    }

    /// Чтение: текст, бинарник и «слишком большой». Разница не косметическая — от неё зависит,
    /// что уедет в редактор: текст, заглушка или четыре мегабайта мусора.
    @MainActor
    func testReadTellsTextFromBinaryAndTooLarge() async throws {
        let repo = try makeRepo()
        let conn = LocalConnection()

        let text = try await RemoteFS.read(conn: conn, path: repo + "/src/main.py")
        XCTAssertTrue(text.isEditable, "обычный UTF-8 должен быть доступен для правки")
        XCTAssertEqual(text.displayText?.contains("HELLO WORLD"), true)

        // Бинарник опознаётся по нулевому байту — как и в git.
        let blob = try await RemoteFS.read(conn: conn, path: repo + "/docs/blob.bin")
        guard case .binary = blob else { return XCTFail("PNG-заголовок не опознан как бинарник: \(blob)") }
        XCTAssertFalse(blob.isEditable, "бинарник нельзя открывать на правку — сохранение испортило бы его")

        // Слишком большой файл даже не читается целиком: сначала спрашивается размер.
        let big = repo + "/huge.log"
        try sh("dd if=/dev/zero of=\(shq(big)) bs=1048576 count=5 2>/dev/null")
        let huge = try await RemoteFS.read(conn: conn, path: big)
        guard case .tooLarge(let bytes) = huge else { return XCTFail("файл на 5 МБ прошёл как обычный: \(huge)") }
        XCTAssertGreaterThan(bytes, RemoteFS.maxFileSize)

        // Файла нет — это `.missing`, а не пустой текст: пустышка в редакторе выглядела бы как
        // файл, который кто-то опустошил.
        let gone = try await RemoteFS.read(conn: conn, path: repo + "/docs/gone.md")
        guard case .missing = gone else { return XCTFail("удалённый файл прочитался: \(gone)") }
    }

    /// Запись атомарна и не портит файл: содержимое доезжает целиком, права сохраняются,
    /// временных огрызков рядом не остаётся.
    @MainActor
    func testWriteReplacesFileAtomicallyAndKeepsPermissions() async throws {
        let repo = try makeRepo()
        let conn = LocalConnection()

        let path = repo + "/src/hook.sh"
        try sh("printf '#!/bin/sh\\necho было\\n' > \(shq(path)) && chmod 755 \(shq(path))")

        let content = "#!/bin/sh\necho стало — с юникодом\n"
        try await RemoteFS.write(conn: conn, path: path, content: content)

        let onDisk = try await RemoteFS.read(conn: conn, path: path)
        XCTAssertEqual(onDisk.displayText, content, "на диск записалось не то, что просили")

        // Права снимаются с оригинала (`cp -p`) до записи. Не сохрани мы их — исполняемый скрипт
        // после сохранения из редактора просто перестал бы запускаться.
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path), "файл потерял +x")

        // Никаких `.remoter.tmp.*` рядом: они бы мозолили глаза в `git status` пользователя.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: repo + "/src")
            .filter { $0.hasPrefix(".remoter.tmp") }
        XCTAssertTrue(leftovers.isEmpty, "после записи остался мусор: \(leftovers)")
    }

    /// Недоехавшее содержимое не должно оказаться на месте файла.
    ///
    /// Гоняем БОЕВОЙ скрипт записи (`RemoteFS.writeScript`), скормив ему на байт меньше, чем он
    /// ждёт: локально так выглядел бы убитый на середине процесс, по ssh — обрыв связи. Файл
    /// обязан остаться прежним, а не превратиться в обрубок.
    @MainActor
    func testTruncatedWriteLeavesOriginalIntact() async throws {
        let repo = try makeRepo()
        let conn = LocalConnection()

        let path = repo + "/precious.txt"
        let original = "очень важные данные\n"
        try sh("printf '%s' \(shq(original)) > \(shq(path))")

        let data = Data("новое содержимое\n".utf8)
        let r = try await conn.sh(
            RemoteFS.writeScript(path: path, expectedBytes: data.count + 1),
            stdin: data
        )

        XCTAssertEqual(r.code, RemoteFS.truncatedExitCode, "предохранитель обрезки не сработал")
        let after = try await RemoteFS.read(conn: conn, path: path)
        XCTAssertEqual(after.displayText, original, "на месте файла оказался обрубок")
    }

    // MARK: - 2. Git через локальный канал

    /// Разбор `git status` для локального проекта — те же пять видов изменений, что и на сервере.
    /// Ошибись разбор — список изменений показывал бы не то, а коммит уносил бы не те файлы.
    @MainActor
    func testGitStatusParsesEveryKindOfChangeLocally() async throws {
        let repo = try makeRepo()
        let conn = LocalConnection()

        let root = await Git.repoRoot(conn: conn, path: repo)
        XCTAssertEqual(root, repo, "корень репозитория не нашёлся локально")

        let status = try await Git.status(conn: conn, root: repo)
        XCTAssertEqual(status.branch, "main")

        func change(_ path: String) throws -> GitChange {
            try XCTUnwrap(status.changes.first { $0.path == path },
                          "в статусе нет \(path): \(status.changes.map(\.path))")
        }

        // Правка в рабочей копии.
        XCTAssertEqual(try change("src/main.py").kind, .modified)
        XCTAssertFalse(try change("src/main.py").isStaged)

        // Правка, уже уехавшая в индекс.
        let staged = try change("src/utils/helper.ts")
        XCTAssertEqual(staged.kind, .modified)
        XCTAssertTrue(staged.isStaged, "файл из индекса не опознан как застейдженный")
        XCTAssertTrue(staged.isStagedOnly)

        // Новый файл.
        XCTAssertEqual(try change("src/brand_new.py").kind, .untracked)

        // Удалённый.
        let deleted = try change("docs/gone.md")
        XCTAssertEqual(deleted.kind, .deleted)
        XCTAssertTrue(deleted.isDeletedInWorktree)

        // Переименованный — и вместе с ним прежнее имя: без него левая сторона diff'а
        // оказалась бы пустой, и пара правленых строк выглядела бы новым файлом целиком.
        let renamed = try change("src/new_name.py")
        XCTAssertEqual(renamed.kind, .renamed)
        XCTAssertEqual(renamed.origPath, "src/old_name.py")

        XCTAssertEqual(status.changes.count, 5, "лишние или потерянные записи: \(status.changes.map(\.path))")
        XCTAssertFalse(status.fingerprint.isEmpty, "без отпечатка поллинг не заметил бы изменений")
    }

    /// Левая сторона diff'а берётся из HEAD — и для переименованного файла по СТАРОМУ имени.
    @MainActor
    func testGitShowGivesLeftSideOfDiffLocally() async throws {
        let repo = try makeRepo()
        let conn = LocalConnection()

        let head = try await Git.show(conn: conn, root: repo, rev: "HEAD", path: "src/main.py")
        let text = String(decoding: try XCTUnwrap(head), as: UTF8.self)
        XCTAssertTrue(text.contains("print(\"hi\")"), "из HEAD приехала не та версия: \(text)")
        XCTAssertFalse(text.contains("HELLO WORLD"), "из HEAD приехала рабочая копия, а не версия из коммита")

        // Нового имени в HEAD нет — и это не ошибка, а причина брать версию по origPath.
        let byNewName = try await Git.show(conn: conn, root: repo, rev: "HEAD", path: "src/new_name.py")
        XCTAssertNil(byNewName)

        let byOldName = try await Git.show(conn: conn, root: repo, rev: "HEAD", path: "src/old_name.py")
        XCTAssertEqual(String(decoding: try XCTUnwrap(byOldName), as: UTF8.self), "old file\n")
    }

    /// Stage, unstage и откат правок — единственные команды, которые ЧТО-ТО МЕНЯЮТ в чужом
    /// репозитории. Сработай они мимо, человек потерял бы работу — поэтому проверяются
    /// по факту, а не по коду возврата.
    @MainActor
    func testStageUnstageAndDiscardWorkLocally() async throws {
        let repo = try makeRepo()
        let conn = LocalConnection()

        func status() async throws -> GitStatus {
            try await Git.status(conn: conn, root: repo)
        }
        func find(_ path: String, in st: GitStatus) throws -> GitChange {
            try XCTUnwrap(st.changes.first { $0.path == path }, "пропал \(path)")
        }

        // Новый файл уходит в индекс и становится «добавленным».
        let newFile = try find("src/brand_new.py", in: try await status())
        try await Git.stage(conn: conn, root: repo, change: newFile)

        let afterStage = try find("src/brand_new.py", in: try await status())
        XCTAssertEqual(afterStage.kind, .added, "файл не встал в индекс")
        XCTAssertTrue(afterStage.isStaged)

        // …и возвращается обратно в «новые», не пропадая с диска.
        try await Git.unstage(conn: conn, root: repo, change: afterStage)
        let afterUnstage = try find("src/brand_new.py", in: try await status())
        XCTAssertEqual(afterUnstage.kind, .untracked, "файл не вынулся из индекса")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo + "/src/brand_new.py"),
                      "unstage удалил файл с диска — это не откат, а потеря работы")

        // Откат правки: файл возвращается к версии из HEAD.
        let modified = try find("src/main.py", in: try await status())
        try await Git.discard(conn: conn, root: repo, change: modified)
        let restored = try await RemoteFS.read(conn: conn, path: repo + "/src/main.py")
        XCTAssertEqual(restored.displayText?.contains("print(\"hi\")"), true, "правка не откатилась")
        XCTAssertEqual(restored.displayText?.contains("HELLO WORLD"), false)

        // Откат неотслеживаемого — это удаление: возвращать его не к чему.
        try await Git.discard(conn: conn, root: repo, change: afterUnstage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo + "/src/brand_new.py"),
                       "новый файл не убрался")

        // Ни одна из операций не тронула чужие изменения.
        let final = try await status()
        XCTAssertTrue(final.changes.contains { $0.path == "src/utils/helper.ts" },
                      "чужая правка в индексе пропала")
        XCTAssertTrue(final.changes.contains { $0.path == "src/new_name.py" },
                      "переименование пропало")
    }

    // MARK: - 3. Окно проекта поднимается без всякого ssh

    /// Главное, ради чего всё затевалось: проект открывается на голой машине.
    /// Ни sshd, ни ключей, ни сети — только папка на диске.
    @MainActor
    func testLocalProjectStartsWithoutSSH() async throws {
        let repo = try makeRepo()
        let model = await started(repo)
        defer { model.stop() }

        XCTAssertTrue(model.conn is LocalConnection, "локальный проект полез в ssh")
        XCTAssertFalse(model.conn is SSHConnection)
        XCTAssertTrue(model.conn.state.isConnected)
        XCTAssertEqual(model.conn.terminalLaunch, .localShell, "терминал локального проекта — не ssh")

        XCTAssertEqual(model.basePath, repo)
        XCTAssertEqual(model.repoRoot, repo)
        XCTAssertEqual(model.status.branch, "main")
        XCTAssertEqual(model.status.changes.count, 5)

        // Дерево верхнего уровня загружено.
        let names = model.rows.map(\.entry.name)
        XCTAssertTrue(names.contains("src"), "дерево не поднялось: \(names)")
        XCTAssertTrue(names.contains("docs"))

        // Бейджи git разложены по путям — значит пути дерева и пути git сошлись.
        XCTAssertEqual(model.kindByPath["src/main.py"], .modified)
        XCTAssertTrue(model.changedDirs.contains("src"), "папка с правками не помечена — пути разъехались")

        // Раздела «Local» у локального проекта нет: его рабочая папка Claude — сам проект,
        // и второй раздел с тем же содержимым только путал бы.
        XCTAssertEqual(model.sidebarTabs, [.changes, .files])
        XCTAssertNil(model.errorMessage)
    }

    /// Клик по изменённому файлу даёт обе стороны diff'а — слева версия из HEAD, справа диск.
    @MainActor
    func testOpeningChangedFileGivesBothSidesOfDiffLocally() async throws {
        let repo = try makeRepo()
        let model = await started(repo)
        defer { model.stop() }

        let change = try XCTUnwrap(model.status.changes.first { $0.path == "src/main.py" })
        await model.openChange(change)

        let doc = try XCTUnwrap(model.doc)
        XCTAssertEqual(doc.mode, .diff)
        XCTAssertEqual(doc.relPath, "src/main.py")
        XCTAssertEqual(doc.kind, .modified)
        XCTAssertTrue(doc.editable)
        XCTAssertTrue(doc.original.contains("print(\"hi\")"), "левая сторона не из HEAD: \(doc.original)")
        XCTAssertTrue(doc.baseline.contains("HELLO WORLD"), "правая сторона не с диска: \(doc.baseline)")
    }

    /// Сохранение из редактора кладёт текст на диск — и именно тот, что был в редакторе.
    @MainActor
    func testSaveWritesToDiskLocally() async throws {
        let repo = try makeRepo()
        let model = await started(repo)
        defer { model.stop() }

        let path = repo + "/src/main.py"
        let change = try XCTUnwrap(model.status.changes.first { $0.path == "src/main.py" })
        await model.openChange(change)

        let edited = try XCTUnwrap(model.doc).baseline + "# сохранено из Remoter\n"
        await model.save(path: path, content: edited)

        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(try XCTUnwrap(model.doc).isDirty)

        // Читаем с диска мимо модели: важно, что там действительно лежит наш текст.
        let onDisk = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(onDisk, edited, "на диск записалось не то, что было в редакторе")
    }

    // MARK: - 4. Проект без git

    /// Папка без git — это тоже проект. Раздел изменений просто пуст, а дерево работает.
    /// Обращение к `repoRoot` без проверки уронило бы всё окно, а таких папок — половина.
    @MainActor
    func testFolderWithoutGitStillOpens() async throws {
        let dir = try makePlainFolder()
        let model = await started(dir, name: "без git")
        defer { model.stop() }

        XCTAssertTrue(model.conn.state.isConnected)
        XCTAssertNil(model.repoRoot, "в папке без git нашёлся репозиторий")
        XCTAssertTrue(model.status.changes.isEmpty, "в папке без git нашлись изменения")
        XCTAssertNil(model.errorMessage)

        // Раз изменений быть не может — открываемся сразу на файлах, а не на пустом разделе.
        XCTAssertEqual(model.tab, .files)

        let names = model.rows.map(\.entry.name)
        XCTAssertTrue(names.contains("src"), "дерево не поднялось: \(names)")
        XCTAssertTrue(names.contains("заметка с пробелом.md"))

        // Пути относительно корня репозитория не существует — и это не падение, а nil.
        XCTAssertNil(model.relPath(dir + "/src/main.py"))

        // Файл открывается обычным просмотром, без всякого diff'а.
        await model.openFile(dir + "/src/main.py")
        let doc = try XCTUnwrap(model.doc)
        XCTAssertEqual(doc.mode, .view)
        XCTAssertEqual(doc.baseline, "просто файл\n")
        XCTAssertNil(doc.relPath)
        XCTAssertNil(model.errorMessage)
    }

    // MARK: - 5. Сохранность чужой папки

    /// САМОЕ ВАЖНОЕ в этом файле. Папка локального проекта — ЧУЖАЯ: это может быть рабочий
    /// репозиторий с историей, командой и code review.
    ///
    /// Приложение не имеет права оставить в ней свой след. Ни CLAUDE.md (у проекта наверняка
    /// есть свой), ни скрипта `remote` (ходить некуда — файлы вот они), ни `docs/`. Появись там
    /// наши файлы — человек увидел бы их в `git status`, а то и закоммитил бы вместе с работой.
    ///
    /// Поэтому снимок папки до и после: появиться может РОВНО `.claude/settings.local.json`
    /// (хуки уведомлений — машинный файл самого Claude Code) и ничего больше. Сам скрипт хука
    /// живёт вне проекта.
    @MainActor
    func testProvisionLeavesNoTracesInsideLocalProject() async throws {
        let repo = try makeRepo()

        // `.git` из снимка исключён намеренно: его переписывает сам git (тот же `status` обновляет
        // кэш в индексе), и это его собственная бухгалтерия, а не наш мусор.
        let before = snapshot(repo)

        let model = await started(repo)
        defer { model.stop() }
        XCTAssertTrue(model.conn.state.isConnected)

        let added = snapshot(repo).subtracting(before)
        XCTAssertEqual(
            added, [".claude", ".claude/settings.local.json"],
            "provision насорил в чужом репозитории: \(added.sorted())"
        )

        // То же самое поимённо — чтобы при падении было видно, ЧТО именно появилось.
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: repo + "/CLAUDE.md"),
                       "в чужой репозиторий положили CLAUDE.md — у проекта есть свой")
        XCTAssertFalse(fm.fileExists(atPath: repo + "/remote"),
                       "в чужой репозиторий положили скрипт доступа к серверу, которого нет")
        XCTAssertFalse(fm.fileExists(atPath: repo + "/docs/О проекте.md"),
                       "в чужой docs/ положили нашу заметку")
        XCTAssertFalse(fm.fileExists(atPath: repo + "/.remoter-id"),
                       "в чужой репозиторий положили маркер владельца")

        // Скрипт хука — вне проекта. Иначе он лежал бы в репозитории и просился в коммит.
        let priv = LocalWorkspace.privateDirectory(for: model.workspace)
        XCTAssertFalse(priv.path.hasPrefix(repo), "наш каталог оказался внутри чужого проекта: \(priv.path)")
        XCTAssertTrue(fm.fileExists(atPath: priv.appendingPathComponent("remoter-notify.sh").path),
                      "скрипт хука не поставился вовсе — уведомлений не будет")
        XCTAssertFalse(fm.fileExists(atPath: repo + "/.claude/remoter-notify.sh"),
                       "скрипт хука лежит в чужом репозитории")

        // И в самих хуках прописан путь наружу, а не внутрь проекта.
        let settings = try String(contentsOfFile: repo + "/.claude/settings.local.json", encoding: .utf8)
        XCTAssertTrue(settings.contains(priv.path), "хук зовёт скрипт не из нашего каталога")
        XCTAssertFalse(settings.contains(repo + "/.claude/remoter-notify.sh"))

        // Живой репозиторий это подтверждает: git видит ровно одну новую запись — и ту машинную.
        let conn = LocalConnection()
        let status = try await Git.status(conn: conn, root: repo)
        let untracked = status.changes.filter { $0.kind == .untracked }.map(\.path).sorted()
        XCTAssertEqual(untracked, [".claude/settings.local.json", "src/brand_new.py"],
                       "в git status пользователя появилось лишнее: \(untracked)")
    }

    /// Скриншоты из буфера тоже НЕ ложатся в чужой репозиторий: `.attachments` в нём —
    /// это пачканье чужого `git status`, причём бинарниками.
    @MainActor
    func testAttachmentsOfLocalProjectLiveOutsideIt() async throws {
        let repo = try makeRepo()
        let model = await started(repo)
        defer { model.stop() }

        let dir = try XCTUnwrap(model.attachmentsDir, "некуда складывать вложения")
        XCTAssertFalse(dir.path.hasPrefix(repo + "/"),
                       "вложения складываются внутрь чужого проекта: \(dir.path)")
        XCTAssertTrue(dir.path.hasSuffix("attachments"))

        // Для сравнения: у серверного проекта они как раз внутри его локальной папки — она наша.
        let remote = Workspace(name: "на сервере", host: "example.com", path: "/srv/app")
        let remoteDir = LocalWorkspace.attachmentsDirectory(for: remote, localPath: "/tmp/локальная")
        XCTAssertEqual(remoteDir.path, "/tmp/локальная/.attachments")
    }

    // MARK: - 6. Обратная совместимость списка проектов

    /// Список проектов писался прошлыми версиями — в нём нет ни `isLocal`, ни `readOnly`.
    /// «Строгий» разбор означал бы «после обновления пропали все проекты»: это адреса серверов
    /// и пути, набранные руками, и восстановить их неоткуда.
    @MainActor
    func testOldProjectListWithoutNewFieldsStillLoads() throws {
        // Ровно то, что лежит на диске у человека, который поставил обновление: полей isLocal
        // и readOnly в файле нет вовсе.
        let json = Data("""
        [
          {
            "id": "8C5D9E90-1B2C-4D3E-9F10-111213141516",
            "name": "прод",
            "host": "example.com",
            "path": "/srv/app"
          },
          {
            "id": "9D6EAFA1-2C3D-5E4F-A021-222324252627",
            "name": "стенд",
            "host": "st.example.com",
            "path": "/srv/app",
            "port": 2222,
            "company": "Nimbus",
            "sshOptions": "-J bastion"
          }
        ]
        """.utf8)

        let list = try JSONDecoder().decode([Workspace].self, from: json)
        XCTAssertEqual(list.count, 2, "старый список не разобрался — у людей пропали бы все проекты")

        // Отсутствующее поле — это значение по умолчанию, а не ошибка.
        XCTAssertFalse(list[0].isLocal)
        XCTAssertFalse(list[0].readOnly)
        XCTAssertEqual(list[0].host, "example.com")
        XCTAssertEqual(list[1].port, 2222)
        XCTAssertEqual(list[1].company, "Nimbus")

        // И то же самое через сам список проектов — ровно так его читает приложение.
        // Файл СВОЙ, во временной папке: настоящий список тесты не видят вовсе.
        let file = root.appendingPathComponent("workspaces.json")
        try json.write(to: file)
        let store = WorkspaceStore(fileURL: file)
        XCTAssertEqual(store.workspaces.map(\.name), ["прод", "стенд"],
                       "после обновления список проектов оказался бы пустым")

        // Новый локальный проект переживает круг «записали — прочитали».
        let saved = try JSONEncoder().encode([workspace("/Users/me/проект")])
        let back = try JSONDecoder().decode([Workspace].self, from: saved)
        XCTAssertTrue(back[0].isLocal, "локальность проекта потерялась при сохранении")
        XCTAssertTrue(back[0].host.isEmpty)
        XCTAssertEqual(back[0].subtitle, "/Users/me/проект", "у локального проекта в подписи нет хоста")
    }

    // MARK: - Снимок папки

    /// Пути всего, что лежит в папке, относительно неё самой. `.git` пропускаем: его содержимое
    /// переписывает сам git, и к нашему мусору это отношения не имеет.
    private func snapshot(_ dir: String) -> Set<String> {
        let base = URL(fileURLWithPath: dir, isDirectory: true)
        guard let walker = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: nil,
            options: [.producesRelativePathURLs]
        ) else {
            XCTFail("не удалось обойти \(dir)")
            return []
        }

        var out: Set<String> = []
        for case let url as URL in walker {
            let rel = url.relativePath
            if rel == ".git" {
                walker.skipDescendants()
                continue
            }
            out.insert(rel)
        }
        return out
    }
}
