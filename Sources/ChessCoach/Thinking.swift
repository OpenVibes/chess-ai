import Foundation

/// How long the AI opponent may think: fast and shallow, a normal pace, or slow and careful.
/// Sets the clock note in the system prompt, the provider's reasoning effort, the output cap and the timeout.
public enum ThinkingLevel: String, Codable, Sendable, CaseIterable {
    case fast, normal, deep

    public var displayName: String {
        switch self {
        case .fast: return "Fast"
        case .normal: return "Normal"
        case .deep: return "Deep"
        }
    }

    /// One line for the menu and the sheet.
    public var summary: String {
        switch self {
        case .fast: return "Little thinking, quick replies. Easier to beat."
        case .normal: return "Thinks briefly before each move."
        case .deep: return "Thinks hard before each move. Slower, plays better."
        }
    }

    /// Added to the opponent's system prompt.
    public var promptNote: String {
        switch self {
        case .fast:
            return "Your clock is almost out: this is blitz. Do not analyse; trust your first instinct and reply right away with only the final lines."
        case .normal:
            return "You have a normal amount of time on your clock: think briefly about threats and captures, then answer."
        case .deep:
            return "You have plenty of time on your clock: think carefully before you answer. Check what your opponent threatens, look at every check and capture for both sides, and compare your best candidate moves."
        }
    }

    public var maxTokens: Int {
        switch self {
        case .fast: return 2000
        case .normal: return 4000
        case .deep: return 16000
        }
    }

    /// Seconds to wait for the reply.
    public var timeout: Double {
        switch self {
        case .fast: return 45
        case .normal: return 120
        case .deep: return 300
        }
    }

    /// Anthropic `output_config.effort`; OpenAI and Gemini `reasoning_effort`; OpenRouter `reasoning.effort`.
    var effort: String {
        switch self {
        case .fast: return "low"
        case .normal: return "medium"
        case .deep: return "high"
        }
    }
}
