import Foundation
import iCordisKernel

/// All implementations remain plugins; provider closures can wrap any host storage or transport.
public typealias MemoryProviderPlugin = ServiceProviderPlugin<MemoryService>
public typealias MCPProviderPlugin = ServiceProviderPlugin<MCPService>
public typealias SkillProviderPlugin = ServiceProviderPlugin<SkillService>
public typealias SessionProviderPlugin = ServiceProviderPlugin<SessionService>
public typealias CompletionProviderPlugin = ServiceProviderPlugin<AgentCompletionService>
public typealias ContinuationProviderPlugin = ServiceProviderPlugin<AgentContinuationService>
public typealias ProgressProviderPlugin = ServiceProviderPlugin<AgentProgressService>
public typealias ContextProviderPlugin = ServiceProviderPlugin<ContextService>
public typealias SystemPromptProviderPlugin = ServiceProviderPlugin<SystemPromptService>
public typealias PermissionProviderPlugin = ServiceProviderPlugin<PermissionService>
