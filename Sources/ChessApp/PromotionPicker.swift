import SwiftUI
import ChessCore

struct PromotionPicker: View {
    let model: GameModel

    private let choices: [(PieceKind, String)] = [
        (.queen, "Queen"), (.rook, "Rook"), (.bishop, "Bishop"), (.knight, "Knight"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(choices, id: \.0) { kind, name in
                Button {
                    model.choosePromotion(kind)
                } label: {
                    VStack(spacing: 2) {
                        // Board colours, so the glyphs read on a square-like tile.
                        PieceGlyph(piece: Piece(color: model.sideToMove, kind: kind), size: 40)
                            .frame(width: 52, height: 52)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.light))
                        Text(name).font(.caption)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
            }
        }
        .padding(10)
    }
}
