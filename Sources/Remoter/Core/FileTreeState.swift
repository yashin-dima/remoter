import Foundation

/// Строка дерева файлов, уже развёрнутого в плоский список — так проще и быстрее рисовать,
/// чем гонять рекурсивные View, и мы полностью управляем подсветкой и отступами.
struct TreeRow: Identifiable, Hashable {
    var entry: RemoteEntry
    var depth: Int
    var isExpanded: Bool
    var isLoading: Bool

    var id: String { entry.path }
}

/// Состояние одного дерева файлов: что загружено, что раскрыто, что грузится.
///
/// В окне таких дерева ДВА — серверное и локальная папка проекта, — и раньше вся эта логика
/// существовала в двух дословных копиях (`children`/`localChildren`, `rebuildRows`/
/// `rebuildLocalRows`…). Здесь она в одном экземпляре; деревья различаются только тем,
/// откуда берут детей каталога — по ssh или с диска, — и это остаётся снаружи.
struct FileTreeState {
    /// Дети каждого загруженного каталога.
    var children: [String: [RemoteEntry]] = [:]
    /// Раскрытые каталоги.
    var expanded: Set<String> = []
    /// Каталоги, которые грузятся прямо сейчас, — у локального дерева всегда пусто:
    /// диск читается синхронно, спиннер не успел бы показаться.
    var loading: Set<String> = []

    /// Переключает раскрытие каталога.
    /// Возвращает путь, который нужно ДОГРУЗИТЬ: каталог раскрыли, а детей у него ещё нет.
    mutating func toggle(_ entry: RemoteEntry) -> String? {
        guard entry.isDir else { return nil }
        if expanded.contains(entry.path) {
            expanded.remove(entry.path)
            return nil
        }
        expanded.insert(entry.path)
        return children[entry.path] == nil ? entry.path : nil
    }

    /// Дерево, развёрнутое в плоский список от корня — то, что рисует панель.
    func rows(from root: String) -> [TreeRow] {
        var out: [TreeRow] = []
        func walk(_ dir: String, depth: Int) {
            for e in children[dir] ?? [] {
                let isExp = expanded.contains(e.path)
                out.append(TreeRow(
                    entry: e, depth: depth,
                    isExpanded: isExp,
                    isLoading: loading.contains(e.path)
                ))
                if e.isDir && isExp { walk(e.path, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        return out
    }
}
