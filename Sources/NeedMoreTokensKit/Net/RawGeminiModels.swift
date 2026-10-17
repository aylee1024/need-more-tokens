import Foundation

// loadCodeAssist is https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist.
// The quota summary is https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary.
// Grouped response shape verified from Antigravity, 2026-06-18.

public struct RawGeminiLoadCodeAssistPayload: Decodable, Sendable {
    public let cloudaicompanionProject: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cloudaicompanionProject = container.decodeNative(String.self, forKey: .cloudaicompanionProject)
    }

    private enum CodingKeys: String, CodingKey {
        case cloudaicompanionProject
    }
}

public struct RawGeminiQuotaPayload: Decodable, Sendable {
    public let groups: [RawGeminiQuotaGroup]?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groups = container.decodeNative([RawGeminiQuotaGroup].self, forKey: .groups)
    }

    private enum CodingKeys: String, CodingKey {
        case groups
    }
}

public struct RawGeminiQuotaGroup: Decodable, Sendable {
    public let displayName: String?
    public let description: String?
    public let buckets: [RawGeminiQuotaBucket]?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = container.decodeNative(String.self, forKey: .displayName)
        description = container.decodeNative(String.self, forKey: .description)
        buckets = container.decodeNative([RawGeminiQuotaBucket].self, forKey: .buckets)
    }

    private enum CodingKeys: String, CodingKey {
        case displayName
        case description
        case buckets
    }
}

public struct RawGeminiQuotaBucket: Decodable, Sendable {
    public let bucketId: String?
    public let displayName: String?
    public let window: String?
    public let resetTime: String?
    public let remainingFraction: Double?
    public let description: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bucketId = container.decodeNative(String.self, forKey: .bucketId)
        displayName = container.decodeNative(String.self, forKey: .displayName)
        window = container.decodeNative(String.self, forKey: .window)
        resetTime = container.decodeNative(String.self, forKey: .resetTime)
        remainingFraction = container.decodeNative(Double.self, forKey: .remainingFraction)
        description = container.decodeNative(String.self, forKey: .description)
    }

    private enum CodingKeys: String, CodingKey {
        case bucketId
        case displayName
        case window
        case resetTime
        case remainingFraction
        case description
    }
}
