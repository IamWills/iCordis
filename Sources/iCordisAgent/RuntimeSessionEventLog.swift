import Foundation
import iCordisKernel

public enum RuntimeSessionEventKind: String, Codable, CaseIterable, Sendable {
  case input
  case contextInjection
  case modelRequest
  case modelResponse
  case toolCall
  case toolResult
  case pluginAction
  case subagentEvent
  case approval
  case completion
}

public struct RuntimeSessionEvent: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public let sessionID: UUID
  public let runID: UUID?
  public let pluginID: PluginID
  public let kind: RuntimeSessionEventKind
  public let timestamp: Date
  public let payload: JSONValue

  public init(
    id: UUID = UUID(),
    sessionID: UUID,
    runID: UUID? = nil,
    pluginID: PluginID,
    kind: RuntimeSessionEventKind,
    timestamp: Date = .now,
    payload: JSONValue
  ) {
    self.id = id
    self.sessionID = sessionID
    self.runID = runID
    self.pluginID = pluginID
    self.kind = kind
    self.timestamp = timestamp
    self.payload = payload
  }
}

public struct RuntimeSessionFork: Codable, Hashable, Sendable {
  public let sourceSessionID: UUID
  public let forkedSessionID: UUID
  public let throughEventID: UUID?
  public let events: [RuntimeSessionEvent]

  public init(
    sourceSessionID: UUID, forkedSessionID: UUID, throughEventID: UUID? = nil,
    events: [RuntimeSessionEvent]
  ) {
    self.sourceSessionID = sourceSessionID
    self.forkedSessionID = forkedSessionID
    self.throughEventID = throughEventID
    self.events = events
  }
}

public actor RuntimeSessionEventLog {
  private var eventsBySession: [UUID: [RuntimeSessionEvent]] = [:]
  private var loadedSessions: Set<UUID> = []
  private let storageDirectory: URL?
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(storageDirectory: URL? = nil) {
    self.storageDirectory = storageDirectory
    if let storageDirectory {
      try? FileManager.default.createDirectory(
        at: storageDirectory,
        withIntermediateDirectories: true
      )
    }
  }

  public func append(_ event: RuntimeSessionEvent) {
    loadIfNeeded(event.sessionID)
    eventsBySession[event.sessionID, default: []].append(event)
    persist(event)
  }

  public func trajectory(sessionID: UUID) -> [RuntimeSessionEvent] {
    loadIfNeeded(sessionID)
    return eventsBySession[sessionID] ?? []
  }

  public func fork(
    sessionID: UUID,
    throughEventID: UUID?,
    forkedSessionID: UUID = UUID()
  ) -> RuntimeSessionFork {
    loadIfNeeded(sessionID)
    let source = eventsBySession[sessionID] ?? []
    let included: [RuntimeSessionEvent]
    if let throughEventID, let index = source.firstIndex(where: { $0.id == throughEventID }) {
      included = Array(source.prefix(through: index))
    } else {
      included = source
    }
    let copied = included.map {
      RuntimeSessionEvent(
        sessionID: forkedSessionID,
        runID: $0.runID,
        pluginID: $0.pluginID,
        kind: $0.kind,
        timestamp: $0.timestamp,
        payload: $0.payload
      )
    }
    eventsBySession[forkedSessionID] = copied
    loadedSessions.insert(forkedSessionID)
    for event in copied {
      persist(event)
    }
    return RuntimeSessionFork(
      sourceSessionID: sessionID,
      forkedSessionID: forkedSessionID,
      throughEventID: throughEventID,
      events: copied
    )
  }

  public nonisolated func replay(_ events: [RuntimeSessionEvent]) -> AsyncStream<
    RuntimeSessionEvent
  > {
    AsyncStream { continuation in
      for event in events {
        continuation.yield(event)
      }
      continuation.finish()
    }
  }

  private func loadIfNeeded(_ sessionID: UUID) {
    guard loadedSessions.insert(sessionID).inserted,
      let fileURL = fileURL(for: sessionID),
      let data = try? Data(contentsOf: fileURL),
      !data.isEmpty
    else { return }
    let events = data.split(separator: 0x0A).compactMap { line in
      try? decoder.decode(RuntimeSessionEvent.self, from: Data(line))
    }
    eventsBySession[sessionID] = events
  }

  private func persist(_ event: RuntimeSessionEvent) {
    guard let fileURL = fileURL(for: event.sessionID),
      var data = try? encoder.encode(event)
    else { return }
    data.append(0x0A)
    if FileManager.default.fileExists(atPath: fileURL.path),
      let handle = try? FileHandle(forWritingTo: fileURL)
    {
      defer { try? handle.close() }
      do {
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
      } catch {
        return
      }
    } else {
      try? data.write(to: fileURL, options: .atomic)
    }
  }

  private func fileURL(for sessionID: UUID) -> URL? {
    storageDirectory?.appendingPathComponent("\(sessionID.uuidString).jsonl")
  }
}

/// Product conversations and agent runtime sessions are deliberately distinct.
/// This reversible namespace transform keeps the mapping stable without global
/// state or a second mutable index.
public enum RuntimeSessionIdentity {
  public static func runtimeSessionID(for conversationID: UUID) -> UUID {
    transformed(conversationID)
  }

  public static func conversationID(for runtimeSessionID: UUID) -> UUID {
    transformed(runtimeSessionID)
  }

  private static func transformed(_ id: UUID) -> UUID {
    var bytes = id.uuid
    bytes.0 ^= 0xA5
    return UUID(uuid: bytes)
  }
}
