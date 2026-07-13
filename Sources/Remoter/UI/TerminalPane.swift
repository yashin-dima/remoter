import SwiftUI
import SwiftTerm
import AppKit

/// Какой это терминал.
///
/// Сессий Claude по проекту может быть несколько — работа над разными задачами идёт параллельно,
/// и открывать новую, обрывая текущую, бессмысленно. Поэтому терминал адресуется не «локальный
/// или серверный», а конкретной сессией.
enum TerminalID: Hashable {
    /// Разговор с Claude. У каждого свой шелл, свой процесс и свой id.
    case claude(UUID)
    /// Обычный ssh на сервер — руками потыкать, посмотреть логи, запустить тесты.
    /// Их тоже может быть несколько: пока в одном крутится хвост лога, во втором работают.
    case remote(UUID)

    var isClaude: Bool {
        if case .claude = self { return true }
        return false
    }
}

/// Ручка к живому терминалу. Через неё панель Claude отправляет команду в терминал —
/// ровно в тот, который сейчас открыт.
@MainActor
final class TerminalHandle: ObservableObject {
    private var views: [TerminalID: LocalProcessTerminalView] = [:]

    /// Команда, которую попросили выполнить раньше, чем терминал успел появиться.
    ///
    /// Так бывает при открытии проекта: последнюю сессию Claude мы хотим продолжить сразу,
    /// но решается это в конце `start()`, а сам терминал SwiftUI создаёт только после того,
    /// как модель об этом сообщит. Без очереди команда просто улетала бы в никуда.
    private var pending: [TerminalID: String] = [:]

    /// Терминалы, которым фокус пообещали раньше, чем они появились на свет. Новая вкладка
    /// открывается мгновенно, а её терминал SwiftUI создаёт следующим кадром — без этой отметки
    /// курсор оставался бы в предыдущей вкладке, и первая набранная строка уходила бы не туда.
    private var wantsFocus: Set<TerminalID> = []

    /// Печатает текст в строку ввода, НЕ нажимая Enter: так вставляются пути к файлам,
    /// которые вы бросили в окно. Дальше вы дописываете вопрос сами.
    func type(_ text: String, on side: TerminalID) {
        guard let view = views[side] else { return }
        view.process.send(data: ArraySlice(Array(text.utf8)))
        focus(side)
    }

    /// Печатает команду и жмёт Enter — как если бы вы набрали её сами.
    /// Никакой скрытой магии: команда видна в терминале, её можно поправить или прервать.
    func run(_ command: String, on side: TerminalID) {
        guard let view = views[side] else {
            pending[side] = command
            return
        }
        send(command, to: view)
        focus(side)
    }

    /// Что ждёт своей очереди. Нужно тесту: терминала в тестовом процессе нет, а проверить,
    /// что при открытии проекта продолжается ИМЕННО последняя сессия, необходимо.
    func pendingCommand(for side: TerminalID) -> String? { pending[side] }

    /// Переключились на вкладку терминала — печатать надо сразу, без клика по нему.
    func focus(_ side: TerminalID) {
        guard let view = views[side] else {
            wantsFocus.insert(side)
            return
        }
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }

    fileprivate func register(_ view: LocalProcessTerminalView, for side: TerminalID) {
        views[side] = view

        if wantsFocus.remove(side) != nil {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }

        guard let command = pending.removeValue(forKey: side) else { return }

        // Шеллу нужно мгновение, чтобы дочитать свой профиль и включить редактор строки.
        // Команда, отправленная раньше, доедет, но напечатается вперемешку с приглашением —
        // выглядит как сбой, хотя ничего не сломалось.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak view] in
            guard let self, let view, self.views[side] === view else { return }
            self.send(command, to: view)
        }
    }

    /// Сессию закрыли — гасим процесс и забываем терминал. На deinit view полагаться нельзя:
    /// SwiftTerm намеренно не шлёт SIGTERM из deinit, а SIGHUP от закрытия PTY игнорируется
    /// nohup'ом и демонами — без явного terminate() процесс остался бы сиротой.
    func forget(_ side: TerminalID) {
        views[side]?.process.terminate()
        views[side] = nil
        pending[side] = nil
        wantsFocus.remove(side)
    }

    /// Пауза между текстом команды и Enter. Меньше 150 мс TUI Claude иногда склеивает их
    /// в одну «вставку»; полсекунды уже заметны глазу. 250 — надёжно и неощутимо.
    private static let enterDelay: TimeInterval = 0.25

    private func send(_ command: String, to view: LocalProcessTerminalView) {
        // Enter уходит ОТДЕЛЬНОЙ посылкой, с паузой. Слэш-команды попадают не в шелл, а в TUI
        // Claude: он видит «/model opus\n» одним куском, считает это вставкой текста — и перевод
        // строки становится частью ввода, а не подтверждением. Команда просто лежала в строке,
        // пока Enter не нажимали руками. Раздельная отправка читается как «набрали и нажали».
        view.process.send(data: ArraySlice(Array(command.utf8)))
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.enterDelay) { [weak view] in
            guard let view else { return }
            view.process.send(data: ArraySlice(Array("\r".utf8)))
        }
    }
}

