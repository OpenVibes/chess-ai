# Chess — spec

A native macOS chess app. Two people can play on one Mac, or one person can play the built-in computer opponent.

## Goals (MVP)

- Full chess rules: legal move generation, castling, en passant, promotion, check, checkmate, stalemate, fifty-move rule, threefold repetition, insufficient material.
- Two modes: **Two players** (same screen) and **Versus computer** (three difficulty levels, play as White, Black or random).
- Move list in standard algebraic notation (SAN), captured pieces, undo, flip board, new game.
- Rules and engine are covered by unit tests (perft counts, mate puzzles).

## Non-goals

Online play, clocks, opening books, PGN import/export, saved games, analysis/eval bar, sounds, themes, iOS. No third-party dependencies, no network, no AI model.

## Stack

- Swift 6.x toolchain, Swift package with `swift-tools-version:5.9` (Swift 5 language mode), `platforms: [.macOS(.v14)]`.
- SwiftUI app as an SPM executable target (no Xcode project), same approach as `../remote-pc`.
- Tests with whichever of XCTest / Swift Testing the scaffold proves works under `swift test`; all later tests use the same one.

## Architecture

Three targets, dependencies point one way: `ChessApp → ChessEngine → ChessCore`.

| Target | Kind | Responsibility |
|---|---|---|
| `ChessCore` | library | Pure rules. No UI, no Foundation-heavy code, no randomness. Value types only. |
| `ChessEngine` | library | Computer opponent: evaluation and search. Depends only on `ChessCore`. |
| `ChessApp` | executable | SwiftUI window, game model, interaction. No rules logic of its own: it asks `ChessCore` what is legal. |

### ChessCore public API (the contract)

The scaffold creates these declarations as compiling stubs. Later tasks fill in bodies and may **add** API; changing or removing a declared signature needs the orchestrator's sign-off.

```swift
public enum PieceColor: Sendable { case white, black; public var opposite: PieceColor }
public enum PieceKind: Sendable, CaseIterable { case pawn, knight, bishop, rook, queen, king }
public struct Piece: Hashable, Sendable { public let color: PieceColor; public let kind: PieceKind }

public struct Square: Hashable, Sendable {
    public let index: Int                 // 0 = a1, 1 = b1 … 7 = h1, 8 = a2 … 63 = h8
    public var file: Int { get }          // 0…7 = a…h
    public var rank: Int { get }          // 0…7 = 1…8
    public init(file: Int, rank: Int)
    public init?(_ algebraic: String)     // "e4"
    public var algebraic: String { get }
}

public struct Move: Hashable, Sendable {
    public let from: Square, to: Square
    public let promotion: PieceKind?      // nil unless a pawn reaches the last rank
    public var uci: String { get }        // "e2e4", "e7e8q"
}

public struct CastlingRights: OptionSet, Hashable, Sendable   // whiteKingside, whiteQueenside, blackKingside, blackQueenside

public struct Position: Hashable, Sendable {
    public static let start: Position
    public init?(fen: String)
    public var fen: String { get }
    public subscript(_ square: Square) -> Piece? { get }
    public var sideToMove: PieceColor { get }
    public var castling: CastlingRights { get }
    public var enPassant: Square? { get }        // target square, only as given by the FEN rules
    public var halfmoveClock: Int { get }
    public var fullmoveNumber: Int { get }
    public func legalMoves() -> [Move]
    public func legalMoves(from: Square) -> [Move]
    public func applying(_ move: Move) -> Position   // precondition: move is legal
    public var isInCheck: Bool { get }               // side to move
    public func kingSquare(of: PieceColor) -> Square?
    public func isAttacked(_ square: Square, by: PieceColor) -> Bool
    public var hasInsufficientMaterial: Bool { get }
    public var repetitionKey: RepetitionKey { get }  // placement + side + castling + en passant (no clocks)
}

public struct RepetitionKey: Hashable, Sendable   // opaque

public func perft(_ position: Position, depth: Int) -> Int

public enum GameStatus: Equatable, Sendable {
    case ongoing
    case checkmate(winner: PieceColor)
    case stalemate
    case drawFiftyMove, drawRepetition, drawInsufficientMaterial
}

public struct MoveRecord: Sendable {
    public let move: Move
    public let san: String                // "Nf3", "exd5", "O-O", "e8=Q+", "Qh4#"
    public let piece: Piece
    public let captured: Piece?
    public let positionBefore: Position
}

public struct Game: Sendable {
    public init(position: Position = .start)
    public private(set) var position: Position
    public private(set) var history: [MoveRecord]
    public var status: GameStatus { get }
    public var lastMove: Move? { get }
    public func captured(by: PieceColor) -> [Piece]        // pieces this colour has taken
    @discardableResult public mutating func play(_ move: Move) -> Bool   // false and no change if illegal or game over
    @discardableResult public mutating func undo() -> Bool
}
```

Rules details that are easy to get wrong:

- Castling: king and rook unmoved (tracked by rights), squares between empty, king not in check, and neither the square it crosses nor lands on attacked. Rights are lost when the king or rook moves **or the rook is captured on its home square**.
- En passant: only on the move right after the double push; the capture must not leave the own king in check (including the horizontal-pin case where both pawns leave the rank).
- Promotion: four moves (Q, R, B, N) per promoting push or capture.
- Draws: fifty-move at `halfmoveClock >= 100`; threefold when the current `repetitionKey` has occurred 3 times in the game; insufficient material for K v K, K+B v K, K+N v K, and K+B v K+B with same-coloured bishops. Checkmate takes priority over the fifty-move rule. Draws are applied automatically (no claim step).
- SAN: disambiguate by file, then rank, then both; only among **legal** moves. `+` for check, `#` for mate.

