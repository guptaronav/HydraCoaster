import CoreBluetooth
import Observation
import os

enum ManagerState: Equatable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn

    init(_ state: CBManagerState) {
        switch state {
        case .unknown: self = .unknown
        case .resetting: self = .resetting
        case .unsupported: self = .unsupported
        case .unauthorized: self = .unauthorized
        case .poweredOff: self = .poweredOff
        case .poweredOn: self = .poweredOn
        @unknown default: self = .unknown
        }
    }
}

enum ConnectionState: Equatable {
    case disconnected
    case scanning
    case connecting
    case connected
}

/// Owns the single CBCentralManager for the app. All CoreBluetooth callbacks
/// are delivered on the main queue (passed explicitly at init) so mutating
/// @Observable state here is always main-thread safe without extra hops.
@Observable
final class CoasterClient: NSObject {
    private static let restoreIdentifier = "com.ronav.HydraCoaster.central"
    private static let knownPeripheralKey = "com.ronav.HydraCoaster.knownPeripheralID"

    private enum GATT {
        static let service = CBUUID(string: CoasterUUID.service)
        static let liveWeight = CBUUID(string: CoasterUUID.liveWeight)
        static let sipLog = CBUUID(string: CoasterUUID.sipLog)
        static let time = CBUUID(string: CoasterUUID.time)
        static let interval = CBUUID(string: CoasterUUID.interval)
        static let prefs = CBUUID(string: CoasterUUID.prefs)
        static let command = CBUUID(string: CoasterUUID.command)
        static let status = CBUUID(string: CoasterUUID.status)
        static let batteryService = CBUUID(string: CoasterUUID.batteryService)
        static let batteryLevel = CBUUID(string: CoasterUUID.batteryLevel)

        static let notifyTargets: Set<CBUUID> = [liveWeight, sipLog, status, batteryLevel]
    }

    private let logger = Logger(subsystem: "com.ronav.HydraCoaster", category: "CoasterClient")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private let sipContinuation: AsyncStream<SipPacket>.Continuation

    private(set) var managerState: ManagerState = .unknown
    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var latestWeight: WeightReading?
    private(set) var batteryPercent: Int?
    private(set) var lastCommandStatus: CommandStatus?

    /// Sip events (backfill, terminator, then live) as they're notified. One
    /// consumer expected (T4's sync pipeline).
    let sipEvents: AsyncStream<SipPacket>

