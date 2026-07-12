import SwiftUI
import WebKit

/// Правая часть окна: шапка с именем файла и счётчиком строк, под ней — Monaco.
struct EditorPane: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            MonacoView(bridge: model.monaco)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let doc = model.doc {
                // Имя файла показывает вкладка — здесь только путь и то, что о файле важно знать.
                if let rel = doc.relPath {
                    Text(rel)
                        .font(.system(size: D.s(11), design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                } else {
                    Text(doc.absPath)
                        .font(.system(size: D.s(11), design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                if doc.conflict {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: D.s(10)))
                        .foregroundStyle(Theme.modified)
                        // Файл проекта на этом Mac меняет не сервер, а Claude или соседний
                        // редактор — «на сервере» звучало бы как сбой приложения.
                        .help(model.workspace.isLocal || doc.isLocal
                              ? "Файл изменился на диске, пока вы его правили"
                              : "Файл изменился на сервере, пока вы его правили")
                }
                if let reason = doc.readOnlyReason {
                    Label("только чтение", systemImage: "lock.fill")
                        .font(.system(size: D.s(10)))
                        .foregroundStyle(Theme.secondary)
                        .help(reason)
                }

                if doc.mode == .diff, doc.added + doc.removed > 0 {
                    HStack(spacing: 4) {
                        Text("+\(doc.added)").foregroundStyle(Theme.added)
                        Text("−\(doc.removed)").foregroundStyle(Theme.removed)
                    }
                    .font(.system(size: D.s(11), weight: .medium, design: .monospaced))
                }
            } else {
                Text("Файл не выбран")
                    .font(.system(size: D.s(12)))
                    .foregroundStyle(Theme.secondary)
            }

            Spacer()

            if model.doc?.mode == .diff {
                Picker("", selection: $model.diffBase) {
                    ForEach(DiffBase.allCases) { b in Text(b.title).tag(b) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                .help("С чем сравнивать рабочую копию")

                Button {
                    model.sideBySide.toggle()
                } label: {
                    Image(systemName: model.sideBySide ? "rectangle.split.2x1" : "rectangle")
                }
                .help(model.sideBySide ? "В одну колонку (⇧⌘D)" : "В две колонки (⇧⌘D)")
            }

            if model.doc?.isDirty == true {
                // Без .keyboardShortcut: ⌘S уже живёт в меню (WorkspaceCommands) — второй
                // обработчик того же сочетания в том же окне это конфликт, а не удобство.
                Button("Сохранить") { model.requestSave() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(height: D.s(36))
    }
}

/// Обёртка над WKWebView. WebView живёт в модели, поэтому переключение файлов
/// не пересоздаёт его и Monaco не грузится заново.
struct MonacoView: NSViewRepresentable {
    let bridge: MonacoBridge

    func makeNSView(context: Context) -> WKWebView { bridge.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
