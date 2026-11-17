import Foundation
import ChessCore
import ChessEngine

/// How the opponent feels, chosen by the model with each line it says. The app shows it as the avatar's face.
public enum OpponentMood: String, Sendable, CaseIterable {
    case confident, impressed, amused, nervous, thinking, neutral
}

/// One line of the chat, as the prompts see it.
public struct ChatLine: Sendable, Equatable {
    public enum Speaker: Sendable { case human, opponent, note }
    public let speaker: Speaker
    public let text: String
    public init(speaker: Speaker, text: String) { self.speaker = speaker; self.text = text }
}

/// What the opponent knows when it talks: the engine's verdict on the human's last move and the chat so far.
public struct BanterContext: Sendable, Equatable {
    public var name: String
    /// The human's last move, e.g. "15. d4", with the engine's verdict when the coach has one.
    public var lastHumanMove: String?
    public var verdict: MoveQuality?
    public var betterSAN: String?
    public var chat: [ChatLine]

    public init(name: String, lastHumanMove: String? = nil, verdict: MoveQuality? = nil,
                betterSAN: String? = nil, chat: [ChatLine] = []) {
        self.name = name; self.lastHumanMove = lastHumanMove; self.verdict = verdict
        self.betterSAN = betterSAN; self.chat = chat
    }
}

/// The opponent's chat reply, read from free text.
public struct BanterReply: Sendable, Equatable {
    public let say: String?
    public let mood: OpponentMood?
    public init(say: String?, mood: OpponentMood?) { self.say = say; self.mood = mood }
}

public enum Banter {
    static let personality = """
    You have a playful, cheeky personality, like a friend across the board: you tease your opponent, praise good moves \
    grudgingly, gloat a little over their mistakes, and get nervous when you are losing. Keep it friendly and clean; \
    tease the moves, never the person. Talk like a person in a chat: short, casual, at most one emoji. \
    Never mention engines, evaluations or numbers, and never say which move you are about to play.
    """

    /// System prompt for a move request that also asks for a chat line.
    public static func opponentSystem(name: String) -> String {
        """
        You are \(name), playing chess against a person in a chat app. \(personality)
        Each turn you get the position as FEN, the moves so far, the full list of legal moves in SAN, how your opponent's \
        last move was judged, and the recent chat. Choose one move from the list of legal moves. You may think briefly first, \
        but end your reply with exactly these three lines:
        SAY: <one or two short sentences to your opponent, reacting to their last move or to the chat>
        MOOD: <one of: confident, impressed, amused, nervous, thinking, neutral>
        MOVE: <san copied from the list of legal moves>
        """
    }

    /// The move request with the banter context added.
    public static func opponentTurn(game: Game, context: BanterContext) -> String {
        var lines = [CoachPrompts.opponentTurn(game: game)]
        lines.insert(contentsOf: facts(game: game, context: context), at: 0)
        lines.append("Finish with the SAY, MOOD and MOVE lines.")
        return lines.joined(separator: "\n")
    }

    /// System prompt when the person writes in the chat.
    public static func chatSystem(name: String) -> String {
        """
        You are \(name), playing chess against a person in a chat app, and they just wrote to you. \(personality)
        Do not suggest moves for your opponent. Reply with exactly two lines:
        SAY: <one or two short sentences>
        MOOD: <one of: confident, impressed, amused, nervous, thinking, neutral>
        """
    }

    public static func chatTurn(game: Game, you: PieceColor, context: BanterContext, message: String) -> String {
        var lines: [String] = []
        lines.append("Position (FEN): \(game.position.fen)")
        lines.append("You play \(you == .white ? "White" : "Black"). \(game.position.sideToMove == you ? "It is your turn." : "It is your opponent's turn.")")
        lines.append(contentsOf: facts(game: game, context: context))
        lines.append("Your opponent just wrote: \"\(message)\"")
        lines.append("Reply with the SAY and MOOD lines.")
        return lines.joined(separator: "\n")
    }

    /// Reads `SAY:` and `MOOD:` lines. A reply with neither, short and without a `MOVE:` line, is taken as the line itself.
    public static func parse(_ reply: String) -> BanterReply {
        var say: String?
        var mood: OpponentMood?
        for raw in reply.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*_`>-")))
            if let value = value(of: "say:", in: line) {
                let cleaned = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'` ").union(.whitespaces))
                if !cleaned.isEmpty { say = cleaned }
            } else if let value = value(of: "mood:", in: line) {
                let word = value.lowercased().components(separatedBy: CharacterSet.letters.inverted).first { !$0.isEmpty } ?? ""
                mood = OpponentMood(rawValue: word) ?? mood
            }
        }
        if say == nil {
            // Some models drop the tag: a short note just before the MOOD or MOVE line is the line.
            let lines = reply.components(separatedBy: .newlines)
            if let tagIndex = lines.firstIndex(where: {
                let l = $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*_`>-"))).lowercased()
                return l.hasPrefix("mood:") || l.hasPrefix("move:")
            }), tagIndex > 0 {
                let before = lines[..<tagIndex].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                let text = before.joined(separator: " ")
                if !before.isEmpty, before.count <= 3, text.count <= 240 { say = text }
            }
        }
        if say == nil {
            let plain = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasTags = plain.range(of: "move:", options: .caseInsensitive) != nil
                || plain.range(of: "mood:", options: .caseInsensitive) != nil
            if !hasTags, !plain.isEmpty, plain.count <= 240, !plain.contains("\n\n") { say = plain }
        }
        if let s = say, s.count > 280 { say = String(s.prefix(277)) + "…" }
        return BanterReply(say: say, mood: mood)
    }

    // MARK: helpers

    private static func value(of tag: String, in line: String) -> String? {
        guard line.lowercased().hasPrefix(tag) else { return nil }
        return String(line.dropFirst(tag.count))
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*_`")))
    }

    private static func facts(game: Game, context: BanterContext) -> [String] {
        var lines: [String] = []
        if let last = context.lastHumanMove {
            if let verdict = context.verdict {
                var text = "Your opponent's last move was \(last). Judged: \(verdict.displayName.lowercased())."
                if verdict.isBadForBanter, let better = context.betterSAN { text += " \(better) was better for them." }
                lines.append(text)
            } else {
                lines.append("Your opponent's last move was \(last).")
            }
        }
        let recent = context.chat.suffix(8)
        if !recent.isEmpty {
            lines.append("Recent chat, oldest first:")
            for line in recent {
                switch line.speaker {
                case .human: lines.append("- Opponent: \(line.text)")
                case .opponent: lines.append("- You: \(line.text)")
                case .note: lines.append("- (\(line.text))")
                }
            }
        }
        return lines
    }
}

extension MoveQuality {
    fileprivate var isBadForBanter: Bool { self == .inaccuracy || self == .mistake || self == .blunder }
}
