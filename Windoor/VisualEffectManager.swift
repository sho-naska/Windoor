import Cocoa

enum InteractionMode {
    case move
    case resize
    case error // エラー（リサイズ不可）用
    case none
}

class VisualEffectManager {
    static let shared = VisualEffectManager()
    
    private var overlayWindow: NSWindow?
    private var lastCocoaFrame: CGRect?
    
    // 現代のmacOS (Big Sur以降) の標準的な角丸サイズに近い値
    private let cornerRadius: CGFloat = 12.0
    
    // 【修正】枠線の太さを細くしました (4.0 -> 2.0)
    private let strokeWidth: CGFloat = 2.0
    
    private init() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.alphaValue = 0.0
        
        // 座標系変換のための設定
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        self.overlayWindow = window
    }
    
    // エフェクトを表示開始
    func showEffect(frame: CGRect, mode: InteractionMode) {
        guard let window = overlayWindow else { return }
        
        let cocoaFrame = convertToCocoaFrame(frame)
        
        let color: NSColor
        let borderWidth: CGFloat
        
        switch mode {
        case .move:
            color = NSColor.systemBlue
            borderWidth = strokeWidth
        case .resize:
            color = NSColor.systemOrange
            borderWidth = strokeWidth
        case .error:
            color = NSColor.systemRed
            borderWidth = strokeWidth + 2.0 // エラー時は少し太く強調
        default:
            return
        }
        
        let viewRect = CGRect(origin: .zero, size: cocoaFrame.size)
        let frameView = NSView(frame: viewRect)
        frameView.wantsLayer = true
        frameView.autoresizingMask = [.width, .height]
        frameView.layer?.borderWidth = borderWidth
        frameView.layer?.borderColor = color.cgColor
        frameView.layer?.cornerRadius = cornerRadius
        
        window.contentView = frameView
        lastCocoaFrame = cocoaFrame
        window.setFrame(cocoaFrame, display: false)
        
        if mode == .error {
            flashErrorAnimation()
        } else {
            // 通常の表示アニメーション
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                window.animator().alphaValue = 0.8
            }
            window.orderFront(nil)
        }
    }
    
    // エラー時の「一瞬表示して消える」アニメーション
    private func flashErrorAnimation() {
        guard let window = overlayWindow else { return }
        
        window.alphaValue = 0.0
        window.orderFront(nil)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            window.animator().alphaValue = 0.8
        } completionHandler: {
            // 表示後にすぐフェードアウト
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                window.animator().alphaValue = 0.0
            } completionHandler: {
                window.orderOut(nil)
            }
        }
    }
    
    func updateFrame(_ frame: CGRect) {
        guard let window = overlayWindow else { return }
        let cocoaFrame = convertToCocoaFrame(frame)
        guard cocoaFrame != lastCocoaFrame else { return }
        lastCocoaFrame = cocoaFrame
        window.setFrame(cocoaFrame, display: false)
    }
    
    func hideEffect() {
        guard let window = overlayWindow else { return }
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            window.animator().alphaValue = 0.0
        }, completionHandler: {
            window.orderOut(nil)
        })
    }
    
    private func convertToCocoaFrame(_ frame: CGRect) -> CGRect {
        let screenHeight = CGDisplayBounds(CGMainDisplayID()).height
        var newRect = frame
        newRect.origin.y = screenHeight - frame.origin.y - frame.height
        return newRect
    }
}
