import CryptoKit
import Foundation

/// File-based storage for subtitles that belong to a piece of media, such as generated
/// transcripts.
///
/// Entries are keyed by the media's identity: path, size and modification date for local files, the
/// URL for remote media. Replacing a file therefore invalidates its entries. Each media can hold
/// several entries, told apart by a `variant` such as `"generated-en_US-audio0"`.
///
/// - ``cache`` lives in the caches directory, which the system may purge. Generated transcripts go
///   here by default.
/// - ``persistent`` lives in Application Support and is kept until you remove it.
public final class SubtitleStore: Sendable {
    public struct Entry: Codable, Sendable, Identifiable, Hashable {
        /// Distinguishes the entries of one media.
        public var variant: String
        public var title: String?
        public var language: String?
        public var isGenerated: Bool
        public var createdAt: Date
        public var document: SubtitleDocument

        public var id: String { variant }

        public init(
            variant: String,
            title: String? = nil,
            language: String? = nil,
            isGenerated: Bool = false,
            createdAt: Date = Date(),
            document: SubtitleDocument
        ) {
            self.variant = variant
            self.title = title
            self.language = language
            self.isGenerated = isGenerated
            self.createdAt = createdAt
            self.document = document
        }
    }

    public let directory: URL

    /// Purgeable storage, used by default for generated subtitles.
    public static let cache = SubtitleStore(
        directory: URL.cachesDirectory.appending(path: "AVPlus/Subtitles", directoryHint: .isDirectory)
    )

    /// Storage that survives cache purges, for transcripts the user wants to keep.
    public static let persistent = SubtitleStore(
        directory: URL.applicationSupportDirectory.appending(path: "AVPlus/Subtitles", directoryHint: .isDirectory)
    )

    public init(directory: URL) {
        self.directory = directory
    }

    /// The variant name used for generated transcripts.
    public static func generatedVariant(locale: Locale, audioTrackIndex: Int?) -> String {
        "generated-\(locale.identifier)-audio\(audioTrackIndex ?? 0)"
    }

    public func entry(for mediaURL: URL, variant: String) -> Entry? {
        guard let data = try? Data(contentsOf: fileURL(for: mediaURL, variant: variant)) else { return nil }
        return try? Self.decoder.decode(Entry.self, from: data)
    }

    /// All entries stored for `mediaURL`, oldest first.
    public func entries(for mediaURL: URL) -> [Entry] {
        let folder = mediaDirectory(for: mediaURL)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? Self.decoder.decode(Entry.self, from: $0) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func save(_ entry: Entry, for mediaURL: URL) throws {
        let file = fileURL(for: mediaURL, variant: entry.variant)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(entry).write(to: file, options: .atomic)
    }

    public func removeEntry(for mediaURL: URL, variant: String) {
        try? FileManager.default.removeItem(at: fileURL(for: mediaURL, variant: variant))
    }

    public func removeEntries(for mediaURL: URL) {
        try? FileManager.default.removeItem(at: mediaDirectory(for: mediaURL))
    }

    public func removeAll() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Layout

    private func mediaDirectory(for mediaURL: URL) -> URL {
        directory.appending(path: Self.hash(Self.identity(of: mediaURL)), directoryHint: .isDirectory)
    }

    private func fileURL(for mediaURL: URL, variant: String) -> URL {
        mediaDirectory(for: mediaURL).appending(path: "\(Self.hash(variant)).json")
    }

    /// Path + size + modification date for files, so edited media do not reuse stale subtitles.
    static func identity(of url: URL) -> String {
        guard url.isFileURL else { return url.absoluteString }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(path)|\(size)|\(modified)"
    }

    private static func hash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
