import Foundation
import ChessCore

public enum MoveParser {
    /// Finds the model's move in free text. Accepts SAN ("Nf3", "exd5", "O-O", "0-0", "e8=Q", with or without +, #, !, ?) and UCI ("g1f3", "e7e8q"). Returns nil unless exactly one legal move matches.
    public static func parse(_ reply: String, in position: Position) -> Move? {
        let legal = position.legalMoves()
        if legal.isEmpty { return nil }
        let sans = legal.map { (move: $0, san: canonical(san(for: $0, in: position))) }

        func matches(_ raw: String) -> Set<Move> {
            let token = normalise(raw)
            if token.isEmpty { return [] }
            var found = Set<Move>()
            let lowered = token.lowercased()
            for (move, s) in sans {
                if s == token || s == castleForm(token) || s == upperPromotion(token) { found.insert(move) }
                if move.uci == lowered { found.insert(move) }
            }
            return found
        }

        let lines = reply.components(separatedBy: .newlines)
        if let line = lines.last(where: { $0.range(of: "move:", options: [.caseInsensitive]) != nil }),
           let r = line.range(of: "move:", options: [.caseInsensitive, .backwards]) {
            let rest = line[r.upperBound...]
            if let first = rest.split(whereSeparator: { $0.isWhitespace }).first {
                let found = matches(String(first))
                if found.count == 1 { return found.first }
                if found.count > 1 { return nil }
            }
        }

        let tokens = reply.split(whereSeparator: { $0.isWhitespace })
        for raw in tokens.reversed() {
            let found = matches(String(raw))
            if found.count == 1 { return found.first }
            if found.count > 1 { return nil }
        }
        return nil
    }

    /// Strips wrapping punctuation, move numbers and check/annotation marks.
    private static func normalise(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: CharacterSet(charactersIn: "`*_\"'“”‘’()[]{}<>.,;:"))
        // leading move number such as "12.Nf3"
        if let r = s.range(of: #"^\d+\.+"#, options: .regularExpression) { s.removeSubrange(r) }
        while let last = s.last, "+#!?".contains(last) { s.removeLast() }
        s = s.replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "−", with: "-")
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "`*_\"'.,;:"))
    }

    /// SAN without decorations or "=".
    private static func canonical(_ san: String) -> String {
        var s = san
        while let last = s.last, "+#!?".contains(last) { s.removeLast() }
        return s.replacingOccurrences(of: "=", with: "")
    }

    /// "0-0", "o-o", "O-O-O" spellings to "O-O" / "O-O-O".
    private static func castleForm(_ token: String) -> String {
        let t = token.replacingOccurrences(of: "0", with: "O").replacingOccurrences(of: "o", with: "O")
        return t == "O-O" || t == "O-O-O" ? t : token
    }

    /// "e8q" or "exd8n" to "e8Q" / "exd8N".
    private static func upperPromotion(_ token: String) -> String {
        guard token.count >= 3, let last = token.last, "qrbn".contains(last) else { return token }
        let body = token.dropLast()
        guard let l = body.last, l == "1" || l == "8" else { return token }
        return body + last.uppercased()
    }
}
