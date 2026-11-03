import SwiftUI

/// A default subtitle renderer: centered lines near the bottom, sized relative to the video.
///
/// Apps that want their own look can render ``AVPlusPlayer/subtitleCues`` directly instead,
/// e.g. by passing a custom builder to ``AVPlusPlayerView``.
public struct SubtitleOverlay: View {
    private let cues: [SubtitleCue]
    private let relativeFontSize: CGFloat

    /// - Parameter relativeFontSize: Font size as a fraction of the video height.
    public init(cues: [SubtitleCue], relativeFontSize: CGFloat = 0.05) {
        self.cues = cues
        self.relativeFontSize = relativeFontSize
    }

    public var body: some View {
        GeometryReader { geometry in
            let fontSize = max(14, geometry.size.height * relativeFontSize)
            VStack(spacing: fontSize * 0.2) {
                ForEach(cues) { cue in
                    Text(cue.attributedText)
                        .font(.system(size: fontSize, weight: .medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black, radius: 2)
                        .padding(.horizontal, fontSize * 0.4)
                        .padding(.vertical, fontSize * 0.1)
                        .background(.black.opacity(0.45), in: .rect(cornerRadius: fontSize * 0.2))
                }
            }
            .frame(maxWidth: geometry.size.width * 0.9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, geometry.size.height * 0.06)
        }
        .accessibilityElement(children: .combine)
    }
}
