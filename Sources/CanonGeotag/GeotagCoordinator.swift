import Foundation
import Observation
import CanonProtocol

enum ConnectionState: Equatable {
    case noCamera
    case waiting
    case connecting
    case connected(geotagging: Bool)
    case failed(String)

    var title: String {
        switch self {
        case .noCamera: "No camera paired"
        case .waiting: "Waiting for camera"
        case .connecting: "Connecting…"
        case .connected(true): "Geotagging"
        case .connected(false): "Connected, waiting for the camera"
        case .failed(let reason): reason
        }
    }
}

/// Ties the camera connection and the location source together and owns
/// every long-lived task in the app.
@Observable
final class GeotagCoordinator {
    static let shared = GeotagCoordinator()

    let ble = CameraBLEManager()
    let location = LocationProvider()
    let timeZone = TimeZoneMonitor()

    private(set) var state: ConnectionState = .noCamera
    private(set) var lastSent: GeoFix?
    private(set) var lastSentDate: Date?
    private(set) var log: [LogEntry] = []

    var mode: LocationMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Keys.mode)
            sessionInput?.yield(.modeChanged)
        }
    }

    private(set) var cameraID: UUID? {
        didSet { defaults.set(cameraID?.uuidString, forKey: Keys.cameraID) }
    }
    private(set) var cameraName: String? {
        didSet { defaults.set(cameraName, forKey: Keys.cameraName) }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let eventLog = EventLog()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []
    @ObservationIgnored private var session: Task<Void, Never>?
    @ObservationIgnored private var sessionInput: AsyncStream<SessionInput>.Continuation?

    private enum Keys {
        static let mode = "locationMode"
        static let cameraID = "cameraID"
        static let cameraName = "cameraName"
        static let appID = "appIdentity"
    }

    /// Name the camera shows for this phone.
    private static let deviceName = "CanonGeotag"
    private static let staleFix: TimeInterval = 5 * 60
    private static let goodAccuracy = 100.0
    private static let minimumMove = 15.0
    private static let resendInterval: TimeInterval = 60

    private nonisolated enum SessionInput: Sendable {
        case indication(Data)
        case fix(GeoFix)
        case gpsFinished
        case modeChanged
    }

    private init() {
        mode = defaults.string(forKey: Keys.mode).flatMap(LocationMode.init) ?? .hybrid
        cameraID = defaults.string(forKey: Keys.cameraID).flatMap(UUID.init)
        cameraName = defaults.string(forKey: Keys.cameraName)
        state = cameraID == nil ? .noCamera : .waiting
    }

    /// Persistent 16-byte identity the camera uses to recognise this phone.
    private var appID: UUID {
        if let id = defaults.string(forKey: Keys.appID).flatMap(UUID.init) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: Keys.appID)
        return id
    }

    // MARK: Lifecycle

    func start(launchReason: String) {
        guard !started else { return }
        started = true

        listeners.append(Task {
            let saved = await eventLog.load()
            log = saved + log
            record("Launched (\(launchReason))")
        })
        listeners.append(Task {
            for await event in ble.events { handle(event) }
        })
        listeners.append(Task {
            for await fix in location.fixes { sessionInput?.yield(.fix(fix)) }
        })
        listeners.append(Task { await timeZone.monitor() })

        location.start()
        ble.activate()
    }

    // MARK: Pairing

    func beginPairing() {
        location.requestAuthorization()
        Task { await timeZone.requestNotificationPermission() }
        ble.startScan()
    }

    func pair(with camera: DiscoveredCamera) {
        ble.stopScan()
        if let cameraID, cameraID != camera.id { forgetCamera() }
        cameraID = camera.id
        cameraName = camera.name
        state = .connecting
        timeZone.markCameraMatchesPhone()
        record("Pairing with \(camera.name)")
        ble.connect(to: camera.id)
    }

    func forgetCamera() {
        guard let cameraID else { return }
        endSession()
        ble.cancelConnection(to: cameraID)
        timeZone.forgetCamera()
        self.cameraID = nil
        cameraName = nil
        state = .noCamera
        record("Forgot camera")
    }

    func clearLog() {
        log.removeAll()
        Task { await eventLog.clear() }
    }

    // MARK: Bluetooth events

    private func handle(_ event: CameraBLEManager.Event) {
        switch event {
        case .power(let power):
            record("Bluetooth \(power)")
            if power == .poweredOn, let cameraID {
                ble.watch(for: cameraID)
            } else if power != .poweredOn {
                endSession()
                if cameraID != nil { state = .waiting }
            }

        case .connected(let id):
            guard id == cameraID, session == nil, let link = ble.link(for: id) else { return }
            record("Camera connected")
            state = .connecting
            session = Task { await runSession(link) }

        case .disconnected(let id, let reason):
            guard id == cameraID else { return }
            record("Camera disconnected" + (reason.map { ": \($0)" } ?? ""))
            endSession()
            state = .waiting
            ble.watch(for: id) // wait for the camera to turn on again

        case .failedToConnect(let id, let reason):
            guard id == cameraID else { return }
            record("Connection failed" + (reason.map { ": \($0)" } ?? ""))
            ble.watch(for: id)

        case .status(let id, let status):
            guard id == cameraID else { return }
            switch status {
            case .off: record("Camera is off, waiting for it to turn on")
            case .on: record("Camera turned on")
            case .other(let byte): record("Camera status 0x\(String(byte, radix: 16)), connecting")
            }
        }
    }

    private func endSession() {
        session?.cancel()
        session = nil
        sessionInput?.finish()
        sessionInput = nil
    }

    // MARK: Camera session

    /// One connection's lifetime: handshake, then a serial loop that answers
    /// camera indications and forwards location fixes. Cancelled on disconnect.
    private func runSession(_ link: PeripheralLink) async {
        let (inputs, input) = AsyncStream.makeStream(of: SessionInput.self, bufferingPolicy: .bufferingNewest(32))
        sessionInput = input
        defer {
            input.finish()
            session = nil
        }

        do {
            try await link.discover()
            let pairing = try await link.indications(from: CanonUUID.pairing)
            for write in Handshake.identify(deviceName: Self.deviceName, appID: appID) {
                try await link.write(write)
            }

            // The camera is assumed to be paired already (for example through
            // Canon Camera Connect's Bluetooth bond). Such a camera accepts the
            // phone without asking and usually sends no result, so only a
            // rejection stops the session.
            if try await firstPairResult(pairing, within: .seconds(3)) == .rejected {
                throw BLEError.pairingRejected
            }

            let geo = try await link.indications(from: CanonUUID.geoIndication)
            for write in Handshake.finish { try await link.write(write) }
            state = .connected(geotagging: false)
            record("Handshake complete")

            await withTaskGroup { group in
                group.addTask {
                    for await data in geo { input.yield(.indication(data)) }
                    input.finish() // link invalidated
                }

                var geoEnabled = false
                var gps: Task<Void, Never>?
                defer { gps?.cancel() }

                // Starts GPS per `mode` unless it's running or the last fix is still good.
                @MainActor func refreshLocation(force: Bool = false) {
                    guard geoEnabled, gps == nil else { return }
                    switch mode {
                    case .significantOnly:
                        return
                    case .hybrid where !force && location.latest.map(isFresh) == true:
                        return
                    case .hybrid:
                        gps = Task {
                            await location.preciseFix()
                            input.yield(.gpsFinished)
                        }
                    case .continuous:
                        gps = Task {
                            await location.continuousUpdates()
                            input.yield(.gpsFinished)
                        }
                    }
                }

                for await event in inputs {
                    switch event {
                    case .indication(let data):
                        switch GeoIndication(indication: data) {
                        case .request:
                            record("Camera requested location")
                            do { try await link.write(Handshake.enableGeo) } catch {
                                record("Enable failed: \(error.localizedDescription)")
                            }
                        case .enabled:
                            geoEnabled = true
                            state = .connected(geotagging: true)
                            record("Camera accepted location")
                            if let fix = location.latest { await send(fix, over: link, force: true) }
                            refreshLocation()
                        case .other(let byte):
                            record("Camera indication 0x\(String(byte, radix: 16))")
                        case nil:
                            break
                        }

                    case .fix(let fix):
                        guard geoEnabled else { break }
                        await send(fix, over: link)
                        // A coarse fix in hybrid mode is a significant change: refine it.
                        if mode == .hybrid, fix.horizontalAccuracy > Self.goodAccuracy { refreshLocation(force: true) }

                    case .gpsFinished:
                        gps = nil

                    case .modeChanged:
                        gps?.cancel()
                        gps = nil
                        refreshLocation()
                    }
                }
                group.cancelAll()
            }
        } catch is CancellationError {
        } catch {
            record("Session failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            if case BLEError.pairingRejected = error { forgetCamera() }
        }
    }

    private func isFresh(_ fix: GeoFix) -> Bool {
        fix.horizontalAccuracy <= Self.goodAccuracy && Date.now.timeIntervalSince(fix.timestamp) < Self.staleFix
    }

    /// Writes a fix unless it adds nothing over the last one sent
    /// (continuous GPS produces about one fix per second).
    private func send(_ fix: GeoFix, over link: PeripheralLink, force: Bool = false) async {
        if !force, let lastSent, let lastSentDate,
           fix.distance(to: lastSent) < Self.minimumMove,
           fix.horizontalAccuracy >= lastSent.horizontalAccuracy,
           Date.now.timeIntervalSince(lastSentDate) < Self.resendInterval {
            return
        }
        do {
            try await link.write(GeoPacket.encode(fix, sentAt: .now), to: CanonUUID.geoData)
            lastSent = fix
            lastSentDate = .now
            record("Sent \(fix.latitude.formatted(.number.precision(.fractionLength(5)))), "
                + "\(fix.longitude.formatted(.number.precision(.fractionLength(5)))) "
                + "±\(Int(fix.horizontalAccuracy)) m")
        } catch {
            record("Send failed: \(error.localizedDescription)")
        }
    }

    /// The camera's pairing result, or `nil` if it sends none within `limit`.
    /// Throws if the camera disconnects first.
    private func firstPairResult(_ stream: AsyncStream<Data>, within limit: Duration) async throws -> PairResult? {
        try await withThrowingTaskGroup(of: PairResult?.self) { group in
            group.addTask {
                for await data in stream {
                    if let result = PairResult(indication: data) { return result }
                }
                try Task.checkCancellation()
                throw BLEError.disconnected // stream ended: link invalidated
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    // MARK: Log

    private func record(_ message: String) {
        let entry = LogEntry(date: .now, message: message)
        log.append(entry)
        if log.count > EventLog.capacity { log.removeFirst(log.count - EventLog.capacity) }
        Task { await eventLog.append(entry) }
    }
}
