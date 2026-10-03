import AppKit

/// Semantic colours follow the system appearance, including increased contrast.
enum Palette {
    static let accent = NSColor.systemBlue
    static let text = NSColor.labelColor
    static let secondary = NSColor.secondaryLabelColor
    static let surface = NSColor.windowBackgroundColor
    static let control = NSColor.controlBackgroundColor
    static let border = NSColor.separatorColor
    static let canvas = NSColor(white: 0.12, alpha: 1)
}
