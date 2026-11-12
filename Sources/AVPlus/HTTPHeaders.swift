import AVFoundation

/// Request headers for media loaded over HTTP, in the forms AVFoundation, mpv and FFmpeg take them.
///
/// All three have a dedicated setting for `User-Agent` and (mpv, FFmpeg) `Referer`; passing those as
/// plain header fields as well would send them twice, so they are split off.
struct HTTPHeaders: Sendable {
    let fields: [String: String]

    init(_ fields: [String: String]) {
        self.fields = fields
    }

    var isEmpty: Bool { fields.isEmpty }

    /// Header names are case-insensitive.
    private func value(_ name: String) -> String? {
        fields.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var userAgent: String? { value("User-Agent") }
    var referer: String? { value("Referer") }

    /// Every field except `User-Agent` and `Referer`, in a stable order.
    var others: [(name: String, value: String)] {
        fields
            .filter { $0.key.caseInsensitiveCompare("User-Agent") != .orderedSame && $0.key.caseInsensitiveCompare("Referer") != .orderedSame }
            .sorted { $0.key < $1.key }
            .map { (name: $0.key, value: $0.value) }
    }

    /// Options for `AVURLAsset`. AVFoundation applies the fields to playlist, segment and key requests.
    var assetOptions: [String: Any]? {
        guard !isEmpty else { return nil }
        var options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": fields]
        if let userAgent { options[AVURLAssetHTTPUserAgentKey] = userAgent }
        return options
    }
}
