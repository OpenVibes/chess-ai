# Chess — plan

Workers run on Sonnet; the tier sets the effort. Status: `[ ]` open, `[x]` accepted. Spec: `docs/SPEC.md`.

## 1. Scaffold package — light — no dependencies — [x]

Create `Package.swift` (tools 5.9, macOS 14) with targets `ChessCore`, `ChessEngine`, `ChessApp` and test targets `ChessCoreTests`, `ChessEngineTests`. Declare the whole public API from SPEC "ChessCore public API" and "ChessEngine public API" as compiling stubs (bodies may `fatalError("unimplemented")`, except `Position.start` and `Square`, which should be real). `ChessApp` opens an empty 920×640 window titled "Chess". One trivial passing test per test target, using whichever of XCTest / Swift Testing works with `swift test` here; record the choice in CLAUDE.md. Verify: `swift build`, `swift test`.

## 2. Rules core — careful — after 1 — [x]

Implement `Position` in `ChessCore`: board storage, FEN parse/print, legal move generation, `applying`, check and attack detection, insufficient material, `repetitionKey`, and `perft`. Follow SPEC "Rules details". Do not touch `Game`/SAN. Verify with perft tests (must all match):

| Position (FEN) | depth: nodes |
|---|---|
| start | 1: 20, 2: 400, 3: 8902, 4: 197281 |
| `r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1` | 1: 48, 2: 2039, 3: 97862 |
| `8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1` | 1: 14, 2: 191, 3: 2812, 4: 43238 |
| `r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1` | 1: 6, 2: 264, 3: 9467 |
| `rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8` | 1: 44, 2: 1486, 3: 62379 |

Plus FEN round-trip tests and targeted tests for castling-rights loss on rook capture and the en passant pin. Start position perft 4 should run in well under 2 s in a debug build.

## 3. Game layer and notation — medium — after 2 — [x]

Implement `Game`, `MoveRecord`, `GameStatus` and SAN generation in `ChessCore` (separate files from task 2's). Status priority and draw rules per SPEC. Tests: fool's mate and scholar's mate end in checkmate with correct SAN (`Qh4#`, `Qxf7#`); a stalemate FEN; threefold by knight shuffling; fifty-move; each insufficient-material case; SAN disambiguation (file, rank, both), castling, en passant, promotion with check; undo restores position, history and status.

## 4. Computer opponent — careful — after 2 — [ ]

Implement `Engine` in `ChessEngine` per SPEC (search, evaluation, three levels). Needs only `Position` from task 2 plus `Game.history` for repetition; if task 3 is not merged yet, read repetition keys defensively. Tests: finds mate in 1 and mate in 2 on Medium and Hard for at least three positions each; never returns an illegal move over 200 random-playout positions; takes a hanging queen; Hard returns within 2.5 s; `shouldStop` returning true ends the search promptly. Only touches `Sources/ChessEngine` and `Tests/ChessEngineTests`.

## 5. Board and sidebar UI — medium — after 3 — [x]

Build the Two players experience in `ChessApp` exactly as SPEC "Design" describes: `GameModel`, `BoardView` with click and drag moves, highlights, promotion picker, sidebar with strips, status, move list and buttons, new game sheet (mode control present; Versus computer options shown but the computer does not move yet), game over card, menu commands, and the `CHESS_SNAPSHOT` / `CHESS_FEN` hook. Verify: `swift build`, then snapshots of the start position and of a mid-game FEN.

## 6. Versus computer wiring — medium — after 4 and 5 — [ ]

Connect `Engine` to `GameModel`: after a human move in Versus computer, run `Engine.bestMove` off the main thread, show "Computer is thinking…", block input meanwhile, apply the reply with the normal animation. Cancel the search on New game and on Undo. Computer moves first when the human plays Black. Undo goes back to the human's previous turn. Opponent strip shows "Computer · <level>". Verify: `swift build`, `swift test`, and a headless self-check (env hook or test) that plays a human move and receives a legal reply.

## 7. App bundle and icon — light — after 1 — [x]

Add `build.sh` modelled on `../remote-pc/build.sh`: `swift build -c release`, assemble `dist/Chess.app` (bundle id `local.chess.app`, category board games, min macOS 14), ad-hoc codesign. No DMG. Icon: `make-icon.py` (Pillow) draws a knight glyph on a rounded square in the board's dark colour and builds `AppIcon.icns`; if Pillow is missing, the script says so and the build continues without an icon. Verify: `./build.sh` and `open dist/Chess.app` starts the app. Touches only `build.sh`, `make-icon.py`, `.gitignore`.

## Order

1 → 2 → (3 ‖ 4 ‖ 7) → 5 → 6. Task 7 can start any time after 1. Commit after each accepted task.
