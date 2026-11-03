import AVFoundation
import SwiftUI

#if canImport(UIKit)
import UIKit

/// Hosts the engine-owned mpv layer. The layer can move between host views without
/// recreating the mpv instance.
final class MPVHostView: UIView {
    var videoLayer: MPVMetalLayer? {
        didSet {
            guard videoLayer !== oldValue else { return }
            if oldValue?.superlayer === layer { oldValue?.removeFromSuperlayer() }
            if let videoLayer { layer.addSublayer(videoLayer) }
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .black
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        videoLayer?.update(bounds: bounds, scale: traitCollection.displayScale)
    }
}

struct MPVVideoSurface: UIViewRepresentable {
    let videoLayer: MPVMetalLayer

    func makeUIView(context: Context) -> MPVHostView {
        let view = MPVHostView()
        view.videoLayer = videoLayer
        return view
    }

    func updateUIView(_ view: MPVHostView, context: Context) {
        view.videoLayer = videoLayer
    }
}

final class AVPlayerLayerHostView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// A bare `AVPlayerLayer`, for apps that draw their own controls.
struct AVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> AVPlayerLayerHostView {
        let view = AVPlayerLayerHostView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: AVPlayerLayerHostView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

#elseif canImport(AppKit)
import AppKit

final class MPVHostView: NSView {
    var videoLayer: MPVMetalLayer? {
        didSet {
            guard videoLayer !== oldValue else { return }
            if oldValue?.superlayer === layer { oldValue?.removeFromSuperlayer() }
            if let videoLayer { layer?.addSublayer(videoLayer) }
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        videoLayer?.update(bounds: bounds, scale: scale)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
}

struct MPVVideoSurface: NSViewRepresentable {
    let videoLayer: MPVMetalLayer

    func makeNSView(context: Context) -> MPVHostView {
        let view = MPVHostView()
        view.videoLayer = videoLayer
        return view
    }

    func updateNSView(_ view: MPVHostView, context: Context) {
        view.videoLayer = videoLayer
    }
}

final class AVPlayerLayerHostView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = playerLayer
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// A bare `AVPlayerLayer`, for apps that draw their own controls.
struct AVPlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerLayerHostView {
        let view = AVPlayerLayerHostView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerLayerHostView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}
#endif
