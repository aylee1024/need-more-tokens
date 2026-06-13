import Foundation

// POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist and :retrieveUserQuota - shapes verified 2026-06-12.

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
    public let buckets: [RawGeminiQuotaBucket]?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        buckets = container.decodeNative([RawGeminiQuotaBucket].self, forKey: .buckets)
    }

    private enum CodingKeys: String, CodingKey {
        case buckets
    }
}

public struct RawGeminiQuotaBucket: Decodable, Sendable {
    public let modelID: String?
    public let tokenType: String?
    public let remainingAmount: String?
    public let remainingFraction: Double?
    public let resetTime: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelID = container.decodeNative(String.self, forKey: .modelID)
        tokenType = container.decodeNative(String.self, forKey: .tokenType)
        remainingAmount = container.decodeNative(String.self, forKey: .remainingAmount)
        remainingFraction = container.decodeNative(Double.self, forKey: .remainingFraction)
        resetTime = container.decodeNative(String.self, forKey: .resetTime)
    }

    private enum CodingKeys: String, CodingKey {
        case modelID = "modelId"
        case tokenType
        case remainingAmount
        case remainingFraction
        case resetTime
    }
}
