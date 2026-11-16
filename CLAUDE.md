# Chess

Native macOS chess app. Swift package (tools 5.9, Swift 5 mode, macOS 14+), SwiftUI, no Xcode project, no dependencies.

## Commands

```bash
swift build                      # debug build
swift test                       # all tests
swift run ChessApp               # run the app
CHESS_SNAPSHOT=/abs/shot.png .build/debug/ChessApp   # render the window to a PNG and exit
# optional env: CHESS_FEN, CHESS_MOVES="e2e4 e7e5" (UCI), CHESS_VS=easy|medium|hard|model (model: fake key, no network; CHESS_NOKEY=1 drops the key; needs CHESS_AUTOPLAY=1 to request), CHESS_SELECT=e2, CHESS_FLIP=1, CHESS_DARK=1, CHESS_AUTOPLAY=1,
#   CHESS_COACH_DEMO=1 (wait for analysis + review of the last move), CHESS_HINT=1 (show hint arrow and card)
CHESS_SETTINGS_SNAPSHOT=/abs/settings.png .build/debug/ChessApp   # render SettingsView (460 pt wide) instead
CHESS_NEWGAME_SNAPSHOT=/abs/sheet.png CHESS_VS=model .build/debug/ChessApp   # render NewGameSheet alone
# snapshot runs use in-memory settings and keys and a transport that never touches the network
./build.sh                       # dist/Chess.app
```

## Conventions

- Dependencies go one way: `ChessApp → ChessCoach → ChessEngine → ChessCore`. `ChessCore` has no UI, no randomness, value types only.
- The public API in `docs/SPEC.md` is a contract. Add to it freely; do not change or remove a declared signature without asking.
- `ChessApp` contains no rules logic. Legality, status and notation always come from `ChessCore`.
- Tests use XCTest.
- Square index: 0 = a1, 7 = h1, 63 = h8.
- Design values (colours, sizes, copy) come from `docs/SPEC.md` "Design". Do not invent UI.
- Do not commit; the orchestrator commits after review. Update `filemap.md` when you add or move files.
- Never touch files outside this repository.

## Pointers

- `docs/SPEC.md`: what to build, API contract, design.
- `docs/PLAN.md`: tasks, order, verification.
- `filemap.md`: where things live.
