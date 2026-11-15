import SwiftUI
import ChessCore

enum Palette {
    static let light = Color(red: 0xEA / 255, green: 0xD9 / 255, blue: 0xB8 / 255)
    static let dark = Color(red: 0xA9 / 255, green: 0x79 / 255, blue: 0x4F / 255)
    static let ink = Color(red: 0x1F / 255, green: 0x1B / 255, blue: 0x18 / 255)
    static let paper = Color(red: 0xFB / 255, green: 0xF7 / 255, blue: 0xEF / 255)
    static let highlight = Color(red: 0xF2 / 255, green: 0xC9 / 255, blue: 0x4C / 255)
    static let check = Color(red: 0xD6 / 255, green: 0x45 / 255, blue: 0x45 / 255)
}

/// A chess piece drawn from Unicode glyphs. White pieces are a cream solid glyph with the outline glyph on top.
struct PieceGlyph: View {
    let piece: Piece
    let size: CGFloat

    private static let solid: [PieceKind: String] = [
        .king: "\u{265A}", .queen: "\u{265B}", .rook: "\u{265C}",
        .bishop: "\u{265D}", .knight: "\u{265E}", .pawn: "\u{265F}",
    ]
    private static let outline: [PieceKind: String] = [
        .king: "\u{2654}", .queen: "\u{2655}", .rook: "\u{2656}",
        .bishop: "\u{2657}", .knight: "\u{2658}", .pawn: "\u{2659}",
    ]
    /// U+FE0E forces text presentation so the pawn never becomes a colour emoji.
    private static let textSelector = "\u{FE0E}"

    var body: some View {
        ZStack {
            Text(Self.solid[piece.kind]! + Self.textSelector)
                .foregroundStyle(piece.color == .white ? Palette.paper : Palette.ink)
            if piece.color == .white {
                Text(Self.outline[piece.kind]! + Self.textSelector)
                    .foregroundStyle(Palette.ink)
            }
        }
        .font(.custom("Apple Symbols", size: size))
        .lineLimit(1)
        .fixedSize()
        .frame(width: size, height: size)
    }
}
