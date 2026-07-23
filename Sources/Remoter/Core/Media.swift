import Foundation

/// Чем файл является для человека: картинкой, видео, звуком — или просто файлом.
///
/// По расширению, и это осознанно: нюхать байты пришлось бы С СЕРВЕРА (лишний круг по ssh
/// до того, как вообще решили, как файл открывать), а расширение уже есть в пути. Ошибка
/// стоит немного: файл с чужим расширением просто откроется не тем способом, и это видно.
enum MediaKind {
    case image, video, audio

    private static let images: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic", "heif", "ico", "icns",
    ]
    private static let videos: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "mpg", "mpeg",
    ]
    private static let audios: Set<String> = [
        "mp3", "wav", "m4a", "aac", "flac", "ogg", "aiff", "aif", "opus",
    ]

    init?(path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        if Self.images.contains(ext) { self = .image }
        else if Self.videos.contains(ext) { self = .video }
        else if Self.audios.contains(ext) { self = .audio }
        else { return nil }
    }

    var title: String {
        switch self {
        case .image: return "картинка"
        case .video: return "видео"
        case .audio: return "аудио"
        }
    }
}
