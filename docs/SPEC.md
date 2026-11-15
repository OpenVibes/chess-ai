# Chess — spec

A native macOS chess app. Two people can play on one Mac, or one person can play the built-in computer opponent.

## Goals (MVP)

- Full chess rules: legal move generation, castling, en passant, promotion, check, checkmate, stalemate, fifty-move rule, threefold repetition, insufficient material.
- Two modes: **Two players** (same screen) and **Versus computer** (three difficulty levels, play as White, Black or random).
- Move list in standard algebraic notation (SAN), captured pieces, undo, flip board, new game.
- Rules and engine are covered by unit tests (perft counts, mate puzzles).

## Non-goals

Online play, clocks, opening books, PGN import/export, saved games, sounds, themes, iOS. No third-party dependencies. (Version 1.1 adds the coach, an evaluation bar and optional AI model access: see "Coach and AI models".)

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

## Coach and AI models (version 1.1)

The app teaches while you play. The built-in engine still makes the computer's moves and does all the judging (which move was best, how bad a move was). An AI model (LLM), when the user has set one up, only puts that judgement into words, and can also be chosen as the opponent. Everything in this section except "Versus AI model" works with no API key.

### Architecture

New library target `ChessCoach` (Foundation allowed): `ChessApp → ChessCoach → ChessEngine → ChessCore`. Test target `ChessCoachTests`. No third-party dependencies; HTTP through `URLSession`.

### ChessEngine additions

```swift
public enum Score: Equatable, Sendable {      // always from White's point of view
    case centipawns(Int)
    case mate(Int)                            // +n: White mates in n moves, -n: Black mates in n
}
public struct PositionAnalysis: Sendable {
    public let bestMove: Move?                // nil when there is no legal move
    public let score: Score
    public let principalVariation: [Move]     // starts with bestMove; may be just that one move
    public let depth: Int
}
public struct AnalysisLimits: Sendable {
    public var maxDepth: Int                  // default 6
    public var budgetSeconds: Double          // default 0.8
    public init(maxDepth: Int = 6, budgetSeconds: Double = 0.8)
}
extension Engine {
    /// Deterministic full-strength search (no easy-level randomness). Checkmate on the board is .mate(0) for the winner's sign; stalemate/draw is .centipawns(0).
    public static func analyse(_ game: Game, limits: AnalysisLimits = .init(),
                               shouldStop: @Sendable () -> Bool = { false }) -> PositionAnalysis
}
```

### ChessCoach: move review (rule based)

```swift
public enum MoveQuality: String, Sendable, CaseIterable { case best, excellent, good, inaccuracy, mistake, blunder }
public struct MoveReview: Sendable, Equatable {
    public let move: Move, san: String, mover: PieceColor
    public let quality: MoveQuality
    public let scoreBefore: Score             // best play available before the move (White POV)
    public let scoreAfter: Score              // after the move actually played (White POV)
    public let bestMove: Move?, bestSAN: String?      // engine's choice in the position before
    public let bestLine: [String]             // SAN of the engine line, up to 4 plies
    public let winChanceLost: Double          // 0…1, from the mover's point of view
    public var summary: String { get }        // rule-based sentence, see copy below
}
public enum Coach {
    public static func winChance(_ score: Score, for color: PieceColor) -> Double   // 0…1
    public static func classify(winChanceLost: Double, playedBest: Bool) -> MoveQuality
    /// `before` is the analysis of record.positionBefore; `after` is the analysis of the position after the move.
    public static func review(record: MoveRecord, before: PositionAnalysis, after: PositionAnalysis) -> MoveReview
    public static func format(_ score: Score) -> String    // "+1.3", "−0.4", "0.0", "M3", "−M2"
}
```

