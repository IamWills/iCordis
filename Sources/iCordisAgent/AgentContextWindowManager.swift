import Foundation
import iCordisKernel

public struct AgentPromptHistorySelection: Sendable, Equatable {
  public var retained: [ConversationItem]
  public var overflow: [ConversationItem]

  public var needsCompression: Bool {
    !overflow.isEmpty
  }

  public var overflowText: String {
    overflow.map { item in
      "\(item.role.rawValue): \(item.plainText)"
    }.joined(separator: "\n\n")
  }

  public init(retained: [ConversationItem], overflow: [ConversationItem]) {
    self.retained = retained
    self.overflow = overflow
  }
}

/// Chooses which prior conversation turns enter the next Agent prompt.
///
/// The newest turns stay verbatim. Anything that would force the prefix past
/// the history budget is handed to semantic compression instead of being
/// dropped or prefix-clipped.
public struct AgentContextWindowManager: Sendable {
  public var messageLimit: Int
  public var characterBudget: Int
  public var verbatimRecentCount: Int

  public static let production = AgentContextWindowManager(
    messageLimit: 40,
    characterBudget: 80_000,
    verbatimRecentCount: 12
  )

  public init(
    messageLimit: Int = 40,
    characterBudget: Int = 80_000,
    verbatimRecentCount: Int = 12
  ) {
    self.messageLimit = max(4, messageLimit)
    self.characterBudget = max(4_000, characterBudget)
    self.verbatimRecentCount = max(2, verbatimRecentCount)
  }

  public func eligibleMessages(from session: ConversationSession) -> [ConversationItem] {
    session.items.filter { !$0.excludesFromPrompt && !$0.isTimelineEvent }
  }

  public func select(
    from session: ConversationSession,
    messageLimit: Int? = nil,
    characterBudget: Int? = nil
  ) -> AgentPromptHistorySelection {
    let items = eligibleMessages(from: session)
    let limit = max(4, messageLimit ?? self.messageLimit)
    let budget = max(4_000, characterBudget ?? self.characterBudget)
    let totalCharacters = items.reduce(0) { $0 + $1.plainText.count }

    if items.count <= limit, totalCharacters <= budget {
      return AgentPromptHistorySelection(retained: items, overflow: [])
    }

    let keepCount = min(items.count, limit, max(2, verbatimRecentCount))
    var retained = Array(items.suffix(keepCount))
    var retainedCharacters = retained.reduce(0) { $0 + $1.plainText.count }

    while retainedCharacters > budget, retained.count > 2 {
      retainedCharacters -= retained.removeFirst().plainText.count
    }

    let overflow = Array(items.dropLast(retained.count))
    return AgentPromptHistorySelection(retained: retained, overflow: overflow)
  }
}