### ChessEngine public API

```swift
public enum Difficulty: String, CaseIterable, Sendable { case easy, medium, hard }

public enum Engine {
    /// Returns nil only when there is no legal move. `shouldStop` is polled during search.
    public static func bestMove(in game: Game, difficulty: Difficulty,
                                shouldStop: @Sendable () -> Bool = { false }) -> Move?
    /// Static score in centipawns from White's point of view.
    public static func evaluate(_ position: Position) -> Int
}
```

- Search: negamax with alpha-beta, iterative deepening, MVV-LVA move ordering, quiescence search on captures. Evaluation: material plus piece-square tables (separate king table for the endgame). Mate scores prefer the shortest mate. Avoids stepping into a threefold repetition when ahead.
- Levels: **easy** = depth 1 and picks randomly among moves within 80 cp of the best; **medium** = fixed depth 3; **hard** = iterative deepening with a 2.0 s budget (always completes at least depth 1). Easy is the only level with randomness.
- Runs synchronously; the app calls it off the main thread.

### ChessApp

- `GameModel` (`@Observable`, main actor): holds `Game`, mode, human colour, difficulty, selection, board orientation, pending promotion, "computer is thinking" flag. All UI state changes go through it.
- Views: `BoardView` (squares, pieces, highlights, interaction), `SidebarView` (players, status, move list, buttons), `NewGameSheet`, `PromotionPicker`, `GameOverCard`.
- `CHESS_SNAPSHOT=/path/shot.png` (optional `CHESS_FEN=<fen>`) renders the main window to a PNG and exits, for layout checks without screen-recording permission.

## Design

One window, default 920×640, minimum 760×540. Board on the left, fixed 280 pt sidebar on the right. The board is always square and takes the largest size that fits with 20 pt padding.

**Board**
- Squares: light `#EAD9B8`, dark `#A9794F`. 6 pt corner radius on the whole board, no per-square borders.
- Coordinates inside the edge squares: rank numbers top-left of the a-file squares, file letters bottom-right of the first-rank squares, 10 pt semibold, in the opposite square colour. They follow the board orientation.
- Pieces are Unicode chess glyphs, font size 0.78 × square. Black piece: solid glyph (♚♛♜♝♞♟) in `#1F1B18`. White piece: the same solid glyph in `#FBF7EF` with the outline glyph (♔♕♖♗♘♙) in `#1F1B18` drawn on top, so it reads as a white piece with a dark outline. No image assets.
- Highlights: last move's from and to squares get a `#F2C94C` overlay at 45%. Selected square gets the same colour at 70%. Legal targets: a centred dot, 28% of the square, black at 22% opacity; capture targets get a ring instead (full square inset 4%, 8% stroke, same colour). King in check: the square gets a `#D64545` overlay at 60%.
- Moving: click a piece of the side to move to select it, click a target to move; clicking another own piece reselects; clicking elsewhere deselects. Dragging a piece to a target also works; an illegal drop snaps back. Piece moves animate over 0.15 s.
- Orientation: White at the bottom by default; in Versus computer the human's colour is at the bottom. "Flip board" toggles it.

**Sidebar** (top to bottom, 16 pt padding, 12 pt gaps)
- Opponent strip (the colour at the top of the board): name ("Black", "White", or "Computer · Hard"), the pieces that side has captured as small glyphs, and the material lead as `+3` when ahead.
- Status line, 15 pt semibold: "White to move", "Black to move", "Check", "Computer is thinking…", "Checkmate. White wins", "Stalemate. Draw", "Draw by repetition", "Draw by fifty-move rule", "Draw by insufficient material".
- Move list: scrollable, monospaced digits, three columns (number, White, Black), latest move highlighted, auto-scrolls to the end. Empty state: "Moves appear here."
- Player strip for the bottom colour, same layout as the opponent strip.
- Buttons in one row: "New game" (opens the sheet), "Undo", "Flip board". Undo is one ply in Two players, and back to the human's previous turn in Versus computer. Menu commands: New game ⌘N, Undo ⌘Z, Flip board ⌘F.

**New game sheet**: "Mode" segmented control (Two players / Versus computer). When Versus computer: "Play as" (White / Black / Random) and "Difficulty" (Easy / Medium / Hard). Buttons: "Cancel", "Start game" (default). The app opens straight into a Two players game; the sheet is not shown at launch.

**Promotion picker**: a popover anchored to the target square with the four pieces in the mover's colour (Queen, Rook, Bishop, Knight); clicking outside cancels the move.

**Game over card**: centred over the board on a material background: the result line, then "New game" and "View board" (dismisses the card; the board stays inspectable, moves are disabled).

Follow the system light/dark appearance for the window and sidebar; the board colours are the same in both.

## Definition of done (MVP)

- `swift build` and `swift test` pass with no warnings introduced by this code.
- Perft matches the reference counts in `docs/PLAN.md` task 2.
- A full game can be played in both modes; every rule above is enforced; the computer answers within about 2.5 s on Hard.
- `./build.sh` produces `dist/Chess.app` that launches by double-click.
