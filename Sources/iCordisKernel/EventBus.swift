import Foundation

public struct EventID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue }
}

public struct NotificationEvent<Payload: Sendable>: Sendable {
  public let id: EventID
  public init(_ id: EventID) { self.id = id }
}

public struct SerialEvent<Payload: Sendable, Response: Sendable>: Sendable {
  public let id: EventID
  public init(_ id: EventID) { self.id = id }
}

public struct ParallelEvent<Payload: Sendable, Response: Sendable>: Sendable {
  public let id: EventID
  public init(_ id: EventID) { self.id = id }
}

public struct TransformEvent<Value: Sendable>: Sendable {
  public let id: EventID
  public init(_ id: EventID) { self.id = id }
}

public struct MiddlewareEvent<Request: Sendable, Response: Sendable>: Sendable {
  public let id: EventID
  public init(_ id: EventID) { self.id = id }
}

public typealias EventNext<Request: Sendable, Response: Sendable> =
  @Sendable (Request) async throws -> Response

public enum EventDispatchKind: String, Sendable {
  case notification
  case serial
  case parallel
  case transform
  case middleware
}

public struct EventSubscription: Hashable, Sendable {
  fileprivate let id: UUID
  public let eventID: EventID
  public let ownerPluginID: PluginID
}

public struct EventHandlerSnapshot: Sendable, Equatable {
  public let eventID: EventID
  public let kind: EventDispatchKind
  public let ownerPluginID: PluginID
  public let priority: Int
  public let registrationOrder: UInt64

  public init(
    eventID: EventID, kind: EventDispatchKind, ownerPluginID: PluginID, priority: Int,
    registrationOrder: UInt64
  ) {
    self.eventID = eventID
    self.kind = kind
    self.ownerPluginID = ownerPluginID
    self.priority = priority
    self.registrationOrder = registrationOrder
  }
}

public enum EventBusError: Error, LocalizedError, Sendable, Equatable {
  case contractMismatch(eventID: EventID, expected: EventDispatchKind, actual: EventDispatchKind)
  case payloadTypeMismatch(eventID: EventID, expected: String, actual: String)
  case responseTypeMismatch(eventID: EventID, expected: String, actual: String)

  public var errorDescription: String? {
    switch self {
    case .contractMismatch(let eventID, let expected, let actual):
      "Event \(eventID) is registered as \(actual.rawValue), not \(expected.rawValue)."
    case .payloadTypeMismatch(let eventID, let expected, let actual):
      "Event \(eventID) expected payload \(expected), but received \(actual)."
    case .responseTypeMismatch(let eventID, let expected, let actual):
      "Event \(eventID) expected response \(expected), but received \(actual)."
    }
  }
}

