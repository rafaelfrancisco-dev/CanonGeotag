import CoreBluetooth
import CanonProtocol

nonisolated enum BLEError: LocalizedError, Sendable {
    case busy
    case timeout
    case disconnected
    case missingCharacteristic(String)
    case pairingRejected
    case pairingTimedOut
    case gatt(String)

    var errorDescription: String? {
        switch self {
        case .busy: "Another Bluetooth operation is in progress"
        case .timeout: "Bluetooth operation timed out"
        case .disconnected: "Camera disconnected"
        case .missingCharacteristic(let uuid): "Camera is missing characteristic \(uuid)"
        case .pairingRejected: "Pairing was rejected on the camera"
        case .pairingTimedOut: "Pairing was not confirmed on the camera"
        case .gatt(let message): message
        }
    }
}

/// async/await wrapper around one connected `CBPeripheral`.
///
/// CoreBluetooth delivers callbacks on the main queue (see `CameraBLEManager`),
/// so the delegate conformance is main-actor isolated. Operations are strictly
/// sequential: exactly one continuation can be pending at a time.
final class PeripheralLink: NSObject {
    let peripheral: CBPeripheral
    var identifier: UUID { peripheral.identifier }

    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var indicationStreams: [String: AsyncStream<Data>.Continuation] = [:]
    private var pending: Pending?
    private var nextOperationID = 0

    private struct Pending {
        let id: Int
        let continuation: CheckedContinuation<Void, any Error>
        let timeout: Task<Void, Never>
    }

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        super.init()
        peripheral.delegate = self
    }

    /// Discovers the Canon services and all of their characteristics.
    func discover() async throws {
        characteristics.removeAll()
        try await perform { peripheral.discoverServices(CanonUUID.services.map(CBUUID.init(string:))) }
        for service in peripheral.services ?? [] {
            try await perform { peripheral.discoverCharacteristics(nil, for: service) }
            for characteristic in service.characteristics ?? [] {
                characteristics[characteristic.uuid] = characteristic
            }
        }
    }

    func write(_ write: HandshakeWrite) async throws {
        try await self.write(write.value, to: write.characteristic)
    }

    func write(_ data: Data, to uuid: String) async throws {
        let characteristic = try characteristic(uuid)
        try await perform { peripheral.writeValue(data, for: characteristic, type: .withResponse) }
    }

    /// Enables indications and returns a stream of their values. The stream
    /// finishes when the link is invalidated.
    func indications(from uuid: String) async throws -> AsyncStream<Data> {
        let characteristic = try characteristic(uuid)
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        indicationStreams[characteristic.uuid.uuidString]?.finish()
        indicationStreams[characteristic.uuid.uuidString] = continuation
        try await perform { peripheral.setNotifyValue(true, for: characteristic) }
        return stream
    }

    /// Fails any in-flight operation and ends all indication streams.
    func invalidate(_ error: any Error = BLEError.disconnected) {
        if let pending { resolve(pending.id, .failure(error)) }
        indicationStreams.values.forEach { $0.finish() }
        indicationStreams.removeAll()
    }

    // MARK: - Continuation plumbing

    private func characteristic(_ uuid: String) throws -> CBCharacteristic {
        guard let characteristic = characteristics[CBUUID(string: uuid)] else {
            throw BLEError.missingCharacteristic(uuid)
        }
        return characteristic
    }

    private func perform(timeout: Duration = .seconds(15), _ start: () -> Void) async throws {
        guard pending == nil else { throw BLEError.busy }
        guard peripheral.state == .connected else { throw BLEError.disconnected }
        nextOperationID += 1
        let id = nextOperationID
        try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.resolve(id, .failure(BLEError.timeout))
            }
            pending = Pending(id: id, continuation: continuation, timeout: timeoutTask)
            start()
        }
    }

    private func resolve(_ id: Int, _ result: Result<Void, any Error>) {
        guard let pending, pending.id == id else { return }
        self.pending = nil
        pending.timeout.cancel()
        pending.continuation.resume(with: result)
    }

    private func completePending(_ error: (any Error)?) {
        guard let pending else { return }
        resolve(pending.id, error.map { .failure(BLEError.gatt($0.localizedDescription)) } ?? .success(()))
    }
}

// Main-actor isolated conformance: the central uses `queue: nil`, so
// CoreBluetooth calls these on the main queue, in order (a write's completion
// is handled before any following indication). Swift verifies the isolation
// at runtime, and non-Sendable CoreBluetooth objects never cross actors.
extension PeripheralLink: @MainActor CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        completePending(error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: (any Error)?) {
        completePending(error)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                    error: (any Error)?) {
        completePending(error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: (any Error)?) {
        completePending(error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: (any Error)?) {
        guard error == nil, let value = characteristic.value else { return }
        indicationStreams[characteristic.uuid.uuidString]?.yield(value)
    }
}