/// Оформление терминала.
///
/// Цвета — те же, что у встроенного терминала VS Code: приложение стоит рядом с редактором
/// и не должно выглядеть чужим. Фон, текст и курсор берутся из хекс-пар Theme (Design.swift) —
/// это одни и те же значения, а не их копия, которая разъехалась бы при первой правке палитры.
///
/// Все функции принимают `dark:` явно: терминалу нужна тема ЕГО окна в момент вызова
/// (см. DropTerminalView.applyTheme), а не глобальная тема приложения на момент создания.
enum TerminalTheme {

    static func background(dark: Bool) -> NSColor { Theme.nsColor(pair: Theme.surfaceHex, dark: dark) }
    static func foreground(dark: Bool) -> NSColor { Theme.nsColor(pair: Theme.textHex, dark: dark) }
    static func caret(dark: Bool) -> NSColor { Theme.nsColor(pair: Theme.accentHex, dark: dark) }
    static func selection(dark: Bool) -> NSColor {
        Theme.nsColor(pair: (light: 0xADD6FF, dark: 0x264F78), dark: dark)
    }

    static func font(size: CGFloat) -> NSFont {
        // SF Mono — системный моноширинный: с ним рамки и таблицы, которые рисует Claude,
        // не разъезжаются.
        NSFont(name: "SFMono-Regular", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// 16 цветов ANSI: 8 обычных и 8 ярких. Порядок фиксирован стандартом — чёрный, красный,
    /// зелёный, жёлтый, синий, пурпурный, голубой, белый.
    static func palette(dark: Bool) -> [SwiftTerm.Color] {
        dark ? darkPalette : lightPalette
    }

    private static let lightPalette: [SwiftTerm.Color] = [
        rgb(0x00, 0x00, 0x00), rgb(0xCD, 0x31, 0x31), rgb(0x1B, 0x84, 0x2C), rgb(0xB2, 0x6A, 0x00),
        rgb(0x04, 0x51, 0xA5), rgb(0xBC, 0x05, 0xBC), rgb(0x05, 0x98, 0xBC), rgb(0x55, 0x55, 0x55),
        rgb(0x66, 0x66, 0x66), rgb(0xCD, 0x31, 0x31), rgb(0x14, 0xCE, 0x14), rgb(0xB5, 0xBA, 0x00),
        rgb(0x04, 0x51, 0xA5), rgb(0xBC, 0x05, 0xBC), rgb(0x05, 0x98, 0xBC), rgb(0xA5, 0xA5, 0xA5),
    ]

    private static let darkPalette: [SwiftTerm.Color] = [
        rgb(0x2B, 0x2F, 0x38), rgb(0xE0, 0x6C, 0x75), rgb(0x98, 0xC3, 0x79), rgb(0xE5, 0xC0, 0x7B),
        rgb(0x61, 0xAF, 0xEF), rgb(0xC6, 0x78, 0xDD), rgb(0x56, 0xB6, 0xC2), rgb(0xAB, 0xB2, 0xBF),
        rgb(0x5C, 0x63, 0x70), rgb(0xEF, 0x8B, 0x93), rgb(0xB0, 0xD6, 0x94), rgb(0xF0, 0xD3, 0x9B),
        rgb(0x82, 0xC2, 0xFF), rgb(0xD8, 0x9C, 0xF0), rgb(0x74, 0xD0, 0xDA), rgb(0xE6, 0xEA, 0xF0),
    ]

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
    }
}

/// Настоящий терминал: либо локальный шелл, либо ssh-сессия на сервере.
///
/// Серверный подключается через тот же мультиплексор, что и всё остальное (`-S <сокет>`),
/// поэтому открывается мгновенно и не просит пароль второй раз.
struct TerminalPane: NSViewRepresentable {
    let side: TerminalID
    /// Чем запускать терминал проекта: ssh на сервер или шелл прямо здесь. Решает транспорт
    /// (см. Connection.terminalLaunch) — панель об устройстве проекта больше ничего не знает.
    let launch: TerminalLaunch
    let remotePath: String
    let localPath: String
    /// Куда падают скриншоты из буфера. У локального проекта — не в его репозиторий.
    let attachmentsDir: URL?
    /// Переменные для локального шелла: хост, путь и сокет — чтобы Claude и вы могли
    /// дотянуться до сервера, не подглядывая в настройки.
    let localEnv: [String]
    let handle: TerminalHandle
    let fontSize: CGFloat

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let term = DropTerminalView(frame: .zero)
        term.attachmentsDir = side.isClaude ? attachmentsDir : nil

