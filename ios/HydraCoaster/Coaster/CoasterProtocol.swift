import Foundation

/// BLE UUIDs from `docs/ble-protocol.md`. Plain strings so this file stays
/// free of CoreBluetooth — CoasterClient turns these into CBUUID.
enum CoasterUUID {
    static let service = "AD0BD001-2A44-4E5B-9C8B-4B1E7C0D5E2A"
    static let liveWeight = "AD0BD002-2A44-4E5B-9C8B-4B1E7C0D5E2A"
    static let sipLog = "AD0BD003-2A44-4E5B-9C8B-4B1E7C0D5E2A"
    static let time = "AD0BD004-2A44-4E5B-9C8B-4B1E7C0D5E2A"
    static let interval = "AD0BD005-2A44-4E5B-9C8B-4B1E7C0D5E2A"
    static let prefs = "AD0BD006-2A44-4E5B-9C8B-4B1E7C0D5E2A"
    static let command = "AD0BD007-2A44-4E5B-9C8B-4B1E7C0D5E2A"
    static let status = "AD0BD008-2A44-4E5B-9C8B-4B1E7C0D5E2A"
    static let batteryService = "180F"
    static let batteryLevel = "2A19"
}

/// D002 — Live Weight (5 B): int16 grams_x10, uint8 flags, uint16 stddev_x10.
struct WeightReading: Equatable {
    let grams: Double
    let settled: Bool
    let cupPresent: Bool
    let clockSynced: Bool
    let stddev: Double
}

/// D003 — one Sip Log packet (10 B): uint32 seq, uint32 unix_ts, uint16 grams_x10.
/// A `seq == 0` packet is the backfill terminator (other fields are zero).
struct SipPacket: Equatable {
    let seq: UInt32
    let unixTs: UInt32
    let grams: Double

    var isTerminator: Bool { seq == 0 }
}

/// D008 — Command Status (2 B): uint8 last_cmd, uint8 result.
enum CommandResult: Equatable {
    case ok
    case noSignal
    case loadTooSmall
    case badCommand
    case unknown(UInt8)

    init(rawValue: UInt8) {
        switch rawValue {
        case 0: self = .ok
        case 1: self = .noSignal
        case 2: self = .loadTooSmall
        case 3: self = .badCommand
        default: self = .unknown(rawValue)
        }
    }
}

struct CommandStatus: Equatable {
    let lastCommand: UInt8
    let result: CommandResult
}

/// D006 — Prefs bitfield: b0 sound, b1 led, b2 remind.
struct CoasterPrefs: Equatable {
    var sound: Bool
    var led: Bool
    var remind: Bool
}

/// D007 — Command writes.
enum CoasterCommand: Equatable {
    case buzz
    case tare
    case calibrate(grams: Double)
    case resetSipLog
}

// MARK: - Little-endian helpers

private func uint16LE(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

private func uint32LE(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(uint16LE(bytes, offset)) | (UInt32(uint16LE(bytes, offset + 2)) << 16)
}

private func leBytes(_ value: UInt16) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8(value >> 8)]
}

private func leBytes(_ value: UInt32) -> [UInt8] {
    [
        UInt8(value & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 24) & 0xFF),
    ]
}

// MARK: - Decode

enum CoasterDecode {
    static func weightReading(from data: Data) -> WeightReading? {
        guard data.count == 5 else { return nil }
        let bytes = [UInt8](data)
        let gramsX10 = Int16(bitPattern: uint16LE(bytes, 0))
        let flags = bytes[2]
        let stddevX10 = uint16LE(bytes, 3)
        return WeightReading(
            grams: Double(gramsX10) / 10.0,
            settled: flags & 0b001 != 0,
            cupPresent: flags & 0b010 != 0,
            clockSynced: flags & 0b100 != 0,
            stddev: Double(stddevX10) / 10.0
        )
    }

    static func sipPacket(from data: Data) -> SipPacket? {
        guard data.count == 10 else { return nil }
        let bytes = [UInt8](data)
        let seq = uint32LE(bytes, 0)
        let unixTs = uint32LE(bytes, 4)
        let gramsX10 = uint16LE(bytes, 8)
        return SipPacket(seq: seq, unixTs: unixTs, grams: Double(gramsX10) / 10.0)
    }

    static func commandStatus(from data: Data) -> CommandStatus? {
        guard data.count == 2 else { return nil }
        let bytes = [UInt8](data)
        return CommandStatus(lastCommand: bytes[0], result: CommandResult(rawValue: bytes[1]))
    }
}

// MARK: - Encode

enum CoasterEncode {
    /// D004 — Time Sync: current Unix UTC seconds, 4 B LE.
    static func time(_ date: Date = Date()) -> Data {
        let seconds = UInt32(date.timeIntervalSince1970)
        return Data(leBytes(seconds))
    }

    /// D005 — Reminder Interval, 2 B LE.
    static func interval(seconds: UInt16) -> Data {
        Data(leBytes(seconds))
    }

    /// D006 — Prefs, 1 B bitfield.
    static func prefs(_ prefs: CoasterPrefs) -> Data {
        var byte: UInt8 = 0
        if prefs.sound { byte |= 0b001 }
        if prefs.led { byte |= 0b010 }
        if prefs.remind { byte |= 0b100 }
        return Data([byte])
    }

    /// D003 — backfill request: uint32 last_seq, 4 B LE.
    static func sipBackfillRequest(afterSeq seq: UInt32) -> Data {
        Data(leBytes(seq))
    }

    /// D007 — Command write.
    static func command(_ command: CoasterCommand) -> Data {
        switch command {
        case .buzz:
            return Data([0x01])
        case .tare:
            return Data([0x02])
        case .calibrate(let grams):
            let gramsX10 = UInt16((grams * 10).rounded())
            return Data([0x03] + leBytes(gramsX10))
        case .resetSipLog:
            return Data([0x04])
        }
    }
}
