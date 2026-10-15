import Foundation

/// Canon EOS "smart device" Bluetooth LE protocol, ported from
/// https://github.com/gkoh/furble (`lib/furble/CanonEOSSmart.cpp`).
///
/// All UUIDs share the Canon base `XXXXXXXX-0000-1000-0000-D8492FFFA821`.
public enum CanonUUID {
    /// Primary service, advertised by the camera while pairing.
    public static let primaryService = canon(0x0001_0000)
    /// Device name write + pairing result indication (0xf108).
    public static let pairing = canon(0x0001_0006)
    /// Identity / pairing control (0xf104).
    public static let identity = canon(0x0001_000A)

    public static let modeService = canon(0x0003_0000)
    /// Camera mode (0xf307). furble writes 0x02 (shooting) for remote
    /// shutter control. Geotagging doesn't need it, and switching modes
    /// turns on a camera whose power switch is off, so it isn't written.
    public static let mode = canon(0x0003_0010)

    public static let geoService = canon(0x0004_0000)
    /// Location data, written with response.
    public static let geoData = canon(0x0004_0002)
    /// Location request / status indication.
    public static let geoIndication = canon(0x0004_0003)

    public static let services = [primaryService, modeService, geoService]

    static func canon(_ prefix: UInt32) -> String {
        let hex = String(prefix, radix: 16, uppercase: true)
        return String(repeating: "0", count: 8 - hex.count) + hex + "-0000-1000-0000-D8492FFFA821"
    }
}

/// Camera power state from its advertisement.
///
/// With Bluetooth enabled, the camera keeps advertising while its power
/// switch is off, and *any* connection turns it on. The manufacturer data
/// tells the two apart. Captured from an R7:
///
///     a9 01  01 f7 32 35 26  05   switched off (sparse, ~1 every 30–70 s)
///     a9 01  01 f7 32 35 26  02   switched on  (~4 per second)
///
/// `a9 01` is Canon's company ID (0x01A9, little-endian). The last byte is
/// the status.
public enum CameraStatus: Sendable, Equatable {
    case off
    case on
    case other(UInt8)

    static let companyID: [UInt8] = [0xA9, 0x01]
    static let statusOffset = 7

    /// `nil` if the data isn't Canon's or is too short.
    public init?(manufacturerData data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count > Self.statusOffset, Array(bytes.prefix(2)) == Self.companyID else { return nil }
        switch bytes[Self.statusOffset] {
        case 0x05: self = .off
        case 0x02: self = .on
        case let byte: self = .other(byte)
        }
    }

    /// Connecting is safe unless the camera reports it's switched off.
    /// Unknown states count as on, so an unrecognised status can't stop
    /// geotagging, and the app logs it.
    public var allowsConnecting: Bool { self != .off }
}

/// A position to send to the camera.
public struct GeoFix: Sendable, Hashable, Codable {
    public var latitude: Double
    public var longitude: Double
    /// Metres above sea level; `nil` when unknown.
    public var altitude: Double?
    /// Metres; lower is better.
    public var horizontalAccuracy: Double
    public var timestamp: Date

    public init(latitude: Double, longitude: Double, altitude: Double?, horizontalAccuracy: Double, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
    }
}

/// The 20-byte packed little-endian location message.
///
///     u8  0x04
///     u8  'N' | 'S',  f32 |latitude|
///     u8  'E' | 'W',  f32 |longitude|
///     u8  '+' | '-',  f32 |elevation m|
///     u32 Unix time (UTC seconds)
///
/// The time is absolute UTC, so it does not depend on any time zone. The
/// camera records it as the EXIF GPS date/time. Pass the time of sending
/// (as Canon Camera Connect does), not the fix's capture time: a
/// significant-change fix can be hours old while still being the best known
/// position.
public enum GeoPacket {
    public static let header: UInt8 = 0x04
    public static let length = 20

    public static func encode(_ fix: GeoFix, sentAt date: Date) -> Data {
        let altitude = fix.altitude ?? 0
        var data = Data(capacity: length)
        data.append(header)
        data.append(UInt8(ascii: fix.latitude < 0 ? "S" : "N"))
        data.appendLittleEndian(Float(abs(fix.latitude)))
        data.append(UInt8(ascii: fix.longitude < 0 ? "W" : "E"))
        data.appendLittleEndian(Float(abs(fix.longitude)))
        data.append(UInt8(ascii: altitude < 0 ? "-" : "+"))
        data.appendLittleEndian(Float(abs(altitude)))
        data.appendLittleEndian(UInt32(clamping: Int64(date.timeIntervalSince1970.rounded(.down))))
        return data
    }
}

/// One characteristic write in the connection handshake.
public struct HandshakeWrite: Sendable, Hashable {
    public let characteristic: String
    public let value: Data

    public init(_ characteristic: String, _ bytes: [UInt8]) {
        self.characteristic = characteristic
        self.value = Data(bytes)
    }
}

public enum Handshake {
    /// Writes that identify the phone to the camera. Run on every connection;
    /// on first pairing the camera then asks the user to confirm.
    public static func identify(deviceName: String, appID: UUID) -> [HandshakeWrite] {
        let name = Array(deviceName.utf8)
        let id = withUnsafeBytes(of: appID.uuid) { Array($0) }
        return [
            HandshakeWrite(CanonUUID.pairing, [0x01] + name),
            HandshakeWrite(CanonUUID.identity, [0x03] + id),
            HandshakeWrite(CanonUUID.identity, [0x04] + name),
            HandshakeWrite(CanonUUID.identity, [0x05, 0x02]),
        ]
    }

    /// Writes that complete the connection once pairing is accepted.
    public static let finish = [
        HandshakeWrite(CanonUUID.identity, [0x01]),
    ]

    /// Reply to a `GeoIndication.request`.
    public static let enableGeo = HandshakeWrite(CanonUUID.geoData, [0x01])
}

/// Indication on `CanonUUID.pairing` after the user responds on the camera.
public enum PairResult: UInt8, Sendable {
    case accepted = 0x02
    case rejected = 0x03

    public init?(indication: Data) {
        guard let first = indication.first else { return nil }
        self.init(rawValue: first)
    }
}

/// Indication on `CanonUUID.geoIndication`.
public enum GeoIndication: Sendable, Equatable {
    /// Camera wants location; reply with `Handshake.enableGeo`.
    case request
    /// Camera accepted location; start sending `GeoPacket`s.
    case enabled
    case other(UInt8)

    public init?(indication: Data) {
        guard let first = indication.first else { return nil }
        switch first {
        case 0x03: self = .request
        case 0x02: self = .enabled
        default: self = .other(first)
        }
    }
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: Float) {
        appendLittleEndian(value.bitPattern)
    }
}
