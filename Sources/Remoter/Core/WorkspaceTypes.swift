import Foundation

// Типы окна проекта: что открыто в редакторе, какие бывают вкладки и панели.
// Сам WorkspaceModel живёт в WorkspaceModel.swift и файлах WorkspaceModel+*.swift.

/// Что сейчас открыто в редакторе.
struct OpenDoc: Equatable {
    enum Mode: Equatable { case view, diff }

    var mode: Mode
    var title: String
    /// Абсолютный путь на сервере.
    var absPath: String
    /// Путь относительно корня репозитория (если файл вообще в репозитории).
    var relPath: String?
    var kind: ChangeKind?
    /// Левая сторона diff'а — версия из HEAD или индекса.
    var original: String = ""
    /// Текст, который лежит на сервере прямо сейчас. По нему ловим правки Claude и конфликты.
    var baseline: String = ""
    /// Контрольная сумма серверной версии. По ней поллинг отличает «файл поменяли на сервере»
    /// от «ничего не произошло», не перекачивая файл целиком. Своя у каждой вкладки: одна общая
    /// на всё окно давала ложное «файл изменился» при каждом переключении вкладок.
    var checksum: String?
    var editable: Bool = false
    var isDirty: Bool = false
    /// Файл изменился на сервере, пока у нас были несохранённые правки.
    var conflict: Bool = false
    var added: Int = 0
    var removed: Int = 0
    /// Заполнено, если править нельзя — показываем причину, а не молча запрещаем ввод.
    var readOnlyReason: String?
    /// Файл лежит на Mac, а не на сервере: сохраняется на диск, поллингом не трогается.
    var isLocal: Bool = false

    /// Вкладка-предпросмотр: открыта одним кликом и будет заменена следующим таким же.
    ///
    /// Так устроен VS Code, и не от лени: просматривая diff, за минуту прощёлкиваешь два десятка
    /// файлов — и все двадцать оставались бы висеть в ряду вкладок. Стоит начать с файлом
    /// работать (двойной клик, правка) — вкладка становится постоянной.
    var isPreview: Bool = false
}

enum DiffBase: String, CaseIterable, Identifiable {
    case head, index
    var id: String { rawValue }
    var title: String { self == .head ? "vs HEAD" : "vs Индекс" }
    /// `git show HEAD:path` против `git show :path` — пустая ревизия и есть индекс.
    var rev: String { self == .head ? "HEAD" : "" }
}

/// Открытая сессия Claude — вкладка со своим терминалом, своим процессом и своими параметрами.
///
/// Параметры запуска (`model`, `effort`, `permissions`) неизменны: с чем сессию запустили, с тем
/// она и запустилась, и переписывать их задним числом нельзя — команда уже ушла в терминал.
///
/// Но внутри работающего Claude их МЕНЯЮТ: `/model`, `/effort`, shift+tab. Поэтому рядом лежит
/// `live` — то, что происходит на самом деле, вычитанное из журнала Claude. Показывать надо его,
/// а флаги запуска — только пока журнал ещё ничего не сказал.
struct ClaudeTab: Identifiable, Equatable {
    let id: UUID
    var title: String
    let model: ClaudeModel
    let effort: ClaudeEffort
    let permissions: ClaudePermissions
    /// Запущена ли сессия с контекстом в миллион токенов (`--model opus[1m]`).
    let longContext: Bool
    /// Продолжённый разговор, если сессия открыта из списка прошлых.
    let resumed: String?

    /// Что у сессии на самом деле. Пусто, пока Claude не написал первую строку журнала.
    var live = ClaudeLive()

    /// Claude сейчас работает — значит, его есть чем остановить.
    /// Ставится по его же хукам: начал отвечать / закончил.
    var isBusy = false

    /// Название, которое пользователь задал вкладке руками. Приоритетнее того, что Claude
    /// придумывает сам (`live.title`): своё имя человек ставит осознанно, и затирать его
    /// автоматическим было бы неправильно.
    var customTitle: String?

    /// Включён ли для этой сессии remote-control — управление с телефона/браузера через
    /// приложение Claude (и push-уведомления через него же). Состояние наше, оптимистичное:
    /// надёжного способа прочитать его из журнала нет, поэтому знаем ровно то, что сами включали.
    /// Начальное — как в настройках Claude Code (`remoteControlAtStartup`).
    var remoteControl = ClaudeConfig.remoteControlAtStartup

    var terminal: TerminalID { .claude(id) }

