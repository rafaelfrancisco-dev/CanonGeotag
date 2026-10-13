import Foundation
import Testing
@testable import CanonProtocol

@Suite struct CanonProtocolTests {
    @Test func uuids() {
        #expect(CanonUUID.primaryService == "00010000-0000-1000-0000-D8492FFFA821")
        #expect(CanonUUID.identity == "0001000A-0000-1000-0000-D8492FFFA821")
        #expect(CanonUUID.geoIndication == "00040003-0000-1000-0000-D8492FFFA821")
    }

    @Test func geoPacketNorthEast() {
        let fix = GeoFix(latitude: 38.7223, longitude: 9.1393, altitude: 120.5,
                         horizontalAccuracy: 10, timestamp: Date(timeIntervalSince1970: 1_760_000_000))
        let bytes = [UInt8](GeoPacket.encode(fix))

        #expect(bytes.count == GeoPacket.length && bytes.count == 20)
        #expect(bytes[0] == 0x04)
        #expect(bytes[1] == UInt8(ascii: "N"))
        #expect(float(bytes, at: 2) == Float(38.7223))
        #expect(bytes[6] == UInt8(ascii: "E"))
        #expect(float(bytes, at: 7) == Float(9.1393))
        #expect(bytes[11] == UInt8(ascii: "+"))
        #expect(float(bytes, at: 12) == Float(120.5))
        #expect(uint32(bytes, at: 16) == 1_760_000_000)
        // Little-endian epoch: 1_760_000_000 = 0x68E7_7800
        #expect(Array(bytes[16...]) == [0x00, 0x78, 0xE7, 0x68])
    }

    @Test func geoPacketSouthWestBelowSeaLevel() {
        let fix = GeoFix(latitude: -33.86, longitude: -151.2, altitude: -12,
                         horizontalAccuracy: 5, timestamp: Date(timeIntervalSince1970: 0))
        let bytes = [UInt8](GeoPacket.encode(fix))

        #expect(bytes[1] == UInt8(ascii: "S"))
        #expect(float(bytes, at: 2) == Float(33.86))
        #expect(bytes[6] == UInt8(ascii: "W"))
        #expect(float(bytes, at: 7) == Float(151.2))
        #expect(bytes[11] == UInt8(ascii: "-"))
        #expect(float(bytes, at: 12) == Float(12))
    }

    @Test func unknownAltitudeIsZero() {
        let fix = GeoFix(latitude: 1, longitude: 1, altitude: nil, horizontalAccuracy: 5, timestamp: .now)
        let bytes = [UInt8](GeoPacket.encode(fix))
        #expect(bytes[11] == UInt8(ascii: "+"))
        #expect(float(bytes, at: 12) == 0)
    }

    @Test func identifyHandshake() {
        let id = UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        let writes = Handshake.identify(deviceName: "Geo", appID: id)

        #expect(writes.map(\.characteristic) == [CanonUUID.pairing, CanonUUID.identity, CanonUUID.identity, CanonUUID.identity])
        #expect([UInt8](writes[0].value) == [0x01, 0x47, 0x65, 0x6F])
        #expect([UInt8](writes[1].value) == [0x03, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                                             0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        #expect([UInt8](writes[2].value) == [0x04, 0x47, 0x65, 0x6F])
        #expect([UInt8](writes[3].value) == [0x05, 0x02])
    }

    @Test func finishAndEnable() {
        #expect(Handshake.finish == [HandshakeWrite(CanonUUID.identity, [0x01]), HandshakeWrite(CanonUUID.mode, [0x02])])
        #expect(Handshake.enableGeo == HandshakeWrite(CanonUUID.geoData, [0x01]))
    }

    @Test func indications() {
        #expect(PairResult(indication: Data([0x02])) == .accepted)
        #expect(PairResult(indication: Data([0x03])) == .rejected)
        #expect(PairResult(indication: Data()) == nil)
        #expect(GeoIndication(indication: Data([0x03])) == .request)
        #expect(GeoIndication(indication: Data([0x02])) == .enabled)
        #expect(GeoIndication(indication: Data([0x07])) == .other(0x07))
    }

    private func float(_ bytes: [UInt8], at offset: Int) -> Float {
        Float(bitPattern: uint32(bytes, at: offset))
    }

    private func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }
}
