import Foundation

extension KeyedDecodingContainer {
    func decodeNative<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }
}

public enum RawJSONValue: Decodable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: RawJSONValue])
    case array([RawJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RawJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: RawJSONValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }
}
