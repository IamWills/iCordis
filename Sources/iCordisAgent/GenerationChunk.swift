import Foundation
import iCordisKernel

public enum GenerationChunk: Sendable, Hashable {
  case text(String)
  case capabilityTrace(CapabilityExecutionTrace)
}