        term.applyTheme()
        term.font = TerminalTheme.font(size: fontSize)

        // Ссылки: подчёркиваются под курсором и открываются обычным кликом, без Cmd.
        // По умолчанию SwiftTerm требует Cmd — а в терминале, где Claude сыплет ссылками
        // на файлы и доки, «нажал и ничего» читается как сломанная ссылка.
        term.linkHighlightMode = .hover

        // Мышь — НАМ, а не TUI. Это ключевая настройка, и вот почему.
        //
        // Claude Code включает mouse reporting, и SwiftTerm честно отдаёт ему всё: колесо уходит
        // в приложение событиями кнопок 4/5 (Claude их не обрабатывает — и терминал не скроллится
        // вовсе), а зажатая мышь — событиями клика (и текст невозможно выделить, то есть и
        // скопировать). Ровно на это и жаловались: «скролл — боль», «ничего не скопировать».
        //
        // Выключаем репортинг: колесо снова листает историю, а выделение работает обычным
        // перетаскиванием. Claude Code клавиатурный, мышь ему не нужна.
        //
        // В обычном терминале репортинг ОСТАЁТСЯ: там он нужен живым TUI (vim, htop, mc). Выделять
        // под ними можно с Shift — стандартное поведение Terminal.app и iTerm.
        term.allowMouseReporting = !side.isClaude

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        switch side {
        case .claude:
            // Логин-шелл: иначе не подхватится PATH из вашего профиля, и `claude`,
            // установленный в ~/.local/bin, не найдётся.
            term.startProcess(
                executable: shell,
                args: ["-l"],
                environment: Terminal.getEnvironmentVariables(termName: "xterm-256color") + localEnv,
                currentDirectory: localPath
            )

        case .remote:
            switch launch {
            case .ssh(let socket, let host, let args):
                let remote = "cd \(shq(remotePath)) 2>/dev/null; exec \"$SHELL\" -l"
                term.startProcess(
                    executable: "/usr/bin/ssh",
                    args: ["-t", "-S", socket, "-o", "ControlMaster=no"] + args + [host, remote],
                    environment: Terminal.getEnvironmentVariables(termName: "xterm-256color")
                )
            case .localShell:
                // Проект лежит на этом Mac — «терминал на сервере» это просто шелл в его папке.
                term.startProcess(
                    executable: shell,
                    args: ["-l"],
                    environment: Terminal.getEnvironmentVariables(termName: "xterm-256color"),
                    currentDirectory: remotePath
                )
            }
        }

        handle.register(term, for: side)
        return term
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        // Размер шрифта меняется на лету: пересоздавать терминал ради этого нельзя — вместе
        // с ним умрёт запущенный в нём Claude.
        if view.font.pointSize != fontSize {
            view.font = TerminalTheme.font(size: fontSize)
        }
    }

    static func dismantleNSView(_ view: LocalProcessTerminalView, coordinator: ()) {
        // SwiftTerm в deinit НАМЕРЕННО не убивает дочерний процесс — только terminate()
        // шлёт SIGTERM. Без этого закрытие вкладки полагалось бы на SIGHUP при закрытии
        // pty, а его процесс волен игнорировать (nohup, демоны) — и жил бы сиротой.
        view.process.terminate()
    }
}


