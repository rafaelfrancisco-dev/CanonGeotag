import CoreBluetooth
import Observation
import CanonProtocol

nonisolated struct DiscoveredCamera: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    /// `nil` for a camera found already connected to this iPhone (for
    /// example by Canon Camera Connect), which doesn't advertise.
    let rssi: Int?
}

nonisolated enum BluetoothPower: Sendable, Equatable {
    case unknown, poweredOn, poweredOff, unauthorized, unsupported
}

/// Owns the `CBCentralManager`.
///
/// Background auto-start: the central is created with a restore identifier
/// and *watches* for the paired camera with a scan filtered by the Canon
/// service, which iOS keeps running (and relaunches the app for) in the
/// background.
///
/// It can't keep a pending `connect` the way Sony's app does: a Canon body
/// with Bluetooth enabled keeps advertising while switched off, and any
/// connection turns it on. So the app connects only once the advertisement's
/// status byte says the camera is on (see `CameraStatus`).
@Observable
final class CameraBLEManager: NSObject {
    nonisolated enum Event: Sendable {
        case power(BluetoothPower)
        case connected(UUID)
        case disconnected(UUID, reason: String?)
        case failedToConnect(UUID, reason: String?)
        /// The watched camera's advertised status changed.
        case status(UUID, CameraStatus)
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
    /// Restored pending connects from builds that connected blindly; cancelled
    /// once powered on, since completing them would turn the camera on.
    @ObservationIgnored private var restoredConnecting: Set<UUID> = []
    /// The paired camera, while waiting for it to turn on.
    @ObservationIgnored private var watchedID: UUID?
    @ObservationIgnored private var lastStatus: CameraStatus?

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

    /// Connects now. Only for a camera known to be on, such as one picked in
    /// the pairing list; otherwise use `watch(for:)`.
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

    /// Waits for the camera to turn on, then connects. Survives suspension and
    /// termination through state restoration.
    func watch(for id: UUID) {
        watchedID = id
        lastStatus = nil
        guard let central, central.state == .poweredOn else { return }
        // A camera another app (Canon Camera Connect) has connected is on, but
        // doesn't advertise.
        let service = CBUUID(string: CanonUUID.primaryService)
        if central.retrieveConnectedPeripherals(withServices: [service]).contains(where: { $0.identifier == id }) {
            stopWatching()
            connect(to: id)
            return
        }
        startWatchScan()
    }

    private func stopWatching() {
        watchedID = nil
        if !isScanning { central?.stopScan() }
    }

    /// Scans for the Canon service. While pairing, the unfiltered pairing scan
    /// covers it. In the background iOS reports each peripheral only once per
    /// scan, so the scan is restarted after every "off" advertisement to hear
    /// the next one.
    private func startWatchScan() {
        guard let central, central.state == .poweredOn, watchedID != nil, !isScanning else { return }
        central.stopScan()
        central.scanForPeripherals(withServices: [CBUUID(string: CanonUUID.primaryService)],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func cancelConnection(to id: UUID) {
        if watchedID == id { stopWatching() }
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
        addConnectedCameras()
    }

    /// Lists Canon cameras that another app, such as Canon Camera Connect,
    /// already has connected. iOS shares the Bluetooth bond between apps, and
    /// a connected camera stops advertising, so the scan alone never sees it.
    func addConnectedCameras() {
        guard let central, isScanning else { return }
        let service = CBUUID(string: CanonUUID.primaryService)
        for peripheral in central.retrieveConnectedPeripherals(withServices: [service])
        where !discovered.contains(where: { $0.id == peripheral.identifier }) {
            peripherals[peripheral.identifier] = peripheral
            discovered.append(DiscoveredCamera(id: peripheral.identifier, name: peripheral.name ?? "Canon camera",
                                               rssi: nil))
        }
    }

    func stopScan() {
        guard isScanning else { return }
        central?.stopScan()
        isScanning = false
        startWatchScan()
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
            for id in restoredConnecting {
                if let peripheral = peripherals[id] { central.cancelPeripheralConnection(peripheral) }
            }
            restoredConnecting.removeAll()
            for id in restoredConnected { eventContinuation.yield(.connected(id)) }
            restoredConnected.removeAll()
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for peripheral in restored {
            peripherals[peripheral.identifier] = peripheral
            switch peripheral.state {
            case .connected: restoredConnected.insert(peripheral.identifier)
            case .connecting: restoredConnecting.insert(peripheral.identifier)
            default: break
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if peripheral.identifier == watchedID {
            peripherals[peripheral.identifier] = peripheral
            handleWatched(peripheral, advertisementData: advertisementData)
        }
        guard isScanning else { return }
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

    private func handleWatched(_ peripheral: CBPeripheral, advertisementData: [String: Any]) {
        let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        // Without manufacturer data the state is unknown; keep waiting.
        guard let status = data.flatMap(CameraStatus.init(manufacturerData:)) else { return }
        if status != lastStatus {
            lastStatus = status
            eventContinuation.yield(.status(peripheral.identifier, status))
        }
        if status.allowsConnecting {
            stopWatching()
            connect(to: peripheral.identifier)
        } else {
            startWatchScan()
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
