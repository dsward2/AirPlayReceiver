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

        public init(deviceName: String, udpHost: String = "127.0.0.1", udpPort: UInt16, password: String? = nil) {
            self.deviceName = deviceName
            self.udpHost = udpHost
            self.udpPort = udpPort
            self.password = password
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

    private var preflightError: Error?
    private var configuration: Configuration
    private let pipelineManager = TaskPipelineManager()
    /// Pending async launch; cancelled and replaced on each new `start()` call so
    /// rapid successive calls never race to start two pipeline instances at once.
    private var startTask: Task<Void, Never>?

    /// Forwards this controller's own diagnostic messages plus its pipeline
    /// stages' relayed stderr (source = each stage's `functionName`), so a
    /// host app can pipe AirPlay receiver activity into its own logging
    /// system without this package depending on a concrete log type.
    public var onLog: ((_ source: String, _ message: String) -> Void)? {
        didSet { pipelineManager.onLog = onLog }
    }

    public init(configuration: Configuration) {
        self.configuration = configuration
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
        guard pipelineManager.status == .running else { return }
        pipelineManager.terminate()
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

        let receiver = pipelineManager.makeTaskItem(pathToExecutable: executablePath, functionName: "shairport-sync")
        for arg in ShairportSyncArguments.make(deviceName: configuration.deviceName, password: configuration.password) {
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

        pipelineManager.add(receiver)
        pipelineManager.add(resample)
        pipelineManager.add(udpSender)

        do {
            try pipelineManager.start()
        } catch {
            preflightError = error
        }
    }

    /// Applies a new configuration, restarting the receiver if it was running.
    public func updateConfiguration(_ newConfiguration: Configuration) {
        let wasRunning = isRunning
        configuration = newConfiguration
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
