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

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Resolves the vendored `shairport-sync` helper embedded in the host app's
    /// bundle, matching every other pipeline helper's lookup convention.
    public static var shairportSyncExecutableURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/shairport-sync")
    }

    public func start() {
        stop()
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

    public func stop() {
        guard pipelineManager.status == .running else { return }
        pipelineManager.terminate()
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
