import Foundation

/// Metadata fields for resources.
public struct ResourceMetadata: Sendable, Codable, Equatable {
    /// Creation timestamp for the resource.
    public var createdAt: Date?

    public init(createdAt: Date?) {
        self.createdAt = createdAt
    }
}

/// Protocol for resources that have common metadata fields.
public protocol HasMetadata {
    var metadata: ResourceMetadata { get set }
}

/// Used to access common metadata fields.
extension HasMetadata {
    /// Get the createdAt field
    public var createdAt: Date? { metadata.createdAt }
}

extension DateFormatter {
    /// A date formatter for ISO 8601 dates with fractional seconds.
    public static var metadataFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
