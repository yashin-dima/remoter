// Готовит картинку под иконку macOS: вырезает саму плитку и кладёт её на прозрачный холст
// в тех пропорциях, которых ждёт система.
//
// Зачем вообще: присланная картинка — это ПОРТРЕТ иконки. Плитка нарисована на тёмном фоне,
// вокруг подсветка, по краям поля. Если скормить такое iconutil, в доке будет тёмный квадрат
// с иконкой внутри вместо иконки. Поэтому: находим плитку, обрезаем фон, скругляем углы
// (чтобы вместо них была прозрачность, а не остатки подложки) и вписываем в сетку macOS —
// плитка занимает 824 из 1024 точек, остальное поля.
//
//   swift Scripts/icon-tool.swift <источник.png> <результат.png>

import AppKit

let args = CommandLine.arguments
guard args.count == 3,
      let src = NSImage(contentsOfFile: args[1]),
      let srcRep = NSBitmapImageRep(data: src.tiffRepresentation!)
else {
    FileHandle.standardError.write(Data("Нужно: icon-tool.swift <источник.png> <результат.png>\n".utf8))
    exit(1)
}

let w = srcRep.pixelsWide
let h = srcRep.pixelsHigh

/// Плитка — это большое однородное пятно в середине. Фон вокруг (тёмный, со свечением) от неё
/// отличается тем, что он либо заметно темнее, либо заметно светлее. Поэтому ищем не «яркое»,
/// а «похожее на центр»: цвет самой плитки берём из середины картинки и от него отталкиваемся.
let center = srcRep.colorAt(x: w / 2, y: h / 2)!
func isTile(_ x: Int, _ y: Int) -> Bool {
    guard let c = srcRep.colorAt(x: x, y: y) else { return false }
    let d = abs(c.redComponent - center.redComponent)
        + abs(c.greenComponent - center.greenComponent)
        + abs(c.blueComponent - center.blueComponent)
    return d < 0.18 && c.alphaComponent > 0.5
}

func scan(_ range: any Sequence<Int>, _ probe: (Int) -> Bool) -> Int? {
    range.first(where: probe)
}

// Границы плитки ищем по средней линии в обе стороны. Углы у плитки скруглены, поэтому
// по средней линии они и находятся честно: там край плитки — это её настоящий край.
let left   = scan(0..<w, { isTile($0, h / 2) })
let right  = scan((0..<w).reversed(), { isTile($0, h / 2) })
let bottom = scan(0..<h, { isTile(w / 2, $0) })
let top    = scan((0..<h).reversed(), { isTile(w / 2, $0) })

guard let left, let right, let bottom, let top, right > left, top > bottom else {
    FileHandle.standardError.write(Data("Не нашёл плитку на картинке\n".utf8))
    exit(1)
}

// В координатах NSBitmapImageRep y растёт вниз, в координатах рисования — вверх.
let side = CGFloat(min(right - left, top - bottom))
let crop = NSRect(
    x: CGFloat(left),
    y: CGFloat(h - top - 1),
    width: side,
    height: side
)

let canvas = 1024.0
let tile = 824.0                    // сетка macOS: плитка меньше холста, вокруг — поля под тень
let inset = (canvas - tile) / 2
let radius = tile * 0.2237          // тот же радиус скругления, что у системных иконок

let out = NSImage(size: NSSize(width: canvas, height: canvas))
out.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high

let box = NSRect(x: inset, y: inset, width: tile, height: tile)
NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).setClip()
src.draw(in: box, from: crop, operation: .copy, fraction: 1.0)

out.unlockFocus()

guard let tiff = out.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("Не смог собрать PNG\n".utf8))
    exit(1)
}

try png.write(to: URL(fileURLWithPath: args[2]))
print("Плитка найдена: \(Int(side))×\(Int(side)) из \(w)×\(h) → \(args[2])")
