import SwiftUI

// Small pieces shared by the settings panes.

/// Section footer text. Grouped forms right-align multi-line footers on
/// their own, which reads oddly for prose, so pin it to the leading edge,
/// in line with the section header.
struct SettingsFooter: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.Typeface.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
    }
}

/// A one-line status with a tinted glyph: "✓ Plenty of room on this Mac."
struct SettingsStatusRow: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.callout)
    }
}

/// Bottom of Mining and Pool while a session runs.
struct SettingsRestartNote: View {
    var body: some View {
        Label {
            Text(Copy.restartNote).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(Theme.Typeface.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }
}
