# Chess

Native macOS chess app. Swift package (tools 5.9, Swift 5 mode, macOS 14+), SwiftUI, no Xcode project, no dependencies.

## Commands

```bash
swift build                      # debug build
swift test                       # all tests
swift run ChessApp               # run the app
CHESS_SNAPSHOT=/abs/shot.png .build/debug/ChessApp   # render the window to a PNG and exit (optional CHESS_FEN)
./build.sh                       # dist/Chess.app
```

## Conventions

- Dependencies go one way: `ChessApp → ChessEngine → ChessCore`. `ChessCore` has no UI, no randomness, value types only.
- The public API in `docs/SPEC.md` is a contract. Add to it freely; do not change or remove a declared signature without asking.
- `ChessApp` contains no rules logic. Legality, status and notation always come from `ChessCore`.
- Tests use XCTest.
- Square index: 0 = a1, 7 = h1, 63 = h8.
- Design values (colours, sizes, copy) come from `docs/SPEC.md` "Design". Do not invent UI.
- Do not commit; the orchestrator commits after review. Update `filemap.md` when you add or move files.
- This folder's parent (`pc-controller`) is unrelated. Never touch files outside `chess/`, and nothing here runs over SSH.

## Pointers

- `docs/SPEC.md`: what to build, API contract, design.
- `docs/PLAN.md`: tasks, order, verification.
- `filemap.md`: where things live.
