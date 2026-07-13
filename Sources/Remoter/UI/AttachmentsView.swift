import SwiftUI
import AppKit

/// Картинки разговора: то, что вы показывали Claude и чего не видно в терминале.
///
/// Разбор журнала — не на главном потоке и по требованию: у долгой сессии он весит десятки
/// мегабайт, а картинки в нём лежат в base64.
struct AttachmentsView: View {
    @ObservedObject var model: WorkspaceModel
    let tab: ClaudeTab
    @Environment(\.dismiss) private var dismiss

    @State private var items: [ClaudeAttachments.Item] = []
    @State private var isLoading = true

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isLoading {
                loading
            } else if items.isEmpty {
                empty
            } else {
                grid
            }

            Divider()
            footer
        }
        .frame(width: D.s(640), height: D.s(520))
        .task {
            items = await model.attachments(of: tab)
            isLoading = false
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: D.s(16), weight: .medium))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("Картинки в разговоре")
                    .font(.system(size: D.s(15), weight: .semibold))
                Text(tab.shownTitle)
                    .font(D.Text.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(items) { item in
                    Image(nsImage: item.image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(height: D.s(140))
                        .frame(maxWidth: .infinity)
                        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { open(item) }
                        .help("Открыть в «Просмотре»")
                        .contextMenu {
                            Button("Открыть") { open(item) }
                            Button("Скопировать") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.writeObjects([item.image])
                            }
                        }
                }
            }
            .padding(12)
        }
    }

    private var loading: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Читаю журнал…")
                .font(D.Text.caption)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo")
                .font(.system(size: D.s(34), weight: .light))
                .foregroundStyle(.tertiary)
            Text("Картинок в этом разговоре нет")
                .font(D.Text.title)
            Text("Бросьте скриншот в окно терминала или вставьте его ⌘V — путь подставится "
                 + "в запрос, а картинка появится здесь.")
                .font(D.Text.caption)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("Картинки лежат в журнале Claude. Приложение его только читает.")
                .font(D.Text.caption)
                .foregroundStyle(Theme.secondary)
            Spacer()
            Button("Закрыть") { dismiss() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Открыть в «Просмотре». Пишем во временный файл: своего просмотрщика заводить незачем —
    /// системный умеет всё, чего от него ждут (зум, поворот, «поделиться»).
    private func open(_ item: ClaudeAttachments.Item) {
        guard let tiff = item.image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("remoter-\(item.id.uuidString.prefix(8)).png")
        do {
            try png.write(to: file)
            NSWorkspace.shared.open(file)
        } catch {
            model.toast(.error, "Не удалось открыть картинку: \(error.localizedDescription)")
        }
    }
}
