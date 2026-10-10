// Renders the app icon: a gold labyrinth on a dark navy macOS-style squircle.
// Writes Resources/AppIcon.icns.
//   swift scripts/make-icon.swift [preview.png]
import AppKit
import SwiftUI

/// The minotaur's maze: nested rounded squares, each open on a different
/// side, with the centre marked.
struct Icon: View {
    let gold = LinearGradient(colors: [Color(red: 1.0, green: 0.87, blue: 0.5), Color(red: 0.91, green: 0.6, blue: 0.14)],
                              startPoint: .top, endPoint: .bottom)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.14, green: 0.16, blue: 0.32), Color(red: 0.04, green: 0.05, blue: 0.13)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 186, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 3))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 12)
            ForEach(0..<4, id: \.self) { ring in
                let side = CGFloat(580 - ring * 140)
                RoundedRectangle(cornerRadius: side * 0.16, style: .continuous)
                    .trim(from: 0.07, to: 1)
                    .stroke(gold, style: StrokeStyle(lineWidth: 36, lineCap: .round))
                    .frame(width: side, height: side)
                    .rotationEffect(.degrees(Double(ring) * 90))
            }
            Circle().fill(.white).frame(width: 60)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func render(_ size: Int) -> Data {
    let r = ImageRenderer(content: Icon())
    r.scale = CGFloat(size) / 1024
    let rep = NSBitmapImageRep(cgImage: r.cgImage!)
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appending(path: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                     ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! MainActor.assumeIsolated { render(size) }.write(to: iconset.appending(path: "icon_\(name).png"))
}
if CommandLine.arguments.count > 1 {
    try! MainActor.assumeIsolated { render(1024) }.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appending(path: "Resources/AppIcon.icns").path]
try! task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
