import Foundation
import Testing
import iCordisAgent

@Test func agentActionParserParsesFinalAnswer() throws {
  let action = try AgentActionParser().parse(
    """
    {
      "type": "final_answer",
      "content": "Done"
    }
    """)

  #expect(action == .finalAnswer("Done"))
}

@Test func agentActionParserParsesToolCallFromFencedJSON() throws {
  let action = try AgentActionParser().parse(
    """
    ```json
    {
      "type": "tool_call",
      "tool": "skill.summarize",
      "rationale": "Need a short summary",
      "arguments": {
        "text": "one\\ntwo"
      }
    }
    ```
    """)

  guard case .toolCall(let call) = action else {
    Issue.record("Expected tool call")
    return
  }
  #expect(call.capabilityID == "skill.summarize")
  #expect(call.arguments["text"]?.stringValue == "one\ntwo")
  #expect(call.rationale == "Need a short summary")
}

@Test func agentActionParserSkipsInvalidBraceFragmentsBeforeValidAction() throws {
  let action = try AgentActionParser().parse(
    """
    I used the tool and received {raw output}.
    {
      "type": "final_answer",
      "content": "Done from tool."
    }
    """)

  #expect(action == .finalAnswer("Done from tool."))
}

@Test func agentActionParserTreatsNaturalLanguageWithBraceFragmentsAsFinalAnswer() throws {
  let text = "I checked the tool output {not JSON} and here is the answer."
  let action = try AgentActionParser().parse(text)

  #expect(action == .finalAnswer(text))
}

@Test func agentActionParserTreatsCodeArtifactStartingWithBraceAsFinalAnswer() throws {
  let text = """
    {
      margin: 0;
      box-sizing: border-box;
    }

    const canvas = document.querySelector("canvas")
    function loop() {
      requestAnimationFrame(loop)
    }
    """
  let action = try AgentActionParser().parse(text)

  #expect(action == .finalAnswer(text))
}

@Test func agentActionParserStillRejectsMalformedJSONAction() {
  let action = try? AgentActionParser().parse(
    #"{"type":"tool_call","tool":"skill.build","arguments":"#)

  #expect(action == nil)
}

@Test func agentActionParserRejectsInvalidOutput() {
  let action = try? AgentActionParser().parse("not json")
  #expect(action == .finalAnswer("not json"))
}

@Test func agentActionParserStrictModeRejectsNaturalLanguageActions() {
  #expect(throws: AgentError.self) {
    _ = try AgentActionParser().parse(
      "The user wants recommendations, so I will answer directly.",
      allowsNaturalLanguageFinalAnswer: false
    )
  }
}

@Test func agentActionParserStrictModeAllowsJSONAfterNaturalLanguagePrefix() throws {
  let action = try AgentActionParser().parse(
    """
    The user wants recommendations, so I will answer directly.
    {
      "type": "final_answer",
      "content": "Here are recommendations."
    }
    """,
    allowsNaturalLanguageFinalAnswer: false
  )

  #expect(action == .finalAnswer("Here are recommendations."))
}

@Test func agentActionParserStrictModeParsesWilliamToolUseTag() throws {
  let action = try AgentActionParser().parse(
    """
    好的，我需要运行代码解析数据。

    <william:tool_use>
    {
      "tool": "william.tools.code.run",
      "rationale": "Parse weather JSON",
      "arguments": {
        "language": "python",
        "source": "print('ok')"
      }
    }
    </william:tool_use>
    """,
    allowsNaturalLanguageFinalAnswer: false
  )

  guard case .toolCall(let call) = action else {
    Issue.record("Expected tool call")
    return
  }
  #expect(call.capabilityID == "william.tools.code.run")
  #expect(call.rationale == "Parse weather JSON")
  #expect(call.arguments["language"]?.stringValue == "python")
  #expect(call.arguments["source"]?.stringValue == "print('ok')")
}

@Test func agentActionParserInfersToolCallWithoutType() throws {
  let action = try AgentActionParser().parse(
    """
    {
      "tool": "william.app.models.list",
      "arguments": {
        "limit": 3
      }
    }
    """)

  guard case .toolCall(let call) = action else {
    Issue.record("Expected tool call")
    return
  }
  #expect(call.capabilityID == "william.app.models.list")
}

@Test func agentActionParserInfersSearchToolsFromQueryOnlyObject() throws {
  let action = try AgentActionParser().parse(
    """
    {
      "query": "models"
    }
    """)

  guard case .toolCall(let call) = action else {
    Issue.record("Expected search tool call")
    return
  }
  #expect(call.capabilityID == AgentBuiltinToolID.searchTools)
  #expect(call.arguments["query"]?.stringValue == "models")
}

@Test func agentActionParserFallsBackToSearchToolsForThoughtOnlyObject() throws {
  let action = try AgentActionParser().parse(
    """
    {
      "thought": "I need to inspect the current app session first."
    }
    """)

  guard case .toolCall(let call) = action else {
    Issue.record("Expected fallback search tool call")
    return
  }
  #expect(call.capabilityID == AgentBuiltinToolID.searchTools)
  #expect(call.arguments["query"]?.stringValue?.contains("inspect") == true)
}

@Test func agentActionParserFallsBackToSearchToolsForEmptyObject() throws {
  let action = try AgentActionParser().parse("{}")

  guard case .toolCall(let call) = action else {
    Issue.record("Expected fallback search tool call")
    return
  }
  #expect(call.capabilityID == AgentBuiltinToolID.searchTools)
  #expect(call.arguments["query"]?.stringValue == "available tools")
}
