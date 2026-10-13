import CoreBluetooth
import Observation
import CanonProtocol

nonisolated struct DiscoveredCamera: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let rssi: Int
}

nonisolated enum BluetoothPower: Sendable, Equatable {
    case unknown, poweredOn, poweredOff, unauthorized, unsupported
}

/// Owns the `CBCentralManager`.
///
/// Background auto-start works the same way as Sony's app: the central is
/// created with a restore identifier and keeps a *pending* `connect` to the
/// paired camera. Pending connects never time out, so when the camera powers
/// on iOS connects to it and relaunches the app in the background if needed.
@Observable
final class CameraBLEManager: NSObject {
    nonisolated enum Event: Sendable {
        case power(BluetoothPower)
        case connected(UUID)
        case disconnected(UUID, reason: String?)
        case failedToConnect(UUID, reason: String?)
    }

    static let restoreIdentifier = "com.rafaelfrancisco.CanonGeotag.central"

    private(set) var power: BluetoothPower = .unknown
    private(set) var isScanning = false
    private(set) var discovered: [DiscoveredCamera] = []

    @ObservationIgnored let events: AsyncStream<Event>
    @ObservationIgnored private let eventContinuation: AsyncStream<Event>.Continuation
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var links: [UUID: PeripheralLink] = [:]
    @ObservationIgnored private var restoredConnected: Set<UUID> = []

    override init() {
        (events, eventContinuation) = AsyncStream.makeStream(of: Event.self)
        super.init()
    }

    /// Creates the central. Must run during `didFinishLaunching` so that state
    /// restoration can deliver `willRestoreState` on a background relaunch.
    func activate() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
    }

    /// Issues a pending connection that survives app suspension.
    func connect(to id: UUID) {
        guard let central, central.state == .poweredOn else { return }
        let peripheral = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
        guard let peripheral else { return }
        peripherals[id] = peripheral
        switch peripheral.state {
        case .connected:
            eventContinuation.yield(.connected(id))
        case .connecting:
            break
        default:
            central.connect(peripheral)
        }
    }

    func cancelConnection(to id: UUID) {
        links.removeValue(forKey: id)?.invalidate()
        if let peripheral = peripherals.removeValue(forKey: id) {
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    func link(for id: UUID) -> PeripheralLink? {
        guard let peripheral = peripherals[id], peripheral.state == .connected else { return nil }
        if let link = links[id] { return link }
        let link = PeripheralLink(peripheral: peripheral)
        links[id] = link
        return link
    }

    // MARK: Pairing scan (foreground only)

    func startScan() {
        guard let central, central.state == .poweredOn, !isScanning else { return }
        discovered = []
        isScanning = true
        // No service filter: some bodies only advertise the Canon service while
        // in "Add a device" mode, so also accept anything named "EOS…".
        central.scanForPeripherals(withServices: nil)
    }

    func stopScan() {
        guard isScanning else { return }
        central?.stopScan()
        isScanning = false
    }
}

// Main-actor isolated conformance; see PeripheralLink. `queue: nil` means
// CoreBluetooth delivers every callback on the main queue.
extension CameraBLEManager: @MainActor CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let power: BluetoothPower = switch central.state {
        case .poweredOn: .poweredOn
        case .poweredOff, .resetting: .poweredOff
        case .unauthorized: .unauthorized
        case .unsupported: .unsupported
        default: .unknown
        }
        self.power = power
        if power != .poweredOn {
            isScanning = false
            links.values.forEach { $0.invalidate() }
            links.removeAll()
        }
        eventContinuation.yield(.power(power))

        if power == .poweredOn {
            for id in restoredConnected { eventContinuation.yield(.connected(id)) }
            restoredConnected.removeAll()
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for peripheral in restored {
            peripherals[peripheral.identifier] = peripheral
            if peripheral.state == .connected {
                restoredConnected.insert(peripheral.identifier)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        let isCanon = services.contains(CBUUID(string: CanonUUID.primaryService)) || name.hasPrefix("EOS")
        guard isCanon else { return }

        peripherals[peripheral.identifier] = peripheral
        let camera = DiscoveredCamera(id: peripheral.identifier, name: name.isEmpty ? "Canon camera" : name,
                                      rssi: RSSI.intValue)
        if let index = discovered.firstIndex(where: { $0.id == camera.id }) {
            discovered[index] = camera
        } else {
            discovered.append(camera)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        eventContinuation.yield(.connected(peripheral.identifier))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: (any Error)?) {
        links.removeValue(forKey: peripheral.identifier)?.invalidate()
        eventContinuation.yield(.disconnected(peripheral.identifier, reason: error?.localizedDescription))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: (any Error)?) {
        eventContinuation.yield(.failedToConnect(peripheral.identifier, reason: error?.localizedDescription))
    }
}
