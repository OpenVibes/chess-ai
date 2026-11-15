import SwiftUI
import ChessCore

struct BoardView: View {
    @Bindable var model: GameModel
    let side: CGFloat

    @State private var dragStartSquare: Square?
    @State private var dragItemID: Int?
    @State private var dragLocation: CGPoint = .zero
    @State private var isDragging = false

    private var sq: CGFloat { side / 8 }

    private func origin(of square: Square) -> CGPoint {
        let col = model.whiteAtBottom ? square.file : 7 - square.file
        let row = model.whiteAtBottom ? 7 - square.rank : square.rank
        return CGPoint(x: CGFloat(col) * sq, y: CGFloat(row) * sq)
    }

    private func center(of square: Square) -> CGPoint {
        let o = origin(of: square)
        return CGPoint(x: o.x + sq / 2, y: o.y + sq / 2)
    }

    private func square(at p: CGPoint) -> Square? {
        guard p.x >= 0, p.y >= 0, p.x < side, p.y < side else { return nil }
        let col = Int(p.x / sq), row = Int(p.y / sq)
        let file = model.whiteAtBottom ? col : 7 - col
        let rank = model.whiteAtBottom ? 7 - row : row
        return Square(file: file, rank: rank)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            squaresLayer
            overlayLayer
            piecesLayer
            arrowLayer
            promotionAnchor
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .gesture(boardGesture)
    }

    // MARK: Layers

    private var squaresLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<64, id: \.self) { i in
                let s = Square(file: i & 7, rank: i >> 3)
                let isLight = (s.file + s.rank) % 2 == 1
                let o = origin(of: s)
                Rectangle()
                    .fill(isLight ? Palette.light : Palette.dark)
                    .frame(width: sq, height: sq)
                    .offset(x: o.x, y: o.y)
            }
            coordinates
        }
    }

    private var coordinates: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<8, id: \.self) { n in
                // Rank numbers: top-left of the left-most file's squares.
                let leftFile = model.whiteAtBottom ? 0 : 7
                let rs = Square(file: leftFile, rank: n)
                let ro = origin(of: rs)
                let rankLight = (rs.file + rs.rank) % 2 == 1
                Text("\(n + 1)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(rankLight ? Palette.dark : Palette.light)
                    .padding(.leading, 4).padding(.top, 3)
                    .frame(width: sq, height: sq, alignment: .topLeading)
                    .offset(x: ro.x, y: ro.y)

                // File letters: bottom-right of the bottom row's squares.
                let bottomRank = model.whiteAtBottom ? 0 : 7
                let fs = Square(file: n, rank: bottomRank)
                let fo = origin(of: fs)
                let fileLight = (fs.file + fs.rank) % 2 == 1
                Text(String(UnicodeScalar(UInt8(97 + n))))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(fileLight ? Palette.dark : Palette.light)
                    .padding(.trailing, 4).padding(.bottom, 3)
                    .frame(width: sq, height: sq, alignment: .bottomTrailing)
                    .offset(x: fo.x, y: fo.y)
            }
        }
        .allowsHitTesting(false)
    }

    private var overlayLayer: some View {
        ZStack(alignment: .topLeading) {
            if let last = model.game.lastMove {
                highlight(last.from, Palette.highlight.opacity(0.45))
                highlight(last.to, Palette.highlight.opacity(0.45))
            }
            if let sel = model.selected {
                highlight(sel, Palette.highlight.opacity(0.70))
            }
            if let king = model.kingInCheckSquare {
                highlight(king, Palette.check.opacity(0.60))
            }
            ForEach(Array(model.legalTargets), id: \.self) { t in
                let o = origin(of: t)
                Group {
                    if model.isCapture(to: t) {
                        Circle()
                            .strokeBorder(Color.black.opacity(0.22), lineWidth: sq * 0.08)
                            .padding(sq * 0.04)
                    } else {
                        Circle().fill(Color.black.opacity(0.22))
                            .frame(width: sq * 0.28, height: sq * 0.28)
                    }
                }
                .frame(width: sq, height: sq)
                .offset(x: o.x, y: o.y)
            }
        }
        .allowsHitTesting(false)
    }

    private func highlight(_ s: Square, _ color: Color) -> some View {
        let o = origin(of: s)
        return Rectangle().fill(color).frame(width: sq, height: sq).offset(x: o.x, y: o.y)
    }

    private var piecesLayer: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.pieces) { item in
                let dragged = isDragging && dragItemID == item.id
                let c = dragged ? dragLocation : center(of: item.square)
                PieceGlyph(piece: item.piece, size: sq * 0.78)
                    .frame(width: sq, height: sq)
                    .position(x: c.x, y: c.y)
                    .zIndex(dragged ? 10 : 0)
            }
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.15), value: model.pieces)
        .animation(.easeInOut(duration: 0.15), value: model.whiteAtBottom)
        .allowsHitTesting(false)
    }

    private var arrowLayer: some View {
        ZStack {
            if let arrow = model.coach.visibleArrow {
                ArrowShape(from: center(of: arrow.from), to: center(of: arrow.to), square: sq)
                    .fill(Palette.arrow)
            }
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// Invisible square on the promotion target; the picker popover anchors to it.
    private var promotionAnchor: some View {
        let target = model.pendingPromotion?.to
        let c = target.map(center(of:)) ?? .zero
        return Color.clear
            .frame(width: sq, height: sq)
            .position(x: c.x, y: c.y)
            .popover(isPresented: Binding(
                get: { model.pendingPromotion != nil },
                set: { if !$0 { model.cancelPromotion() } }
            ), arrowEdge: (target.map { origin(of: $0).y < side / 2 } ?? false) ? .bottom : .top) {
                PromotionPicker(model: model)
            }
            .allowsHitTesting(false)
    }

    // MARK: Interaction

    private var boardGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartSquare == nil {
                    dragStartSquare = square(at: value.startLocation)
                    if let s = dragStartSquare, model.canInteract,
                       let item = model.pieces.first(where: { $0.square == s }),
                       item.piece.color == model.sideToMove {
                        dragItemID = item.id
                    }
                }
                guard let id = dragItemID else { return }
                let dist = hypot(value.translation.width, value.translation.height)
                if !isDragging && dist > 4, let s = dragStartSquare {
                    isDragging = true
                    model.select(s)
                }
                if isDragging {
                    dragLocation = value.location
                }
                _ = id
            }
            .onEnded { value in
                let start = dragStartSquare
                let wasDragging = isDragging
                var transaction = Transaction(animation: .easeOut(duration: 0.15))
                transaction.disablesAnimations = false
                if wasDragging, let from = start {
                    let moved: Bool
                    if let to = square(at: value.location), to != from {
                        moved = model.tryMove(from: from, to: to)
                    } else {
                        moved = false
                    }
                    withTransaction(transaction) {
                        isDragging = false
                        dragItemID = nil
                    }
                    _ = moved
                } else if let s = start {
                    isDragging = false
                    dragItemID = nil
                    model.tap(s)
                } else {
                    isDragging = false
                    dragItemID = nil
                }
                dragStartSquare = nil
            }
    }
}
