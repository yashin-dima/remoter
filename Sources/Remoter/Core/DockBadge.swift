import AppKit

/// Красный бейдж на иконке в доке — сколько сессий ждут внимания.
///
/// Считаем не сами уведомления, а СЕССИИ, от которых пришло что-то непросмотренное: два
/// «Claude закончил» из одного разговора — это один повод заглянуть, а не два. Ключ — id сессии
/// (он глобально уникален), поэтому бейдж общий на все окна: неважно, в каком проекте ждёт ответа
/// Claude, — цифра на иконке одна.
///
/// Просмотром считается факт открытия: как только смотришь на вкладку этой сессии в активном
/// окне, её метка снимается (см. WorkspaceModel.markActiveSessionSeen).
@MainActor
enum DockBadge {
    private static var unseen: Set<String> = []

    /// Пришло уведомление от сессии — если её ещё не «видели», бейдж растёт.
    static func markUnseen(_ session: String?) {
        guard let session, !session.isEmpty else { return }
        if unseen.insert(session).inserted { refresh() }
    }

    /// Сессию открыли/просмотрели — снимаем её вклад в бейдж.
    static func markSeen(_ session: String?) {
        guard let session, !session.isEmpty else { return }
        if unseen.remove(session) != nil { refresh() }
    }

    private static func refresh() {
        // Пустая строка убрала бы бейдж не всегда надёжно — именно nil гасит его начисто.
        NSApp.dockTile.badgeLabel = unseen.isEmpty ? nil : String(unseen.count)
    }
}
