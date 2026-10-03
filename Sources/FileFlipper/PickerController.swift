import AppKit

/// Positions the quick palette beside the drag origin and keeps it within the screen.
final class PickerController {
    var onPick: ((PickerItem, [URL]) -> Void)?
    private var panel: NSPanel?
    private var palette: BubbleArcView?
    private var urls: [URL] = []
    private var origin = NSPoint.zero
    private var hideToken = 0

    func show(at point: NSPoint, urls: [URL], tools: Bool) {
        hideToken += 1
        self.urls = urls
        origin = point
        let panel = self.panel ?? makePanel()
        setToolsMode(tools)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            panel.animator().alphaValue = 1
        }
    }

    func setToolsMode(_ tools: Bool) {
        guard let panel, let palette else { return }
        palette.configure(items: Catalog.items(for: urls, tools: tools), urls: urls, tools: tools)
        let size = palette.preferredSize
        let screen = NSScreen.screens.first { NSMouseInRect(origin, $0.frame, false) } ?? NSScreen.main
        let visible = (screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)).insetBy(dx: 8, dy: 8)
        let above = origin.y + 18 + size.height <= visible.maxY
        let x = min(max(origin.x - size.width / 2, visible.minX), visible.maxX - size.width)
        let y = min(max(above ? origin.y + 18 : origin.y - size.height - 18, visible.minY), visible.maxY - size.height)
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
    }

    func hide(afterDelay delay: TimeInterval = 0) {
        let token = hideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, token == self.hideToken, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
                panel.animator().alphaValue = 0
            }, completionHandler: {
                guard token == self.hideToken else { return }
                panel.orderOut(nil)
            })
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 256),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = BubbleArcView(frame: panel.contentView!.bounds)
        view.autoresizingMask = [.width, .height]
        view.onDrop = { [weak self] item, urls in
            guard let self else { return }
            self.hideToken += 1
            self.hide()
            self.onPick?(item, urls)
        }
        panel.contentView = view
        self.panel = panel
        self.palette = view
        return panel
    }
}
