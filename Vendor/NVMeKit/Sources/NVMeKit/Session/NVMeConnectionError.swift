import Foundation

/// Why a queue's connection ended, or why a step on it failed. A queue fails
/// every command in flight with its close reason, and the controller treats
/// any of these as the trigger to recover.
public enum NVMeConnectionError: Error, Equatable, Sendable {
    /// Closed on purpose, or used after it was.
    case closed
    /// The transport failed underneath the queue.
    case connectionLost(String)
    /// The controller sent something NVMe/TCP does not allow.
    case protocolError(String)
}
