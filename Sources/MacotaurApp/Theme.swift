import AppKit
import SwiftUI

extension NSColor {
    /// sRGB from 0xRRGGBB.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    /// Resolves per appearance like an asset-catalog color (SwiftPM has no catalog here).
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
    }
    init(lightHex: UInt32, darkHex: UInt32) { self.init(light: NSColor(hex: lightHex), dark: NSColor(hex: darkHex)) }
}

enum Theme {
    // Gold means "this Mac's / earned". Light mode darkens it: gold on white fails contrast.
    static let accent = Color(lightHex: 0xA86B18, darkHex: 0xF2B544)      // .tint (4.2:1 on white)
    static let accentText = Color(lightHex: 0x8C5414, darkHex: 0xFFDC80)  // gold text (6.2:1 / 12:1)

    // Status. Never gold, so gold always means good.
    static let positive = Color(lightHex: 0x1F8A4C, darkHex: 0x4CC38A)   // wallet OK
    static let danger = Color(lightHex: 0xC8372D, darkHex: 0xFF6B5E)
    static let heatWarm = Color(lightHex: 0xC2610F, darkHex: 0xF0904A)
    static let heatHot = Color(lightHex: 0xC8452A, darkHex: 0xFF6B4A)
    static let heatVeryHot = Color(lightHex: 0xB8233F, darkHex: 0xFF4F6B)
    static let caution = heatWarm                                        // settings warnings

    static let windowBackground = Color(nsColor: .windowBackgroundColor)

    enum Typeface {
        static let footnote = Font.system(size: 12)
    }
}

extension HeatLevel {
    /// Normal reads as ordinary secondary text; warmer levels take the heat ramp.
    var color: Color {
        switch self {
        case .normal: .secondary
        case .warm: Theme.heatWarm
        case .hot: Theme.heatHot
        case .veryHot: Theme.heatVeryHot
        }
    }
}
