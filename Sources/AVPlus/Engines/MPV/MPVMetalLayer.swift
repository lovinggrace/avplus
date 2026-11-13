import Foundation
import QuartzCore

/// The layer mpv renders into through MoltenVK (`vo=gpu-next`, `gpu-api=vulkan`).
///
/// Workarounds taken from MPVKit's demo:
/// - MoltenVK sets `drawableSize` to 1x1 to force-complete a presentation, which flickers and
///   can leave the drawable stuck at 1x1 (https://github.com/mpv-player/mpv/pull/13651).
/// - `wantsExtendedDynamicRangeContent` only activates EDR when set on the main thread, while mpv
///   sets it from its render thread. (The property does not exist on tvOS.)
///
/// It is `@unchecked Sendable` because mpv's render thread drives it by design.
final class MPVMetalLayer: CAMetalLayer, @unchecked Sendable {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1, Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    #if !os(tvOS)
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                // The compiler flags this as unnecessary but rejects the capture without it.
                nonisolated(unsafe) let layer = self
                DispatchQueue.main.sync {
                    layer.setSuperWantsExtendedDynamicRangeContent(newValue)
                }
            }
        }
    }

    private func setSuperWantsExtendedDynamicRangeContent(_ value: Bool) {
        super.wantsExtendedDynamicRangeContent = value
    }
    #endif

    override init() {
        super.init()
        framebufferOnly = true
        backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Called on the main thread after `update` gave the drawable a different size.
    var onResize: (@MainActor () -> Void)?

    /// Resizes the layer and its drawable without implicit animations.
    @MainActor
    func update(bounds: CGRect, scale: CGFloat) {
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let changed = size != drawableSize && size.width > 1 && size.height > 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = bounds
        contentsScale = scale
        drawableSize = size
        CATransaction.commit()
        if changed { onResize?() }
    }
}
