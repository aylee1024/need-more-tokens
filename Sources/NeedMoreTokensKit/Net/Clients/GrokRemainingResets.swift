import Foundation

/// SuperGrok banked usage-limit resets. grok.com Settings ▸ Usage reads
/// `prod_mc_billing.ConsumerUiSvc/GetRemainingResets` over gRPC-web with the
/// same OIDC bearer as credits. NMT only COUNTS unexpired tokens; redeeming one
/// spends it, so that POST is never issued here.
enum GrokRemainingResets {
    static let url = URL(string: "https://grok.com/prod_mc_billing.ConsumerUiSvc/GetRemainingResets")!

    static func request(accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "X-Grpc-Web")
        request.setValue("grok-cli", forHTTPHeaderField: "User-Agent")
        // Empty protobuf message framed as uncompressed gRPC-web.
        request.httpBody = Data([0, 0, 0, 0, 0])
        return request
    }

    /// Unexpired reset tokens in a gRPC-web body. `nil` means the frame was
    /// unreadable or the RPC failed (`grpc-status` other than 0). A successful
    /// empty list is `0`, not `nil`.
    static func resetCount(fromGrpcWeb body: Data, now: Date) -> Int? {
        guard let framed = GrpcWebFrame.parse(body), framed.status == 0 else { return nil }
        var reader = ProtoReader(framed.message)
        var count = 0
        while let field = reader.nextField() {
            guard field.number == 10, field.wire == 2 else { continue }
            if tokenIsUnexpired(field.payload, now: now) { count += 1 }
        }
        return count
    }

    /// `ConsumerResetToken`: token_id=10, validity_end=30 (google.protobuf.Timestamp).
    /// Drop empty ids and missing/expired ends, matching grok.com's own filter.
    private static func tokenIsUnexpired(_ bytes: Data, now: Date) -> Bool {
        var reader = ProtoReader(bytes)
        var tokenId = ""
        var validityEnd: Date?
        while let field = reader.nextField() {
            if field.number == 10, field.wire == 2 {
                tokenId = String(data: field.payload, encoding: .utf8) ?? ""
            } else if field.number == 30, field.wire == 2 {
                validityEnd = timestampDate(field.payload)
            }
        }
        guard !tokenId.isEmpty, let end = validityEnd else { return false }
        return end > now
    }

    private static func timestampDate(_ bytes: Data) -> Date? {
        var reader = ProtoReader(bytes)
        var seconds: Int64 = 0
        var nanos: Int32 = 0
        while let field = reader.nextField() {
            if field.number == 1, field.wire == 0, let n = field.varint {
                seconds = Int64(bitPattern: n)
            } else if field.number == 2, field.wire == 0, let n = field.varint {
                nanos = Int32(truncatingIfNeeded: n)
            }
        }
        return Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanos) / 1_000_000_000)
    }
}

/// One uncompressed gRPC-web data frame plus optional trailer status.
struct GrpcWebFrame {
    let message: Data
    let status: Int

    static func parse(_ body: Data) -> GrpcWebFrame? {
        var offset = 0
        var message = Data()
        var status: Int?
        while offset + 5 <= body.count {
            let flags = body[offset]
            let length = (UInt32(body[offset + 1]) << 24) | (UInt32(body[offset + 2]) << 16)
                | (UInt32(body[offset + 3]) << 8) | UInt32(body[offset + 4])
            offset += 5
            let end = offset + Int(length)
            guard end <= body.count else { return nil }
            let chunk = body.subdata(in: offset..<end)
            offset = end
            if flags & 0x80 != 0 {
                status = grpcStatus(fromTrailers: chunk) ?? status
            } else if flags & 0x01 != 0 {
                return nil
            } else {
                message.append(chunk)
            }
        }
        guard offset == body.count else { return nil }
        return GrpcWebFrame(message: message, status: status ?? 0)
    }

    private static func grpcStatus(fromTrailers trailers: Data) -> Int? {
        guard let text = String(data: trailers, encoding: .utf8) else { return nil }
        let lowered = text.lowercased()
        guard let range = lowered.range(of: "grpc-status:") else { return nil }
        let rest = text[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = rest.prefix(while: { $0 == "-" || ($0 >= "0" && $0 <= "9") })
        return Int(digits)
    }
}

private struct ProtoField {
    let number: Int
    let wire: UInt8
    let payload: Data
    let varint: UInt64?
}

private struct ProtoReader {
    let data: Data
    var offset = 0

    init(_ data: Data) { self.data = data }

    mutating func nextField() -> ProtoField? {
        guard offset < data.count, let key = readVarint() else { return nil }
        let number = Int(key >> 3)
        let wire = UInt8(key & 7)
        switch wire {
        case 0:
            guard let value = readVarint() else { return nil }
            return ProtoField(number: number, wire: wire, payload: Data(), varint: value)
        case 1:
            guard let bytes = readBytes(8) else { return nil }
            return ProtoField(number: number, wire: wire, payload: bytes, varint: nil)
        case 2:
            guard let length = readVarint(), let bytes = readBytes(Int(length)) else { return nil }
            return ProtoField(number: number, wire: wire, payload: bytes, varint: nil)
        case 5:
            guard let bytes = readBytes(4) else { return nil }
            return ProtoField(number: number, wire: wire, payload: bytes, varint: nil)
        default:
            return nil
        }
    }

    private mutating func readVarint() -> UInt64? {
        var shift = 0
        var result: UInt64 = 0
        while offset < data.count, shift <= 63 {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    private mutating func readBytes(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.count else { return nil }
        let slice = data.subdata(in: offset..<(offset + count))
        offset += count
        return slice
    }
}
