import Foundation
import Testing

@testable import HydraCoaster

// HydraCoasterTests runs hosted by the HydraCoaster.app target (see
// project.yml TEST_HOST/BUNDLE_LOADER) — SwiftData's ModelContainer needs a
// real app bundle context, so `@testable import` replaces the earlier
// standalone-compiled-sources pattern.
struct CoasterProtocolTests {

    // MARK: - Weight decode

    @Test func weightDecode_positiveGramsAndFlags() {
        // grams_x10=1234 (LE D2 04), flags=0b101 (settled+clockSynced), stddev_x10=25 (LE 19 00)
        let data = Data([0xD2, 0x04, 0b101, 0x19, 0x00])
        let reading = CoasterDecode.weightReading(from: data)
        #expect(reading == WeightReading(grams: 123.4, settled: true, cupPresent: false, clockSynced: true, stddev: 2.5))
    }

    @Test func weightDecode_negativeGrams() {
        // grams_x10=-505 (LE 07 FE), flags=0b010 (cup only), stddev_x10=0
        let data = Data([0x07, 0xFE, 0b010, 0x00, 0x00])
        let reading = CoasterDecode.weightReading(from: data)
        #expect(reading == WeightReading(grams: -50.5, settled: false, cupPresent: true, clockSynced: false, stddev: 0.0))
    }

    @Test func weightDecode_allFlagsSet() {
        let data = Data([0x00, 0x00, 0b111, 0x00, 0x00])
        let reading = CoasterDecode.weightReading(from: data)
        #expect(reading?.settled == true)
        #expect(reading?.cupPresent == true)
        #expect(reading?.clockSynced == true)
    }

    @Test func weightDecode_wrongLength_returnsNil() {
        #expect(CoasterDecode.weightReading(from: Data([0x00, 0x00, 0x00, 0x00])) == nil)
        #expect(CoasterDecode.weightReading(from: Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00])) == nil)
        #expect(CoasterDecode.weightReading(from: Data()) == nil)
    }

    // MARK: - Sip decode

    @Test func sipDecode_normalPacket() throws {
        // seq=300 (LE 2C 01 00 00), ts=1_000_000 (LE 40 42 0F 00), grams_x10=999 (LE E7 03)
        let data = Data([0x2C, 0x01, 0x00, 0x00, 0x40, 0x42, 0x0F, 0x00, 0xE7, 0x03])
        let packet = try #require(CoasterDecode.sipPacket(from: data))
        #expect(packet == SipPacket(seq: 300, unixTs: 1_000_000, grams: 99.9))
        #expect(!packet.isTerminator)
    }

    @Test func sipDecode_terminatorPacket() throws {
        let data = Data(repeating: 0x00, count: 10)
        let packet = try #require(CoasterDecode.sipPacket(from: data))
        #expect(packet == SipPacket(seq: 0, unixTs: 0, grams: 0))
        #expect(packet.isTerminator)
    }

    @Test func sipDecode_unrecoverableTimestamp_isNotTerminator() throws {
        // seq=7 (nonzero), ts=0 (unrecoverable), grams_x10=1205 (LE B5 04)
        let data = Data([0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xB5, 0x04])
        let packet = try #require(CoasterDecode.sipPacket(from: data))
        #expect(packet == SipPacket(seq: 7, unixTs: 0, grams: 120.5))
        #expect(!packet.isTerminator)
    }

    @Test func sipDecode_wrongLength_returnsNil() {
        #expect(CoasterDecode.sipPacket(from: Data(repeating: 0, count: 9)) == nil)
        #expect(CoasterDecode.sipPacket(from: Data(repeating: 0, count: 11)) == nil)
    }

    // MARK: - Command status decode

    @Test func commandStatusDecode_allResults() {
        #expect(CoasterDecode.commandStatus(from: Data([0x01, 0x00]))?.result == .ok)
        #expect(CoasterDecode.commandStatus(from: Data([0x01, 0x01]))?.result == .noSignal)
        #expect(CoasterDecode.commandStatus(from: Data([0x03, 0x02]))?.result == .loadTooSmall)
        #expect(CoasterDecode.commandStatus(from: Data([0x03, 0x03]))?.result == .badCommand)
        #expect(CoasterDecode.commandStatus(from: Data([0x01, 0x09]))?.result == .unknown(0x09))
    }

    @Test func commandStatusDecode_wrongLength_returnsNil() {
        #expect(CoasterDecode.commandStatus(from: Data([0x01])) == nil)
        #expect(CoasterDecode.commandStatus(from: Data([0x01, 0x00, 0x00])) == nil)
    }

    // MARK: - Encode

    @Test func encodeTime_isLittleEndianUnixSeconds() {
        let seconds: UInt32 = 1_700_000_000
        let expected = Data([
            UInt8(seconds & 0xFF),
            UInt8((seconds >> 8) & 0xFF),
            UInt8((seconds >> 16) & 0xFF),
            UInt8((seconds >> 24) & 0xFF),
        ])
        let data = CoasterEncode.time(Date(timeIntervalSince1970: TimeInterval(seconds)))
        #expect(data == expected)
    }

    @Test func encodeInterval() {
        #expect(CoasterEncode.interval(seconds: 1200) == Data([0xB0, 0x04]))
        #expect(CoasterEncode.interval(seconds: 0) == Data([0x00, 0x00]))
    }

    @Test func encodePrefs() {
        #expect(CoasterEncode.prefs(CoasterPrefs(sound: true, led: false, remind: true)) == Data([0b101]))
        #expect(CoasterEncode.prefs(CoasterPrefs(sound: true, led: true, remind: true)) == Data([0b111]))
        #expect(CoasterEncode.prefs(CoasterPrefs(sound: false, led: false, remind: false)) == Data([0b000]))
    }

    @Test func encodeSipBackfillRequest() {
        #expect(CoasterEncode.sipBackfillRequest(afterSeq: 42) == Data([0x2A, 0x00, 0x00, 0x00]))
    }

    @Test func encodeCommand_buzzAndTare() {
        #expect(CoasterEncode.command(.buzz) == Data([0x01]))
        #expect(CoasterEncode.command(.tare) == Data([0x02]))
    }

    @Test func encodeCommand_calibrate_200Grams() {
        // 200.0 g -> grams_x10 = 2000 = 0x07D0 -> LE D0 07
        #expect(CoasterEncode.command(.calibrate(grams: 200.0)) == Data([0x03, 0xD0, 0x07]))
    }

    @Test func encodeCommand_calibrate_otherValue() {
        // 55.5 g -> grams_x10 = 555 = 0x022B -> LE 2B 02
        #expect(CoasterEncode.command(.calibrate(grams: 55.5)) == Data([0x03, 0x2B, 0x02]))
    }

    @Test func encodeQuietWindow() {
        // start=1320 (22:00) = 0x0528 -> LE 28 05, end=420 (07:00) = 0x01A4 -> LE A4 01
        #expect(CoasterEncode.quietWindow(startMin: 1320, endMin: 420) == Data([0x28, 0x05, 0xA4, 0x01]))
    }

    @Test func encodeQuietWindow_disabled() {
        #expect(CoasterEncode.quietWindow(startMin: 0, endMin: 0) == Data([0x00, 0x00, 0x00, 0x00]))
    }
}
