import Foundation
import Observation
import PipelineRunner

/// Runs a vendored `shairport-sync` (AirPlay 1 / RAOP) helper and forwards its
/// decoded PCM to a UDP destination, for embedding in a host app's own audio
/// pipeline.
///
///     shairport-sync (--output=stdout, 44100 Hz/16-bit/stereo)
///       -> sox (resample to 48000 Hz)
///       -> PCMUDPSender (--host --port --exit-with-parent)
///
/// built with `TaskPipelineManager`/`TaskItem` from PipelineHelpers, the same
/// way AntennaHead's `SDRController` assembles its rtl_fm chain. Callers embed
/// this package's `Resources/shairport-sync` binary in their app bundle's
/// `Contents/Helpers/` (see the package README) so it resolves the same way
/// every other pipeline helper does.
@MainActor
@Observable
public final class AirPlayReceiverController {
    public struct Configuration {
        public var deviceName: String
        public var udpHost: String
        public var udpPort: UInt16
        public var password: String?
        /// Initial relay state the PCMUDPSender stage launches with. Live
        /// toggles after launch go through `setRelayEnabled(_:)`, not a
        /// reconfigure — see that method's doc comment.
        public var relayEnabled: Bool

        public init(deviceName: String, udpHost: String = "127.0.0.1", udpPort: UInt16, password: String? = nil,
                    relayEnabled: Bool = true) {
            self.deviceName = deviceName
            self.udpHost = udpHost
            self.udpPort = udpPort
            self.password = password
            self.relayEnabled = relayEnabled
        }
    }

    /// Current track's title/artist, from shairport-sync's metadata pipe
    /// (`--with-metadata`). `nil` when nothing is known (no session, or
    /// metadata not yet received for the current one).
    public struct NowPlayingTrack: Equatable, Sendable {
        public var title: String?
        public var artist: String?
        public init(title: String? = nil, artist: String? = nil) {
            self.title = title
            self.artist = artist
        }
    }

    public enum AirPlayReceiverError: Error, CustomStringConvertible {
        case executableMissing(String)
        case startFailed(String)

        public var description: String {
            switch self {
            case .executableMissing(let path): return "shairport-sync executable not found at \(path)."
            case .startFailed(let m): return "AirPlay receiver failed to start: \(m)"
            }
        }
    }

    /// PCM format shairport-sync emits on its stdout output backend.
    private static let inputSampleRate = 44_100
    private static let inputChannels = 2
    /// Output format matching LiveAudioServer's UDP-input contract (see
    /// LiveAudioServerProcessManager in AntennaHead).
    private static let outputSampleRate = 48_000
    private static let outputChannels = 2
    /// Local-only UDP port PCMUDPSender's `--control-port` binds, for live
    /// relay mute/unmute (see `setRelayEnabled`). Fixed rather than
    /// negotiated: this socket never leaves the host and nothing else in
    /// this process tree uses it.
    private static let relayControlPort: UInt16 = 6029
    /// How often `isReceivingAudio` re-checks the session marker file.
    private static let sessionMarkerPollInterval: UInt64 = 1_000_000_000

    /// Reflects the pipeline manager's live state rather than a snapshot taken
    /// at `start()` — otherwise a stage that dies later (e.g. shairport-sync
    /// losing a port-5000 race to another AirPlay receiver, detected by the
    /// pipeline manager's liveness monitor a few seconds in) would leave
    /// `isRunning`/`lastError` stuck reporting the launch-time result forever.
    public var isRunning: Bool { pipelineManager.status == .running }
    public var lastError: Error? {
        preflightError ?? pipelineManager.lastFailure.map {
            AirPlayReceiverError.startFailed("\($0.functionName) exited unexpectedly (status \($0.terminationStatus)): \($0.reason)")
        }
    }

