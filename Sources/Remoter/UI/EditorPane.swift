import SwiftUI
import WebKit

/// Правая часть окна: шапка с именем файла и счётчиком строк, под ней — Monaco.
struct EditorPane: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                // Monaco смонтирован всегда: пересоздание WebView — это повторная загрузка
                // редактора. Картинка просто рисуется ПОВЕРХ, когда вкладка — про неё.
                MonacoView(bridge: model.monaco)

                if let doc = model.doc, doc.mode == .image {
                    ImageViewer(data: doc.imageData, title: doc.title)
                        .background(Theme.surface)
                }
            }
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

/// Просмотр картинки во вкладке редактора.
///
/// Скриншоты и ассеты — обычные жители репозитория, и «бинарный файл, показать нечего»
/// на клик по ним — не ответ. Картинка вписывается в окно; фактический размер — в подписи.
struct ImageViewer: View {
    let data: Data?
    let title: String

    var body: some View {
        if let data, let image = NSImage(data: data) {
            VStack(spacing: 8) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)

                // Размер в пикселях честнее, чем в точках: у ретины они различаются вдвое,
                // а человеку важно, какого размера сам файл.
                Text("\(pixelSize(image)) · \(byteString(data.count))")
                    .font(D.Text.caption)
                    .foregroundStyle(Theme.secondary)
                    .padding(.bottom, 10)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "photo")
                    .font(.system(size: D.s(34), weight: .light))
                    .foregroundStyle(.tertiary)
                Text("\(title) — не удалось показать картинку")
                    .font(D.Text.caption)
                    .foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func pixelSize(_ image: NSImage) -> String {
        guard let rep = image.representations.first else { return "?" }
        return "\(rep.pixelsWide) × \(rep.pixelsHigh)"
    }
}