/// Терминал, который принимает файлы.
///
/// Зачем: Claude умеет читать картинку по пути, но набирать этот путь руками — мучение.
/// Бросили скриншот в окно — путь подставился в строку ввода, дальше пишете вопрос словами.
/// Enter при этом НЕ нажимается: подставить путь и отправить запрос — разные решения.
final class DropTerminalView: LocalProcessTerminalView {

    /// Куда складывать картинки из буфера. Внутри рабочего каталога Claude — чтобы он
    /// до них дотянулся, и чтобы они не расползались по /tmp.
    var attachmentsDir: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    /// Красит терминал по ТЕКУЩЕЙ теме. Вызывается при создании и при каждой смене темы:
    /// цвета, взятые один раз при создании, оставляли тёмный терминал в посветлевшем окне —
    /// а пересоздать терминал нельзя, вместе с ним умер бы работающий в нём Claude.
    func applyTheme() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        nativeBackgroundColor = TerminalTheme.background(dark: dark)
        nativeForegroundColor = TerminalTheme.foreground(dark: dark)
        caretColor = TerminalTheme.caret(dark: dark)
        selectedTextBackgroundColor = TerminalTheme.selection(dark: dark)
        getTerminal().installPalette(colors: TerminalTheme.palette(dark: dark))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    // MARK: - Копирование и вставка
    //
    // SwiftTerm умеет copy/paste/selectAll, но НИКАК их не предлагает: контекстного меню у него
    // нет вовсе (правый клик не делает ничего), а горячие клавиши работают только если в меню
    // приложения есть стандартные пункты Правки, которых у нас не было. Итог — «из терминала
    // ничего не скопировать». Даём и меню, и клавиши.

    /// Правый клик — обычное меню, как в любом терминале.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        let copy = NSMenuItem(title: "Копировать", action: #selector(copy(_:)), keyEquivalent: "c")
        copy.target = self
        copy.isEnabled = selectionActive
        menu.addItem(copy)

        let paste = NSMenuItem(title: "Вставить", action: #selector(paste(_:)), keyEquivalent: "v")
        paste.target = self
        menu.addItem(paste)

        menu.addItem(.separator())

        let all = NSMenuItem(title: "Выделить всё", action: #selector(selectAll(_:)), keyEquivalent: "a")
        all.target = self
        menu.addItem(all)

        return menu
    }

    /// ⌘C / ⌘V / ⌘A. Через performKeyEquivalent, а не keyDown: до keyDown терминала эти сочетания
    /// доходят как обычный ввод и улетают в процесс — Ctrl+C он бы понял, а ⌘C просто пропал.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.option),
              !event.modifierFlags.contains(.control),
              let key = event.charactersIgnoringModifiers?.lowercased()
        else { return super.performKeyEquivalent(with: event) }

        switch key {
        case "c":
            // Без выделения ⌘C — не копирование: пусть уходит дальше по цепочке, как и был.
            guard selectionActive else { return super.performKeyEquivalent(with: event) }
            copy(self)
            return true
        case "v":
            paste(self)   // наш paste: картинка из буфера станет файлом и подставится путём
            return true
        case "a":
            selectAll(self)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard
            .readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }

        insert(paths: urls.map(\.path))
        return true
    }

    /// ⌘V со скриншотом в буфере. Claude Code для картинок просит Ctrl+V, потому что обычный
    /// терминал вставит вместо картинки мусор. Здесь терминал свой: картинку он сохраняет
    /// в файл и подставляет путь — то есть ⌘V делает ровно то, чего от него и ждут.
    override func paste(_ sender: Any) {
        if let dir = attachmentsDir, let file = saveClipboardImage(to: dir) {
            insert(paths: [file.path])
            return
        }
        super.paste(sender)
    }

    private func insert(paths: [String]) {
        let text = paths.map(shq).joined(separator: " ") + " "
        process.send(data: ArraySlice(Array(text.utf8)))
        window?.makeFirstResponder(self)
    }

    /// Картинка из буфера → PNG на диске. Имя со временем: вставок за сессию бывает много,
    /// и затирать предыдущую было бы неприятным сюрпризом.
    private func saveClipboardImage(to dir: URL) -> URL? {
        let pb = NSPasteboard.general
        guard let image = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage],
              let first = image.first,
              let tiff = first.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let file = dir.appendingPathComponent("снимок-\(stamp).png")

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: file)
        } catch {
            return nil
        }
        return file
    }
}