    /// Что показать на вкладке: заданное человеком имя приоритетнее всего.
    var shownTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        return title
    }

    /// Что показывать в плашке: правду из журнала, а пока её нет — то, с чем запускали.
    ///
    /// Сессия могла ничего не задавать и взять настройки Claude — тогда до первого его ответа
    /// показываем то, что стоит у него в настройках. Написать «Как в Claude» значило бы
    /// ответить на вопрос «какая модель?» словами «та, которая настроена».
    var shownModel: String {
        if let live = live.model { return live }
        guard model == .inherit else { return model.title }
        return ClaudeConfig.model.map(ClaudeJournal.modelName(fromID:)) ?? "Claude"
    }

    var shownEffort: ClaudeEffort {
        if let live = live.effort { return live }
        guard effort == .inherit else { return effort }
        return ClaudeConfig.effort.flatMap(ClaudeEffort.init(rawValue:)) ?? .inherit
    }

    var shownPermissions: ClaudePermissions { live.permissions ?? permissions }

    /// Алиас модели, с которым сессия реально работает. Из него и берётся размер окна.
    ///
    /// Приоритет у журнала: `/model opus[1m]`, набранный внутри сессии, — это и есть текущее
    /// состояние, а флаг запуска и настройки Claude лишь говорят, с чего она начиналась.
    var alias: String {
        live.modelAlias ?? model.alias(longContext: longContext) ?? ClaudeConfig.model ?? ""
    }

    /// Размер контекстного окна.
    ///
    /// Числом его не отдаёт никто: в журнал Claude его не пишет, а `/context` рисует картинку
    /// в терминале и наружу ничего не возвращает. Поэтому смотрим на алиас — `[1m]` означает
    /// миллион, иначе 200k, — и подстраховываемся наблюдением: если занято больше, чем мы считали
    /// пределом, значит окно на самом деле длинное, и врать про «переполнено» мы не станем.
    var contextWindow: Int {
        let declared = ClaudeConfig.window(alias: alias)
        guard let used = live.contextTokens, used > declared else { return declared }
        return ClaudeConfig.longWindow
    }

    /// Доля занятого контекста: 0…1. Пусто, пока Claude не ответил ни разу.
    var contextFill: Double? {
        guard let used = live.contextTokens else { return nil }
        return min(Double(used) / Double(contextWindow), 1)
    }
}

/// Открытый терминал на сервере — вкладка со своим ssh.
///
/// Их может быть несколько по той же причине, что и сессий Claude: пока в одном крутится хвост
/// лога, во втором работают руками. Постоянной вкладки «Сервер» больше нет — терминал появляется,
/// когда он нужен, и закрывается, когда не нужен.
struct ShellTab: Identifiable, Equatable {
    let id: UUID
    var title: String

    var terminal: TerminalID { .remote(id) }
}

/// Вкладки основной области окна.
enum Pane: Hashable {
    /// Разговор с Claude. Их может быть несколько — по вкладке на каждый.
    case claude(UUID)
    /// Терминал на сервере. Тоже вкладка, тоже не одна.
    case remote(UUID)
    case file

    var terminal: TerminalID? {
        switch self {
        case .claude(let id): return .claude(id)
        case .remote(let id): return .remote(id)
        case .file:           return nil
        }
    }
}

enum SidebarTab: String, CaseIterable {
    /// Что тронуто на сервере.
    case changes
    /// Дерево проекта на сервере.
    case files
    /// Локальная папка проекта на Mac: доки, заметки, инструкция для Claude, конфиг доступа.
    /// Сервер про Claude ничего не знает и знать не должен — всё это живёт у нас.
    case local

    // Раздела «Terminal» здесь больше нет. Он ничего не показывал — только открывал: сам терминал
    // живёт вкладкой во весь экран. Список открытых дублировал ряд вкладок, а кнопка «Новый» —
    // единственное, ради чего в раздел заходили, — переехала в тулбар, к плюсу.

    var title: String {
        switch self {
        case .changes: return "Git"
        case .files:   return "Remote"
        case .local:   return "Local"
        }
    }

    var icon: String {
        switch self {
        case .changes: return "arrow.triangle.branch"
        case .files:   return "server.rack"
        case .local:   return "laptopcomputer"
        }
    }
}

extension Array {
    /// Индекс, который не роняет приложение на выходе за границы — при закрытии вкладок
    /// «соседняя» вполне может не существовать.
    subscript(safe i: Int) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}

func byteString(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
