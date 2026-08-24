import Foundation
import Testing
@testable import NeedMoreTokensKit

@Suite("Grok remaining resets decoder")
struct GrokRemainingResetsTests {
    private static let now = Date(timeIntervalSince1970: 1_787_538_000) // 2026-08-24 02:20 UTC

    @Test func oneUnexpiredTokenCountsAsOne() {
        let end = Self.now.addingTimeInterval(30 * 24 * 3_600)
        let body = Self.grpcWeb(tokens: [Self.token(id: "restok_test1", end: end)])
        #expect(GrokRemainingResets.resetCount(fromGrpcWeb: body, now: Self.now) == 1)
    }

    @Test func emptySuccessIsZeroNotNil() {
        let body = Self.grpcWeb(tokens: [])
        #expect(GrokRemainingResets.resetCount(fromGrpcWeb: body, now: Self.now) == 0)
    }

    @Test func expiredAndEmptyIdsAreDropped() {
        let past = Self.now.addingTimeInterval(-3_600)
        let future = Self.now.addingTimeInterval(3_600)
        let body = Self.grpcWeb(tokens: [
            Self.token(id: "restok_expired", end: past),
            Self.token(id: "", end: future),
            Self.token(id: "restok_live", end: future),
        ])
        #expect(GrokRemainingResets.resetCount(fromGrpcWeb: body, now: Self.now) == 1)
    }

    @Test func tokenMissingEndIsDropped() {
        let body = Self.grpcWeb(tokens: [Self.token(id: "restok_noend", end: nil)])
        #expect(GrokRemainingResets.resetCount(fromGrpcWeb: body, now: Self.now) == 0)
    }

    @Test func twoUnexpiredTokensCountAsTwo() {
        let end = Self.now.addingTimeInterval(86_400)
        let body = Self.grpcWeb(tokens: [
            Self.token(id: "restok_a", end: end),
            Self.token(id: "restok_b", end: end.addingTimeInterval(86_400)),
        ])
        #expect(GrokRemainingResets.resetCount(fromGrpcWeb: body, now: Self.now) == 2)
    }

    @Test func grpcStatusNonZeroIsUnreadable() {
        let body = Self.grpcWeb(tokens: [Self.token(id: "restok_x", end: Self.now.addingTimeInterval(86_400))],
                                status: 16)
        #expect(GrpcWebFrame.parse(body)?.status == 16)
        #expect(GrokRemainingResets.resetCount(fromGrpcWeb: body, now: Self.now) == nil)
    }

    @Test func compressedFrameIsUnreadable() {
        var frame = Data([1]) // compressed data flag
        frame.append(contentsOf: [0, 0, 0, 1, 0])
        #expect(GrokRemainingResets.resetCount(fromGrpcWeb: frame, now: Self.now) == nil)
    }

    @Test func truncatedFrameIsUnreadable() {
        #expect(GrokRemainingResets.resetCount(fromGrpcWeb: Data([0, 0, 0, 0, 20]), now: Self.now) == nil)
    }

    @Test func liveShapedOneTokenFrameDecodes() {
        // Field numbers from prod_mc_billing.ConsumerGetRemainingResetsResp /
        // ConsumerResetToken: tokens=10, token_id=10, validity_end=30, Timestamp.seconds=1.
        let end = Date(timeIntervalSince1970: 1_789_238_940) // 2026-09-12 18:49 UTC
        let body = Self.grpcWeb(tokens: [Self.token(id: "restok_sample", end: end)])
        #expect(GrokRemainingResets.resetCount(fromGrpcWeb: body, now: Self.now) == 1)
        #expect(GrokRemainingResets.resetCount(fromGrpcWeb: body, now: end.addingTimeInterval(1)) == 0)
    }

    static func token(id: String, end: Date?) -> (id: String, end: Date?) { (id, end) }

    static func grpcWeb(tokens: [(id: String, end: Date?)], status: Int = 0) -> Data {
        var message = Data()
        for token in tokens {
            var inner = protoString(10, token.id)
            if let end = token.end {
                inner.append(protoMessage(30, protoVarint(1, UInt64(end.timeIntervalSince1970.rounded()))))
            }
            message.append(protoMessage(10, inner))
        }
        return grpcWebFrame(message: message, status: status)
    }

    static func grpcWebFrame(message: Data, status: Int) -> Data {
        var out = Data()
        out.append(0)
        out.append(contentsOf: u32be(UInt32(message.count)))
        out.append(message)
        let trailer = Data("grpc-status:\(status)\r\n".utf8)
        out.append(0x80)
        out.append(contentsOf: u32be(UInt32(trailer.count)))
        out.append(trailer)
        return out
    }

    private static func protoString(_ field: Int, _ value: String) -> Data {
        protoBytes(field, Data(value.utf8))
    }

    private static func protoMessage(_ field: Int, _ value: Data) -> Data {
        protoBytes(field, value)
    }

    private static func protoBytes(_ field: Int, _ value: Data) -> Data {
        var out = encodeVarint(UInt64(field << 3 | 2))
        out.append(encodeVarint(UInt64(value.count)))
        out.append(value)
        return out
    }

    private static func protoVarint(_ field: Int, _ value: UInt64) -> Data {
        var out = encodeVarint(UInt64(field << 3))
        out.append(encodeVarint(value))
        return out
    }

    private static func encodeVarint(_ value: UInt64) -> Data {
        var n = value
        var out = Data()
        while n > 0x7f {
            out.append(UInt8(n & 0x7f) | 0x80)
            n >>= 7
        }
        out.append(UInt8(n))
        return out
    }

    private static func u32be(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
    }
}
