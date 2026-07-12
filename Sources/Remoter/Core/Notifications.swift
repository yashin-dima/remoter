import Foundation
import AppKit
import UserNotifications

/// Уведомления macOS: Claude закончил работу или просит разрешение.
///
/// Как это устроено. Claude Code умеет звать внешнюю команду на своих событиях (`Stop` — закончил
/// отвечать, `Notification` — просит разрешение). Мы кладём в папку проекта маленький скрипт,
/// а тот шлёт событие прямо в приложение — по локальному серверу, на котором и так живёт редактор.
///
/// Почему не osascript прямо из хука: уведомление тогда приходит от «Script Editor», без иконки
/// и без понимания, к какому проекту оно относится. А проектов открыто несколько.
@MainActor
enum Notifications {

    /// Ключ, под которым в уведомлении едет id проекта: по клику надо вернуться именно в него.
    /// nonisolated — его читает делегат центра уведомлений, а тот приходит не с главного актора.
    nonisolated static let workspaceKey = "workspace"

    /// Центр уведомлений живёт только внутри настоящего `.app`. В тестовом процессе главный
    /// бандл — это исполняемый файл xctest, и обращение к центру валит процесс исключением
    /// (проверять bundleIdentifier бесполезно: у xctest он есть).
    ///
    /// Поэтому трогаем центр только там, где он существует. Разбор события от этого не зависит
    /// и проверяется тестами; доставку проверяет `--selfcheck` в настоящем приложении.
    private static var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
    }

    private static var delegate: Delegate?

    /// Спрашиваем разрешение один раз при запуске. Откажут — уведомлений не будет, и об этом
    /// честно скажет панель Claude, а не «тишина непонятно почему».
    static func setUp() {
        guard let center else { return }
        let d = Delegate()
        delegate = d
        center.delegate = d
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func isAuthorized() async -> Bool {
        guard let center else { return false }
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    /// Событие от хука → уведомление на экране.
    static func handle(event: String, project64: String, id: String, payload: Data) {
        // Занятость сессии — не уведомление, а состояние: по нему в плашке появляется «Стоп».
        // Claude сообщает о ней теми же хуками: взялся за работу (Prompt) — закончил (Stop).
        let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        let session = json?["session_id"] as? String

        let model = UUID(uuidString: id).flatMap(WorkspaceModel.model(for:))
        if let model {
            switch event {
            case "Prompt": model.setBusy(true, session: session)
            case "Stop":   model.setBusy(false, session: session)
            default:       break
            }
        }
        guard event != "Prompt" else { return }

        guard let n = parse(event: event, project64: project64, id: id, payload: payload) else { return }

        // Два события могут прийти почти одновременно (закончил — и тут же ждёт ввода).
        // Показывать это дважды незачем.
        let key = n.title + "|" + n.subtitle + "|" + n.body
        if key == lastKey, Date().timeIntervalSince(lastAt) < dedupeWindow { return }
        lastKey = key
        lastAt = Date()

        post(n)

        // Бейдж на иконке в доке — если пользователь не смотрит на эту сессию прямо сейчас.
        // Смотрит — уведомление он и так видит, зажигать счётчик незачем.
        if model?.isViewingSession(session) != true {
            DockBadge.markUnseen(session)
        }
    }

    struct Note: Equatable {
        /// Проект — по нему сразу понятно, о каком окне речь.
        let title: String
        /// Название сессии: «Починить деплой». Иначе непонятно, какой из разговоров закончился.
        let subtitle: String
        let body: String
        /// Чей это проект. По клику надо попасть именно в его окно и именно на вкладку Claude,
        /// а не «куда-нибудь в приложение».
        let workspace: UUID?
        /// Закончил работу или ждёт ответа. Звук у этих двух разный — и это не украшение:
        /// «он ждёт меня» должно быть слышно, не отрываясь от другого окна.
        var kind: Kind = .done

        enum Kind { case done, ask }
    }

    /// Что пришло от хука → что показать. Отдельно от показа, чтобы это можно было проверить
    /// тестом: уведомление на экране тест увидеть не может, а вот текст — вполне.
    ///
    /// Имя проекта приезжает в base64: в нём бывают и пробелы, и кавычки, и кириллица, а тащить
    /// это через параметры URL значило бы ловить экранирование там, где его можно не иметь.
    static func parse(event: String, project64: String, id: String, payload: Data) -> Note? {
        let project = decode(project64) ?? "Claude"
        let payload: [String: Any] =
            (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]

        func field(_ name: String) -> String {
            (payload[name] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        // Название разговора Claude ведёт сам — берём его из журнала, путь к которому он же
        // и передал. Пока названия нет (сессия только началась), показываем первую фразу.
        let session = ClaudeSessions.title(ofJournal: field("transcript_path")) ?? ""

        let body: String
        let kind: Note.Kind
        switch event {
        case "Stop":
            // В хуке приезжает последняя реплика Claude — она куда полезнее, чем «закончил».
            let last = single(field("last_assistant_message"))
            body = last.isEmpty ? "Claude закончил работу" : last
            kind = .done
        case "Notification":
            let message = single(field("notification_message"))
            body = message.isEmpty ? "Claude ждёт вашего ответа" : message
            kind = .ask
        default:
            return nil
        }

        return Note(title: project, subtitle: session, body: body,
                    workspace: UUID(uuidString: id), kind: kind)
    }

    /// Реплика бывает в несколько абзацев — в уведомление всё равно влезет пара строк,
    /// и переводы строк там только съедают место.
    private static func single(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }



    /// Окно склейки одинаковых уведомлений: одно и то же дважды за это время не показываем.
    private static let dedupeWindow: TimeInterval = 3

    private static var lastKey = ""
    private static var lastAt = Date.distantPast

    private static func post(_ n: Note) {
        guard let center else { return }

        let content = UNMutableNotificationContent()
        content.title = n.title
        content.subtitle = n.subtitle
        content.body = n.body

        // Звук из настроек. macOS ищет его по имени файла — в бандле, в /System/Library/Sounds
        // и в ~/Library/Sounds; свой файл мы туда и кладём, иначе система его не найдёт.
        let sound = n.kind == .done ? AppSettings.shared.soundDone : AppSettings.shared.soundAsk
        content.sound = sound.fileName.map { UNNotificationSound(named: UNNotificationSoundName($0)) }

        if let id = n.workspace {
            content.userInfo = [Self.workspaceKey: id.uuidString]
        }

        center.add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil   // сразу
        ))
    }

    private static func decode(_ base64url: String?) -> String? {
        guard let base64url else { return nil }

        var s = base64url
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }

        guard let data = Data(base64Encoded: s) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Уведомление должно приходить ВСЕГДА — в том числе когда окно приложения на переднем плане.
    /// По умолчанию система такие проглатывает, считая, что пользователь и так всё видит.
    /// Здесь это не так: Claude может работать в одной вкладке, пока смотришь diff в другой.
    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .sound])
        }

        /// Кликнули по уведомлению — открываем ТОТ проект и ТУ вкладку, откуда оно пришло.
        /// Просто вывести приложение вперёд мало: окон несколько, и попасть можно не в то.
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            let info = response.notification.request.content.userInfo
            let id = (info[Notifications.workspaceKey] as? String).flatMap(UUID.init(uuidString:))

            Task { @MainActor in
                // Проект мог быть закрыт, пока уведомление висело. Тогда открывать нечего —
                // и выдёргивать пользователя в пустоту незачем.
                if let id, WorkspaceModel.reveal(id) { return }
                NSApp.activate(ignoringOtherApps: true)
            }
            completionHandler()
        }
    }
}