public actor EventBus {
  public init() {}
  private enum ErasedResult: Sendable {
    case noResult
    case value(any Sendable)
  }

  private typealias StandardHandler = @Sendable (any Sendable) async throws -> ErasedResult
  private typealias ErasedNext = @Sendable (any Sendable) async throws -> any Sendable
  private typealias MiddlewareHandler =
    @Sendable (any Sendable, @escaping ErasedNext) async throws -> any Sendable

  private struct Handler: Sendable {
    let subscription: EventSubscription
    let kind: EventDispatchKind
    let priority: Int
    let order: UInt64
    let standard: StandardHandler?
    let middleware: MiddlewareHandler?
  }

  private var handlers: [EventID: [Handler]] = [:]
  private var contracts: [EventID: EventDispatchKind] = [:]
  private var nextOrder: UInt64 = 0

  public func on<Payload: Sendable>(
    _ event: NotificationEvent<Payload>,
    owner: PluginID,
    priority: Int = 0,
    handler: @escaping @Sendable (Payload) async throws -> Void
  ) throws -> EventSubscription {
    try register(
      eventID: event.id,
      kind: .notification,
      owner: owner,
      priority: priority,
      standard: { payload in
        guard let typed = payload as? Payload else {
          throw EventBusError.payloadTypeMismatch(
            eventID: event.id,
            expected: String(reflecting: Payload.self),
            actual: String(reflecting: type(of: payload))
          )
        }
        try await handler(typed)
        return .noResult
      }
    )
  }

  public func on<Payload: Sendable, Response: Sendable>(
    _ event: SerialEvent<Payload, Response>,
    owner: PluginID,
    priority: Int = 0,
    handler: @escaping @Sendable (Payload) async throws -> Response?
  ) throws -> EventSubscription {
    try register(
      eventID: event.id,
      kind: .serial,
      owner: owner,
      priority: priority,
      standard: { payload in
        guard let typed = payload as? Payload else {
          throw EventBusError.payloadTypeMismatch(
            eventID: event.id,
            expected: String(reflecting: Payload.self),
            actual: String(reflecting: type(of: payload))
          )
        }
        guard let response = try await handler(typed) else { return .noResult }
        return .value(response)
      }
    )
  }

  public func on<Payload: Sendable, Response: Sendable>(
    _ event: ParallelEvent<Payload, Response>,
    owner: PluginID,
    priority: Int = 0,
    handler: @escaping @Sendable (Payload) async throws -> Response
  ) throws -> EventSubscription {
    try register(
      eventID: event.id,
      kind: .parallel,
      owner: owner,
      priority: priority,
      standard: { payload in
        guard let typed = payload as? Payload else {
          throw EventBusError.payloadTypeMismatch(
            eventID: event.id,
            expected: String(reflecting: Payload.self),
            actual: String(reflecting: type(of: payload))
          )
        }
        return .value(try await handler(typed))
      }
    )
  }

  public func on<Value: Sendable>(
    _ event: TransformEvent<Value>,
    owner: PluginID,
    priority: Int = 0,
    handler: @escaping @Sendable (Value) async throws -> Value
  ) throws -> EventSubscription {
    try register(
      eventID: event.id,
      kind: .transform,
      owner: owner,
      priority: priority,
      standard: { payload in
        guard let typed = payload as? Value else {
          throw EventBusError.payloadTypeMismatch(
            eventID: event.id,
            expected: String(reflecting: Value.self),
            actual: String(reflecting: type(of: payload))
          )
        }
        return .value(try await handler(typed))
      }
    )
  }

  public func on<Request: Sendable, Response: Sendable>(
    _ event: MiddlewareEvent<Request, Response>,
    owner: PluginID,
    priority: Int = 0,
    handler:
      @escaping @Sendable (Request, @escaping EventNext<Request, Response>) async throws -> Response
  ) throws -> EventSubscription {
    try register(
      eventID: event.id,
      kind: .middleware,
      owner: owner,
      priority: priority,
      middleware: { payload, next in
        guard let typed = payload as? Request else {
          throw EventBusError.payloadTypeMismatch(
            eventID: event.id,
            expected: String(reflecting: Request.self),
            actual: String(reflecting: type(of: payload))
          )
        }
        let typedNext: EventNext<Request, Response> = { nextRequest in
          let response = try await next(nextRequest)
          guard let typedResponse = response as? Response else {
            throw EventBusError.responseTypeMismatch(
              eventID: event.id,
              expected: String(reflecting: Response.self),
              actual: String(reflecting: type(of: response))
            )
          }
          return typedResponse
        }
        return try await handler(typed, typedNext)
      }
    )
  }

  public func emit<Payload: Sendable>(_ event: NotificationEvent<Payload>, payload: Payload)
    async throws
  {
    let resolved = try orderedHandlers(eventID: event.id, kind: .notification)
    for handler in resolved {
      _ = try await handler.standard?(payload)
    }
  }

  public func serial<Payload: Sendable, Response: Sendable>(
    _ event: SerialEvent<Payload, Response>,
    payload: Payload
  ) async throws -> Response? {
    let resolved = try orderedHandlers(eventID: event.id, kind: .serial)
    for handler in resolved {
      guard let invoke = handler.standard else { continue }
      switch try await invoke(payload) {
      case .noResult:
        continue
      case .value(let value):
        guard let typed = value as? Response else {
          throw EventBusError.responseTypeMismatch(
            eventID: event.id,
            expected: String(reflecting: Response.self),
            actual: String(reflecting: type(of: value))
          )
        }
        return typed
      }
    }
    return nil
  }

  public func parallel<Payload: Sendable, Response: Sendable>(
    _ event: ParallelEvent<Payload, Response>,
    payload: Payload
  ) async throws -> [Response] {
    let resolved = try orderedHandlers(eventID: event.id, kind: .parallel)
    let values = try await withThrowingTaskGroup(of: (Int, ErasedResult).self) { group in
      for (index, handler) in resolved.enumerated() {
        guard let invoke = handler.standard else { continue }
        group.addTask { (index, try await invoke(payload)) }
      }
      var collected: [(Int, ErasedResult)] = []
      for try await value in group {
        collected.append(value)
      }
      return collected.sorted { $0.0 < $1.0 }.map(\.1)
    }
    return try values.compactMap { result in
      guard case .value(let value) = result else { return nil }
      guard let typed = value as? Response else {
        throw EventBusError.responseTypeMismatch(
          eventID: event.id,
          expected: String(reflecting: Response.self),
          actual: String(reflecting: type(of: value))
        )
      }
      return typed
    }
  }

  public func transform<Value: Sendable>(
    _ event: TransformEvent<Value>,
    initial: Value
  ) async throws -> Value {
    let resolved = try orderedHandlers(eventID: event.id, kind: .transform)
    var current = initial
    for handler in resolved {
      guard let invoke = handler.standard else { continue }
      guard case .value(let value) = try await invoke(current), let typed = value as? Value else {
        throw EventBusError.responseTypeMismatch(
          eventID: event.id,
          expected: String(reflecting: Value.self),
          actual: "no result"
        )
      }
      current = typed
    }
    return current
  }

  public func middleware<Request: Sendable, Response: Sendable>(
    _ event: MiddlewareEvent<Request, Response>,
    request: Request,
    terminal: @escaping EventNext<Request, Response>
  ) async throws -> Response {
    let resolved = try orderedHandlers(eventID: event.id, kind: .middleware)

    @Sendable func invoke(_ index: Int, _ erasedRequest: any Sendable) async throws -> any Sendable
    {
      guard index < resolved.count else {
        guard let typedRequest = erasedRequest as? Request else {
          throw EventBusError.payloadTypeMismatch(
            eventID: event.id,
            expected: String(reflecting: Request.self),
            actual: String(reflecting: type(of: erasedRequest))
          )
        }
        return try await terminal(typedRequest)
      }
      guard let body = resolved[index].middleware else {
        return try await invoke(index + 1, erasedRequest)
      }
      let next: ErasedNext = { nextRequest in
        try await invoke(index + 1, nextRequest)
      }
      return try await body(erasedRequest, next)
    }

    let response = try await invoke(0, request)
    guard let typed = response as? Response else {
      throw EventBusError.responseTypeMismatch(
        eventID: event.id,
        expected: String(reflecting: Response.self),
        actual: String(reflecting: type(of: response))
      )
    }
    return typed
  }

  public func remove(_ subscription: EventSubscription) {
    guard var registered = handlers[subscription.eventID] else { return }
    registered.removeAll { $0.subscription == subscription }
    if registered.isEmpty {
      handlers.removeValue(forKey: subscription.eventID)
      contracts.removeValue(forKey: subscription.eventID)
    } else {
      handlers[subscription.eventID] = registered
    }
  }

  public func snapshots() -> [EventHandlerSnapshot] {
    handlers.values.flatMap { entries in
      entries.map {
        EventHandlerSnapshot(
          eventID: $0.subscription.eventID,
          kind: $0.kind,
          ownerPluginID: $0.subscription.ownerPluginID,
          priority: $0.priority,
          registrationOrder: $0.order
        )
      }
    }
    .sorted {
      if $0.eventID.rawValue == $1.eventID.rawValue {
        if $0.priority == $1.priority {
          return $0.registrationOrder < $1.registrationOrder
        }
        return $0.priority > $1.priority
      }
      return $0.eventID.rawValue < $1.eventID.rawValue
    }
  }

  private func register(
    eventID: EventID,
    kind: EventDispatchKind,
    owner: PluginID,
    priority: Int,
    standard: StandardHandler? = nil,
    middleware: MiddlewareHandler? = nil
  ) throws -> EventSubscription {
    if let existing = contracts[eventID], existing != kind {
      throw EventBusError.contractMismatch(eventID: eventID, expected: kind, actual: existing)
    }
    contracts[eventID] = kind
    let subscription = EventSubscription(id: UUID(), eventID: eventID, ownerPluginID: owner)
    handlers[eventID, default: []].append(
      Handler(
        subscription: subscription,
        kind: kind,
        priority: priority,
        order: nextOrder,
        standard: standard,
        middleware: middleware
      ))
    nextOrder += 1
    return subscription
  }

  private func orderedHandlers(eventID: EventID, kind: EventDispatchKind) throws -> [Handler] {
    if let existing = contracts[eventID], existing != kind {
      throw EventBusError.contractMismatch(eventID: eventID, expected: kind, actual: existing)
    }
    return (handlers[eventID] ?? []).sorted {
      if $0.priority == $1.priority { return $0.order < $1.order }
      return $0.priority > $1.priority
    }
  }
}
