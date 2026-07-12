import SwiftUI
import AppKit

/// ⌘P — быстрый переход к файлу. Индекс берём из `git ls-files`, поэтому в него не попадает
/// мусор вроде node_modules: git и так знает, что относится к проекту.
struct QuickOpenView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private var matches: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(model.quickOpenFiles.prefix(50)) }
        return Array(
            model.quickOpenFiles
                .compactMap { path -> (String, Int)? in
                    guard let score = fuzzyScore(path.lowercased(), q) else { return nil }
                    return (path, score)
                }
                .sorted { $0.1 == $1.1 ? $0.0.count < $1.0.count : $0.1 > $1.1 }
                .prefix(50)
                .map(\.0)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Имя файла…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: D.s(15)))
                .padding(12)
                .focused($focused)
                .onChange(of: query) { _, _ in selection = 0 }
                .onSubmit(open)

            Divider()

            if matches.isEmpty {
                Text(model.quickOpenFiles.isEmpty ? "Индекс файлов ещё строится…" : "Ничего не найдено")
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, minHeight: D.s(120))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.element) { i, path in
                                row(path, index: i)
                                    .id(i)
                            }
                        }
                    }
                    .onChange(of: selection) { _, new in
                        withAnimation(.linear(duration: 0.08)) { proxy.scrollTo(new, anchor: .center) }
                    }
                }
                .frame(height: D.s(320))
            }
        }
        .frame(width: D.s(620))
        .onAppear { focused = true }
        .onExitCommand { dismiss() }
        // Стрелки нужно перехватить до TextField, иначе они будут гулять по тексту, а не по списку.
        .background(KeyCatcher(
            onUp: { selection = max(0, selection - 1) },
            onDown: { selection = min(matches.count - 1, selection + 1) }
        ))
    }

    private func row(_ path: String, index: Int) -> some View {
        let name = (path as NSString).lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent
        let kind = model.kindByPath[path]

        return HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: D.s(11)))
                .foregroundStyle(Theme.secondary)
            Text(name).font(.system(size: D.s(13)))
            Text(dir)
                .font(.system(size: D.s(11)))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            if let kind {
                Text(kind.letter)
                    .font(D.Text.badge)
                    .foregroundStyle(kind.color)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(index == selection ? Theme.selection : .clear)
        .contentShape(Rectangle())
        .onTapGesture { selection = index; open() }
    }

    private func open() {
        guard selection < matches.count else { return }
        let path = matches[selection]
        dismiss()
        Task { await model.openQuick(path) }
    }
}

/// Подпоследовательность с бонусом за совпадения подряд и за начало сегмента пути —
/// ровно то поведение, к которому приучил ⌘P в редакторах.
private func fuzzyScore(_ haystack: String, _ needle: String) -> Int? {
    let h = Array(haystack), n = Array(needle)
    var hi = 0, ni = 0, score = 0, streak = 0

    while hi < h.count && ni < n.count {
        if h[hi] == n[ni] {
            score += 1 + streak
            if hi == 0 || h[hi - 1] == "/" || h[hi - 1] == "." || h[hi - 1] == "_" || h[hi - 1] == "-" {
                score += 4
            }
            streak += 1
            ni += 1
        } else {
            streak = 0
        }
        hi += 1
    }
    return ni == n.count ? score : nil
}

/// Ловит ↑/↓ на уровне СВОЕГО окна — SwiftUI-полю их не отдаём.
private struct KeyCatcher: NSViewRepresentable {
    let onUp: () -> Void
    let onDown: () -> Void

    private enum KeyCode {
        static let up: UInt16 = 126
        static let down: UInt16 = 125
    }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak v] event in
            // Локальный монитор слышит клавиши всего приложения. Без проверки окна стрелки
            // глотались бы и в соседних окнах проектов: открыт ⌘P в одном — в другом
            // перестают работать стрелки (например, в меню Claude в терминале).
            guard let v, event.window === v.window else { return event }
            switch event.keyCode {
            case KeyCode.up: onUp(); return nil
            case KeyCode.down: onDown(); return nil
            default: return event
            }
        }
        return v
    }

    func updateNSView(_ view: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var monitor: Any?
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