    /// Whether the currently-running (or about-to-run) PCMUDPSender stage is
    /// forwarding to `configuration.udpHost`/`udpPort`. Changed live via
    /// `setRelayEnabled(_:)`, independent of `isRunning`/`stop()`/`start()` —
    /// shairport-sync stays connected to its AirPlay source the whole time.
    public private(set) var relayEnabled: Bool
    /// Whether an AirPlay client is actively streaming right now (as opposed
    /// to just connected/idle, or nothing connected at all). Polled from a
    /// marker file shairport-sync's `-B`/`-E` hooks touch/remove — see
    /// `startSessionMarkerPolling`.
    public private(set) var isReceivingAudio = false
    /// See `NowPlayingTrack`. Updated live as shairport-sync's metadata pipe
    /// reports items; cleared when the current session ends.
    public private(set) var nowPlayingTrack: NowPlayingTrack?
    /// Fires whenever `nowPlayingTrack` actually changes (including to/from
    /// `nil`), so a host app can push the update elsewhere (e.g. ControlBooth
    /// announcing it to AntennaHead) without polling.
    public var onNowPlayingChange: ((NowPlayingTrack?) -> Void)?

    private var preflightError: Error?
    private var configuration: Configuration
    private let pipelineManager = TaskPipelineManager()
    /// Pending async launch; cancelled and replaced on each new `start()` call so
    /// rapid successive calls never race to start two pipeline instances at once.
    private var startTask: Task<Void, Never>?
    /// Polls `currentSessionMarkerPath` for `isReceivingAudio`; cancelled and
    /// restarted with each `launchPipeline()`, cancelled outright in `stop()`.
    private var sessionMarkerPollTask: Task<Void, Never>?
    /// Unique per launch — shairport-sync's `-B`/`-E` hooks touch/remove this
    /// exact path, so a stale poll from a previous launch can't read a marker
    /// left behind (or missing) from the wrong process generation.
    private var currentSessionMarkerPath: String?
    /// The metadata FIFO's `readabilityHandler`; torn down and recreated with
    /// each launch alongside the session marker poll.
    private var metadataFileHandle: FileHandle?
    private var currentMetadataPipePath: String?
    /// Title/artist accumulate independently as shairport-sync's metadata
    /// pipe reports each one separately; combined into `nowPlayingTrack`
    /// (and the change callback) after each update.
    private var pendingTrackTitle: String?
    private var pendingTrackArtist: String?

