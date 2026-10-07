import iCordisKernel

public extension RuntimeServices {
  static let agentPlugins = ServiceKey<AgentPluginsService>(
    ServiceID("icordis.agent-plugins"))
}

// Compatibility alias kept inside the Agent module so the bridge can state its
// read-only filesystem requirement without changing iCordisKernel.
extension PluginPermission {
  static let filesystem = PluginPermission.filesystemRead
}
