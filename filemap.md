# File map

- `CLAUDE.md` — commands and conventions for agents
- `docs/SPEC.md` — goals, API contract, design
- `docs/PLAN.md` — task list and status
- `Package.swift` — targets and test targets (task 1)
- `Sources/ChessCore/Types.swift` — colours, pieces, squares, moves, castling rights
- `Sources/ChessCore/Position.swift` — Position, RepetitionKey, perft
- `Sources/ChessCore/Game.swift` — GameStatus, MoveRecord, Game
- `Sources/ChessCore/Notation.swift` — SAN generation (placeholder until task 3)
- `Sources/ChessEngine/Engine.swift` — Difficulty and Engine (search, evaluation)
- `Sources/ChessApp/ChessApp.swift` — @main app, window, activation delegate
- `Tests/ChessCoreTests/ChessCoreTests.swift` — perft, rules, game and SAN tests
- `Tests/ChessEngineTests/ChessEngineTests.swift` — engine tests
- `build.sh`, `make-icon.py` — app bundle and icon (task 7)