    /// Forwards this controller's own diagnostic messages plus its pipeline
    /// stages' relayed stderr (source = each stage's `functionName`), so a
    /// host app can pipe AirPlay receiver activity into its own logging
    /// system without this package depending on a concrete log type.
    public var onLog: ((_ source: String, _ message: String) -> Void)? {
        didSet { pipelineManager.onLog = onLog }
    }

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.relayEnabled = configuration.relayEnabled
    }

    /// Resolves the vendored `shairport-sync` helper embedded in the host app's
    /// bundle, matching every other pipeline helper's lookup convention.
    public static var shairportSyncExecutableURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/shairport-sync")
    }

    public func start() {
        // Capture dying process references before stop() clears them, so the
        // async wait below can confirm they've released OS resources (port 5000)
        // before the new pipeline tries to bind the same port.
        let dyingProcesses = pipelineManager.taskItems.compactMap { $0.process }.filter { $0.isRunning }
        stop()

        startTask?.cancel()
        startTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            if !dyingProcesses.isEmpty {
                await Self.waitForExit(dyingProcesses, timeout: 2.5)
                guard !Task.isCancelled else { return }
            }
            await Self.waitForTCPPortFree(5000, onLog: self.onLog)
            guard !Task.isCancelled else { return }
            self.launchPipeline()
        }
    }

    public func stop() {
        startTask?.cancel()
        startTask = nil
        stopSessionMarkerPolling()
        stopMetadataPipeReading()
        guard pipelineManager.status == .running else { return }
        pipelineManager.terminate()
    }

    /// Mutes or unmutes the PCMUDPSender stage without restarting anything —
    /// shairport-sync stays connected to its AirPlay source and sox keeps
    /// resampling the whole time, so toggling this produces no audio glitch
    /// or reconnect on the AirPlay client's end. A no-op (beyond updating the
    /// published state, so a subsequent `start()`/`updateConfiguration` picks
    /// up the requested value) when nothing is running yet.
    public func setRelayEnabled(_ enabled: Bool) {
        relayEnabled = enabled
        configuration.relayEnabled = enabled
        guard isRunning else { return }
        Self.sendControlCommand(enabled ? "relay on" : "relay off", port: Self.relayControlPort)
    }

    /// Fire-and-forget UDP send to PCMUDPSender's `--control-port`, same
    /// raw-socket style as `isTCPPortFree` below.
    private static func sendControlCommand(_ text: String, port: UInt16) {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr) == 1 else { return }
        _ = text.withCString { cString in
            withUnsafePointer(to: &addr) { rawAddr in
                rawAddr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddr in
                    sendto(sock, cString, strlen(cString), 0, sockAddr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Starts (re)polling `path` for `isReceivingAudio`, replacing any poll
    /// left over from a previous launch.
    private func startSessionMarkerPolling(path: String) {
        sessionMarkerPollTask?.cancel()
        isReceivingAudio = false
        sessionMarkerPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let exists = FileManager.default.fileExists(atPath: path)
                if exists != self.isReceivingAudio {
                    self.isReceivingAudio = exists
                    // A session just ended: clear stale title/artist rather
                    // than leaving the last-played track showing while idle.
                    if !exists {
                        self.pendingTrackTitle = nil
                        self.pendingTrackArtist = nil
                        self.updateNowPlayingTrack()
                    }
                }
                try? await Task.sleep(nanoseconds: Self.sessionMarkerPollInterval)
            }
        }
    }

    private func stopSessionMarkerPolling() {
        sessionMarkerPollTask?.cancel()
        sessionMarkerPollTask = nil
        isReceivingAudio = false
        if let currentSessionMarkerPath {
            try? FileManager.default.removeItem(atPath: currentSessionMarkerPath)
        }
        currentSessionMarkerPath = nil
    }

    /// Opens shairport-sync's metadata FIFO (created here, before launch —
    /// see `launchPipeline`'s `mkfifo` — rather than left to shairport-sync,
    /// so it's guaranteed to exist the instant this reads from it) and wires
    /// a `readabilityHandler` that extracts `<item>...</item>` blocks as they
    /// arrive. Opened `O_NONBLOCK` so this never blocks the caller waiting
    /// for shairport-sync to open its write end (which happens moments later,
    /// once the pipeline is actually running).
    ///
    /// Item format (undocumented but stable across shairport-sync releases):
    /// `<item><type>HEX</type><code>HEX</code><length>N</length>[<data
    /// encoding="base64">B64</data>]</item>`, where `type`/`code` are
    /// hex-encoded 4-character tags — e.g. `type=core` (`636f7265`),
    /// `code=minm` (`6d696e6d`, track title) or `asar` (artist). Only those
    /// two are currently used; everything else (album, genre, ssnc/* control
    /// markers, artwork, …) is ignored.
    private func startMetadataPipeReading(path: String) {
        pendingTrackTitle = nil
        pendingTrackArtist = nil
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else {
            onLog?("AirPlayReceiverController", "open() failed for metadata pipe at \(path): \(String(cString: strerror(errno)))")
            return
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        metadataFileHandle = handle
        let buffer = MetadataItemBuffer()
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            let items = buffer.appendAndExtractItems(data)
            guard !items.isEmpty else { return }
            Task { @MainActor in
                for item in items {
                    self?.handleMetadataItem(item)
                }
            }
        }
    }

    private func stopMetadataPipeReading() {
        metadataFileHandle?.readabilityHandler = nil
        try? metadataFileHandle?.close()
        metadataFileHandle = nil
        if let currentMetadataPipePath {
            unlink(currentMetadataPipePath)
        }
        currentMetadataPipePath = nil
        pendingTrackTitle = nil
        pendingTrackArtist = nil
        updateNowPlayingTrack()
    }

    private func handleMetadataItem(_ text: String) {
        guard let typeHex = Self.extractTag("type", from: text),
              let codeHex = Self.extractTag("code", from: text) else { return }
        guard Self.hexToASCII(typeHex) == "core" else { return }
        let code = Self.hexToASCII(codeHex)
        guard code == "minm" || code == "asar" else { return }
        let value = Self.extractBase64Data(from: text)
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        if code == "minm" {
            pendingTrackTitle = value
        } else {
            pendingTrackArtist = value
        }
        updateNowPlayingTrack()
    }

    private func updateNowPlayingTrack() {
        let newValue: NowPlayingTrack? = (pendingTrackTitle != nil || pendingTrackArtist != nil)
            ? NowPlayingTrack(title: pendingTrackTitle, artist: pendingTrackArtist) : nil
        guard newValue != nowPlayingTrack else { return }
        nowPlayingTrack = newValue
        onNowPlayingChange?(newValue)
    }

    private static func extractTag(_ tag: String, from text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    private static func extractBase64Data(from text: String) -> String? {
        guard let open = text.range(of: "<data encoding=\"base64\">"),
              let close = text.range(of: "</data>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    private static func hexToASCII(_ hex: String) -> String {
        var result = ""
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index..<next], radix: 16) {
                result.append(Character(Unicode.Scalar(byte)))
            }
            index = next
        }
        return result
    }

    /// Accumulates bytes from the metadata pipe's `readabilityHandler`
    /// (invoked off the main actor) and extracts complete `<item>...</item>`
    /// blocks — same locked-buffer approach `TaskPipelineManager` uses for
    /// stderr line buffering, and for the same reason (a plain captured `var`
    /// mutated from that closure is a Swift 6 concurrency error, not just a
    /// style warning).
    private final class MetadataItemBuffer: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        private static let terminator = Data("</item>".utf8)

        func appendAndExtractItems(_ newData: Data) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            data.append(newData)
            var items: [String] = []
            while let range = data.range(of: Self.terminator) {
                let itemData = data.subdata(in: data.startIndex..<range.upperBound)
                data.removeSubrange(data.startIndex..<range.upperBound)
                if let text = String(data: itemData, encoding: .utf8) {
                    items.append(text)
                }
            }
            return items
        }
    }

    /// Waits (non-blocking) for all processes to exit, then SIGKILLs any that
    /// outlast the timeout. Ensures port 5000 is free before a replacement
    /// shairport-sync tries to bind it.
    private static func waitForExit(_ processes: [Process], timeout: TimeInterval) async {
        var alive = processes.filter { $0.isRunning }
        let deadline = Date().addingTimeInterval(timeout)
        while !alive.isEmpty && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            alive = alive.filter { $0.isRunning }
        }
        for proc in alive {
            kill(proc.processIdentifier, SIGKILL)
        }
        if !alive.isEmpty {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Polls until TCP port is available to bind, up to `timeout` seconds.
    private static func waitForTCPPortFree(_ port: UInt16, timeout: TimeInterval = 2.0,
                                           onLog: ((_ source: String, _ message: String) -> Void)? = nil) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !isTCPPortFree(port) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if !isTCPPortFree(port) {
            let message = "TCP port \(port) still in use after \(timeout)s; proceeding anyway"
            print("AirPlayReceiverController: \(message)")
            onLog?("AirPlayReceiverController", message)
        }
    }

    private static func isTCPPortFree(_ port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return true }
        defer { close(sock) }
        var reuseAddr: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = 0
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private func launchPipeline() {
        preflightError = nil

        let executablePath = Self.shairportSyncExecutableURL.path
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            preflightError = AirPlayReceiverError.executableMissing(executablePath)
            return
        }

        let sessionMarkerPath = NSTemporaryDirectory()
            .appending("airplay-receiver-session-\(UUID().uuidString).active")
        let metadataPipePath = NSTemporaryDirectory()
            .appending("airplay-receiver-metadata-\(UUID().uuidString).pipe")
        // Created here rather than left to shairport-sync so it's guaranteed
        // to exist before startMetadataPipeReading() opens it below. A
        // failure here is non-fatal to the receiver as a whole — audio still
        // works without a metadata pipe, so just skip that part rather than
        // failing the whole launch.
        unlink(metadataPipePath)
        let metadataPipeCreated = mkfifo(metadataPipePath, 0o600) == 0
        if !metadataPipeCreated {
            onLog?("AirPlayReceiverController",
                   "mkfifo failed for metadata pipe at \(metadataPipePath): \(String(cString: strerror(errno))) — track metadata will be unavailable this session")
        } else {
            // Open *our* read end before shairport-sync ever launches, not
            // after: shairport-sync opens its write end non-blocking at
            // startup and, per POSIX FIFO semantics, a non-blocking open for
            // writing fails outright (ENXIO) if no reader is attached yet —
            // it doesn't retry later. Opening late here meant every session's
            // metadata silently vanished for the entire run, confirmed by
            // tapping the raw pipe live (a continuously looping playlist
            // produced zero bytes for the whole session on the old ordering).
            currentMetadataPipePath = metadataPipePath
            startMetadataPipeReading(path: metadataPipePath)
        }

        let receiver = pipelineManager.makeTaskItem(pathToExecutable: executablePath, functionName: "shairport-sync")
        for arg in ShairportSyncArguments.make(deviceName: configuration.deviceName, password: configuration.password,
                                               sessionMarkerPath: sessionMarkerPath, metadataPipePath: metadataPipePath) {
            receiver.addArgument(arg)
        }

        guard let resample = makeResampleTaskItem() else {
            return  // lastError already set by the failing builder
        }

        // Resolved the same way every other pipeline helper is (SDRController,
        // ControlBooth's PipelineRunner): Bundle.main.path(forAuxiliaryExecutable:)
        // — used by TaskPipelineManager.makeTaskItem(executableName:) — does not
        // reliably find Contents/Helpers executables, so build the path directly.
        let udpSenderPath = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PCMUDPSender").path
        guard FileManager.default.isExecutableFile(atPath: udpSenderPath) else {
            preflightError = AirPlayReceiverError.executableMissing(udpSenderPath)
            return
        }
        let udpSender = pipelineManager.makeTaskItem(pathToExecutable: udpSenderPath, functionName: "PCMUDPSender")
        udpSender.addArgument("--host"); udpSender.addArgument(configuration.udpHost)
        udpSender.addArgument("--port"); udpSender.addArgument(Int(configuration.udpPort))
        udpSender.addArgument("--exit-with-parent")
        udpSender.addArgument("--control-port"); udpSender.addArgument(Int(Self.relayControlPort))
        udpSender.addArgument("--relay"); udpSender.addArgument(configuration.relayEnabled ? "on" : "off")

        pipelineManager.add(receiver)
        pipelineManager.add(resample)
        pipelineManager.add(udpSender)

        do {
            try pipelineManager.start()
        } catch {
            preflightError = error
            stopMetadataPipeReading()
            return
        }
        currentSessionMarkerPath = sessionMarkerPath
        startSessionMarkerPolling(path: sessionMarkerPath)
    }

    /// Applies a new configuration, restarting the receiver if it was
    /// running. `newConfiguration.relayEnabled` becomes the value the
    /// restarted (or next-started) PCMUDPSender launches with; call this with
    /// the current `relayEnabled` (not necessarily the value passed to
    /// `init`) to avoid a restart reverting a live `setRelayEnabled` toggle.
    public func updateConfiguration(_ newConfiguration: Configuration) {
        let wasRunning = isRunning
        configuration = newConfiguration
        relayEnabled = newConfiguration.relayEnabled
        if wasRunning {
            start()
        }
    }

    /// sox stage: resamples shairport-sync's fixed 44100 Hz/stereo stdout to
    /// the 48000 Hz/2-channel LiveAudioServer UDP-input contract.
    private func makeResampleTaskItem() -> TaskItem? {
        let item: TaskItem
        do {
            item = try pipelineManager.makeSoxTaskItem()
        } catch {
            preflightError = error
            return nil
        }

        item.addArgument("-V2")
        item.addArgument("-q")

        // Without an explicit --buffer, sox falls back to its default (large
        // enough to add several hundred ms of latency at this rate), which
        // shows up as sluggishness switching to/resuming AirPlay playback.
        // Size it for ~50 ms of audio instead, matching SDRController's radio
        // pipeline (see its makeResampleTaskItem for the same rationale).
        let blockBytes = max(1024, Self.inputSampleRate * Self.inputChannels * 2 / 20)
        item.addArgument("--buffer"); item.addArgument(blockBytes)

        item.addArgument("-r"); item.addArgument(Self.inputSampleRate)
        item.addArgument("-e"); item.addArgument("signed-integer")
        item.addArgument("-b"); item.addArgument(16)
        item.addArgument("-c"); item.addArgument(Self.inputChannels)
        item.addArgument("-t"); item.addArgument("raw")
        item.addArgument("-")

        item.addArgument("-e"); item.addArgument("signed-integer")
        item.addArgument("-b"); item.addArgument(16)
        item.addArgument("-c"); item.addArgument(Self.outputChannels)
        item.addArgument("-t"); item.addArgument("raw")
        item.addArgument("-")

        item.addArgument("rate"); item.addArgument(Self.outputSampleRate)
        return item
    }
}