    override init() {
        var continuation: AsyncStream<SipPacket>.Continuation!
        sipEvents = AsyncStream { continuation = $0 }
        sipContinuation = continuation
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
        )
    }

    // MARK: - Public API

    func startScanning() {
        guard managerState == .poweredOn else {
            logger.info("startScanning ignored, manager state \(String(describing: self.managerState))")
            return
        }
        connectionState = .scanning
        central.scanForPeripherals(withServices: [GATT.service], options: nil)
        logger.info("scanning for \(GATT.service)")
    }

    func connect(to peripheral: CBPeripheral) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        connectionState = .connecting
        central.connect(peripheral, options: nil)
        logger.info("connecting to \(peripheral.identifier)")
    }

    func disconnect() {
        guard let peripheral else { return }
        central.cancelPeripheralConnection(peripheral)
    }

    func requestBackfill(after seq: UInt32) {
        logger.info("requesting backfill after seq=\(seq)")
        write(CoasterEncode.sipBackfillRequest(afterSeq: seq), to: GATT.sipLog)
    }

    func write(interval seconds: UInt16) {
        write(CoasterEncode.interval(seconds: seconds), to: GATT.interval)
    }

    func write(prefs: CoasterPrefs) {
        write(CoasterEncode.prefs(prefs), to: GATT.prefs)
    }

    func sendCommand(_ command: CoasterCommand) {
        write(CoasterEncode.command(command), to: GATT.command)
    }

    // MARK: - Internals

    private func write(_ data: Data, to uuid: CBUUID) {
        guard let peripheral, let characteristic = characteristics[uuid] else {
            logger.error("write to \(uuid) failed: characteristic unavailable")
            return
        }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: characteristic, type: type)
    }

    private func writeTime() {
        write(CoasterEncode.time(), to: GATT.time)
        logger.info("wrote time sync")
    }

    private func attemptReconnect() {
        guard managerState == .poweredOn else { return }
        if let idString = UserDefaults.standard.string(forKey: Self.knownPeripheralKey),
           let id = UUID(uuidString: idString),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(to: known)
        } else {
            startScanning()
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension CoasterClient: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        managerState = ManagerState(central.state)
        logger.info("manager state -> \(String(describing: central.state.rawValue))")
        if managerState == .poweredOn {
            attemptReconnect()
        } else {
            connectionState = .disconnected
        }
    }

    // ponytail: v1 assumes one coaster per phone, so the first advertisement
    // matching the service UUID auto-connects. A picker UI (T5 onboarding)
    // would replace this with collecting candidates and calling connect(to:)
    // from the UI instead.
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        connect(to: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logger.info("connected: \(peripheral.identifier)")
        connectionState = .connected
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.knownPeripheralKey)
        characteristics.removeAll()
        peripheral.discoverServices([GATT.service, GATT.batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logger.error("failed to connect: \(error?.localizedDescription ?? "unknown")")
        connectionState = .disconnected
        attemptReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logger.info("disconnected: \(error?.localizedDescription ?? "clean")")
        connectionState = .disconnected
        latestWeight = nil
        batteryPercent = nil
        attemptReconnect()
    }

    /// Only meaningful on-device (background relaunch after the system kills
    /// the app). The simulator never invokes this, so there's nothing to
    /// guard beyond handling an empty/missing peripherals list gracefully.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        logger.info("willRestoreState")
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let peripheral = restored.first else { return }
        self.peripheral = peripheral
        peripheral.delegate = self
        if peripheral.state == .connected {
            // didConnect never fires for an already-connected peripheral, so
            // rediscover here: the normal discovery path repopulates the
            // characteristics map, re-arms notifies, and re-writes time.
            connectionState = .connected
            characteristics.removeAll()
            peripheral.discoverServices([GATT.service, GATT.batteryService])
        } else {
            connectionState = .connecting
        }
    }
}

// MARK: - SipSource (T4 sync engine bridge)

extension CoasterClient: SipSource {
    var isConnected: Bool { connectionState == .connected }
}

// MARK: - CBPeripheralDelegate

extension CoasterClient: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services else {
            logger.error("service discovery failed: \(error?.localizedDescription ?? "unknown")")
            return
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let chars = service.characteristics else {
            logger.error("characteristic discovery failed: \(error?.localizedDescription ?? "unknown")")
            return
        }
        for characteristic in chars {
            characteristics[characteristic.uuid] = characteristic
            if GATT.notifyTargets.contains(characteristic.uuid) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        if service.uuid == GATT.service {
            writeTime()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            logger.error("subscribe FAILED for \(characteristic.uuid): \(error.localizedDescription)")
        } else {
            logger.info("subscribed: \(characteristic.uuid), notifying=\(characteristic.isNotifying)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        switch characteristic.uuid {
        case GATT.liveWeight:
            if let reading = CoasterDecode.weightReading(from: data) {
                latestWeight = reading
            }
        case GATT.sipLog:
            if let packet = CoasterDecode.sipPacket(from: data) {
                logger.info("sip packet: seq=\(packet.seq) ts=\(packet.unixTs) grams=\(packet.grams)")
                sipContinuation.yield(packet)
            } else {
                logger.error("sip packet decode failed, \(data.count) bytes")
            }
        case GATT.status:
            if let status = CoasterDecode.commandStatus(from: data) {
                lastCommandStatus = status
            }
        case GATT.batteryLevel:
            batteryPercent = data.first.map(Int.init)
        default:
            break
        }
    }
}
