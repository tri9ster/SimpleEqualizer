// アプリのアイコンの PNG を、SVG から書き出す。
//
// 使い方(リポジトリのいちばん上のフォルダで実行する):
//   swift tools/render-app-icon.swift design/AppIcon.svg SimpleEqualizer/Assets.xcassets/AppIcon.appiconset
//
// Apple 標準の仕組み(AppKit)だけを使う。元の SVG は書き換えない。
// `design/AppIcon.svg` を直したら、このスクリプトを実行し直して、PNG を作り直す。

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("使い方: swift tools/render-app-icon.swift <SVG> <書き出し先の appiconset>\n".utf8))
    exit(1)
}
let source = URL(fileURLWithPath: arguments[1])
let destination = URL(fileURLWithPath: arguments[2])

guard let image = NSImage(contentsOf: source) else {
    FileHandle.standardError.write(Data("SVG を読めません: \(source.path)\n".utf8))
    exit(1)
}

// macOS のアプリのアイコンに要る大きさ(ピクセル)。
let pixelSizes = [16, 32, 64, 128, 256, 512, 1024]

for pixels in pixelSizes {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
        FileHandle.standardError.write(Data("画像の置き場を作れません(\(pixels) ピクセル)\n".utf8))
        exit(1)
    }
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    // 背景は透明のままにする(角の外側を塗らない)。
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("PNG にできません(\(pixels) ピクセル)\n".utf8))
        exit(1)
    }
    let file = destination.appendingPathComponent("icon_\(pixels).png")
    do {
        try data.write(to: file)
        print("書き出し: \(file.lastPathComponent)")
    } catch {
        FileHandle.standardError.write(Data("書き込めません: \(file.path)\n".utf8))
        exit(1)
    }
}