- Win chance for White: `0.5 + 0.5 * (2 / (1 + exp(-0.00368208 * cp)) - 1)`; a mate score is 1.0 or 0.0.
- `winChanceLost = max(0, winChance(before) - winChance(after))` for the mover. If the played move equals `before.bestMove`, the quality is `best` and the loss is 0, whatever the second search says.
- Thresholds: best = played the engine move (or loss < 0.005); excellent < 0.02; good < 0.05; inaccuracy < 0.10; mistake < 0.20; blunder otherwise. If the position before had only one legal move, the quality is `best`.
- `summary` copy: best → "Best move."; excellent → "Excellent move."; good → "Good move."; the three bad ones → "Inaccuracy. Nf3 was better." / "Mistake. Nf3 was better." / "Blunder. Nf3 was better." (with the engine's SAN). When the loss is a forced mate missed or allowed, say so instead: "Blunder. This allows mate in 2." / "Mistake. You missed mate in 3 with Qh5."

### ChessCoach: AI model access

```swift
public enum ProviderKind: String, Codable, Sendable, CaseIterable { case anthropic, openAICompatible }
public struct ModelConfig: Codable, Equatable, Sendable {
    public var kind: ProviderKind
    public var baseURL: String                // no trailing slash
    public var model: String
    public var requiresKey: Bool
}
public struct ProviderPreset: Identifiable, Sendable { public let id: String, name: String; public let config: ModelConfig }
// Presets: Claude (anthropic, https://api.anthropic.com, claude-opus-5-5), OpenAI (https://api.openai.com/v1, gpt-5),
// Gemini (https://generativelanguage.googleapis.com/v1beta/openai, gemini-2.5-flash), OpenRouter (https://openrouter.ai/api/v1, anthropic/claude-opus-5-5),
// Ollama on this Mac (http://localhost:11434/v1, llama3.2, no key), Custom (openAICompatible, empty URL and model).
// Base URL and model are always editable, so any proxy or gateway that speaks one of the two formats works.

public struct ChatMessage: Sendable, Equatable { public enum Role: String, Sendable { case user, assistant }; public let role: Role; public let content: String }
public enum LLMError: Error, Equatable, LocalizedError {
    case missingKey, badURL, unauthorized, rateLimited, refused, emptyReply
    case http(Int, String)                    // status, short message from the body
    case network(String)
}
public protocol LLMTransport: Sendable { func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) }   // URLSession in the app, a stub in tests
public struct LLMClient: Sendable {
    public init(config: ModelConfig, apiKey: String?, transport: LLMTransport = URLSessionTransport())
    public func complete(system: String, messages: [ChatMessage], maxTokens: Int = 4000) async throws -> String
}
```

- Anthropic format: `POST {baseURL}/v1/messages`, headers `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`. Body: `model`, `max_tokens`, `system`, `messages`, `output_config: {"effort": "low"}`. Never send `temperature`, `top_p`, `top_k`, `thinking` or an assistant prefill (current Claude models reject them). The reply is the concatenation of the `text` blocks in `content` (skip `thinking` blocks). `stop_reason == "refusal"` → `LLMError.refused`. When the host is `api.anthropic.com` and the model is one of `claude-fable-5-2`, `claude-fable-5-1`, `claude-opus-5-5`, `claude-opus-5`, `claude-sonnet-5-5`, also send header `anthropic-beta: server-side-fallback-2026-07-01` and body field `"fallbacks": "default"`.
- OpenAI-compatible format: `POST {baseURL}/chat/completions`, header `Authorization: Bearer <key>` (omitted when there is no key). Body: `model`, `messages` (system message first), `max_tokens`. Reply: `choices[0].message.content`.
- Status mapping: 401/403 → unauthorized, 429 → rateLimited, other non-2xx → `.http`. 60 s timeout. No streaming, no retries inside the client.
- The API key never appears in logs, error text, UserDefaults or files. The app keeps it in the Keychain.

### ChessCoach: prompts and reply parsing

```swift
public enum CoachPrompts {
    public static let coachSystem: String
    public static func explainMove(review: MoveReview, positionBefore: Position, recentSAN: [String]) -> String
    public static func explainHint(position: Position, bestSAN: String, line: [String], recentSAN: [String]) -> String
    public static let opponentSystem: String
    public static func opponentTurn(game: Game) -> String            // FEN, colour to move, move list so far, every legal move in SAN
    public static func opponentRetry(rejected: String, legalSAN: [String]) -> String
}
public enum MoveParser {
    /// Finds the model's move in free text. Accepts SAN ("Nf3", "exd5", "O-O", "0-0", "e8=Q", with or without +, #, !, ?) and UCI ("g1f3", "e7e8q"). Returns nil unless exactly one legal move matches.
    public static func parse(_ reply: String, in position: Position) -> Move?
}
```

- Coach prompts give the model the facts (FEN, the move played, the engine's verdict and better move, the line, both scores) and ask for a plain explanation in at most two short sentences, for a learner, with no evaluation numbers and no move the engine did not supply. The model explains; it never judges.
- Opponent prompt asks for the chosen move on the last line as `MOVE: <san>`. `MoveParser` reads the `MOVE:` line first, then falls back to the last token in the reply that matches a legal move.

### ChessApp: coach behaviour

- **Background analysis.** Whenever the position changes and the game is not over, the app analyses the new position off the main thread (default `AnalysisLimits`) and caches the result by position. Cancelled when the position changes again. It feeds the evaluation bar, the hint, and the "before" half of the next review.
- **Review.** After each move by a human (both sides in Two players; only the human in the other modes), the app builds a `MoveReview` from the cached analysis before the move and the analysis after it, and stores it against that ply. Undo removes the reviews of the plies it takes back.
- **AI explanation.** If "Explain with AI" is on and a model is usable, the app asks the model to explain reviews of quality inaccuracy, mistake or blunder (and best moves that win material or mate are not explained: keep requests few). The rule-based summary shows at once; the model's text replaces the line under it when it arrives. A failure shows the rule-based text plus a one-line error in secondary colour; it never blocks play.
- **Hint.** Shows the engine's best move for the side to move as an arrow, with "Try Nf3." in the coach card; with AI on, the model adds why. The arrow clears on the next move.
- **Versus AI model.** Third mode. On the model's turn the app sends `opponentTurn`, parses the reply, and plays the move. An illegal or unreadable reply is retried with `opponentRetry`, twice at most; after the third failure the engine (Medium) plays that move and the coach card says "claude-opus-5-5 gave no legal move, so the engine played Nf3." A network or key error stops and shows the error in the coach card with "Try again" and "Let the engine move". New game and Undo cancel a pending request. Undo goes back to the human's previous turn.
- Settings (UserDefaults): `coachEnabled` (default on), `evalBarEnabled` (on), `hintsEnabled` (on), `aiExplanations` (off), and the `ModelConfig`. API key in the Keychain: generic password, service `local.chess.app`, account = the base URL host.

### Design additions

**Quality colours and marks** (same in light and dark): best `#5B8C3A` ★, excellent `#5B8C3A` "!", good `#7A9A6A` no mark, inaccuracy `#E0A526` "?!", mistake `#E07B26` "?", blunder `#D64545` "??".

**Evaluation bar.** A 10 pt wide vertical bar on the left of the board, same height, 8 pt gap, 3 pt corner radius. Black part `#1F1B18` at the top, white part `#FBF7EF` at the bottom when White is at the bottom (swapped when flipped). The white share is White's win chance, clamped to 5–95% (a forced mate fills it). Changes animate over 0.3 s. The board plus the bar stay centred; the board shrinks by 18 pt to make room. Hidden when the coach or the bar is off.

**Arrow.** From the centre of the from-square to the centre of the to-square, drawn above the pieces: line width 0.16 × square, triangular head 0.42 × square wide, colour `#5B8C3A` at 80%, no hit testing. Used for the hint and for "Show better move".

**Move list.** A reviewed move with a mark gets the mark appended in its quality colour ("Nxe5??"). Clicking a move shows its review in the coach card (the board does not rewind); the clicked cell gets a 1 pt accent outline. A new move returns the card to the latest review.

**Coach card.** In the sidebar between the move list and the bottom player strip, fixed 132 pt high, 8 pt corner radius, fill `Color.primary.opacity(0.05)`, 10 pt padding. Hidden when the coach is off (the move list takes the space).
- Header row: a 9 pt circle in the quality colour, the quality name in 13 pt semibold ("Mistake"), the move in secondary ("14. Nxe5"), spacer, then a borderless lightbulb button (SF Symbol `lightbulb`, help text "Hint") shown when hints are on and it is a human's turn.
- Body, 12 pt, up to 5 lines, scrolls if longer: the rule-based summary, then the AI text when there is one. While the AI text is loading: a small `ProgressView` and "Asking the model…" in secondary.
- Footer row for inaccuracy, mistake and blunder: a borderless button "Show better move" that draws the arrow for the engine's move on the current board only when the review is for the latest move; otherwise the footer shows "Better: Nf3" as text.
- Empty state (no move reviewed yet): title "Coach", body "Play a move and I will tell you how good it was."
- Hint state: title "Hint", body "Try Nf3." plus the AI text if any.
- Model opponent messages (fallback notice, errors with their two buttons) use the same card with the title "Opponent".

**Sidebar buttons** stay as they are. Menu "Game" gains: Hint ⇧⌘H. App menu gains Settings… ⌘, (SwiftUI `Settings` scene).

**Settings window**, 460 pt wide, grouped `Form`:
- Section "Coach": toggles "Review my moves", "Evaluation bar", "Hints", "Explain with AI" (disabled with the footnote "Add a model below to turn this on." until a model is usable).
- Section "AI model": "Provider" picker (the presets), "Base URL" text field, "Model" text field, "API key" secure field (placeholder "Stored in your Keychain"; hidden for a preset that needs no key), a "Test connection" button with a result line next to it ("Connected." in green, or the error in red), and the footnote "Only the position and moves are sent to the model. Requests are billed to your own key."
- Choosing a preset fills URL and model; editing either keeps the choice but the fields win. Changes save as they are made; the key saves when the field loses focus or Return is pressed.

**New game sheet**: 400 pt wide. "Mode" has three segments: Two players / Versus computer / Versus AI model. Versus AI model shows "Play as" and a "Model" text field prefilled from Settings (changing it here changes the setting). If no usable model is set up, it shows "Add an API key in Settings to play against a model." with an "Open Settings" button, and "Start game" is disabled. The opponent's strip shows the model name.

**Status line** in Versus AI model while waiting: "claude-opus-5-5 is thinking…" (the model name, truncated in the middle if long).

**Headless hooks**: `CHESS_COACH_DEMO=1` makes the snapshot wait for the background analysis and the review of the last `CHESS_MOVES` move before rendering, with AI off. `CHESS_HINT=1` shows the hint arrow. `CHESS_SETTINGS_SNAPSHOT=/abs.png` renders the settings form instead of the main window. Snapshots never touch the Keychain or the network.

### Packaging

`./build.sh` also writes `dist/Chess-<version>.dmg` (compressed, with the app and an Applications symlink, volume name "Chess"). Version 1.1.0. Info.plist gains `NSAppTransportSecurity → NSAllowsLocalNetworking = true` so a local Ollama over http works. Ad-hoc signed, not notarised: the first launch on another Mac needs right-click → Open.
