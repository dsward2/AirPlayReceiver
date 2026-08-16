// swift-tools-version: 5.9
import PackageDescription
import Foundation

// AirPlayReceiver — a shared AirPlay 1 (RAOP) audio-receiver package for
// AntennaHead and ControlBooth.
//
// Wraps a vendored `shairport-sync` binary (classic AirPlay 1 only — AirPlay 2
// isn't supported on macOS by shairport-sync itself) and feeds its decoded PCM
// into the same pipeline architecture the two apps already use for rtl_fm:
//
//     shairport-sync (--output=stdout)  ->  sox (resample 44100 -> 48000)  ->  PCMUDPSender
//
// built with PipelineHelpers' TaskItem/TaskPipelineManager, exactly like
// AntennaHead's SDRController assembles its rtl_fm chain.

// Use the local PipelineHelpers sibling when building from the umbrella monorepo;
// fall back to GitHub when used standalone.
// Use #file (absolute path to this manifest) so the sibling check works regardless
// of what directory SwiftPM sets as CWD during manifest evaluation.
let _manifestDir = URL(fileURLWithPath: #file).deletingLastPathComponent()
let pipelineHelpersDep: Package.Dependency = FileManager.default.fileExists(
    atPath: _manifestDir.appendingPathComponent("../PipelineHelpers/Package.swift").standardized.path
) ? .package(path: "../PipelineHelpers")
  : .package(url: "https://github.com/dsward2/PipelineHelpers", branch: "main")

let package = Package(
    name: "AirPlayReceiver",
    platforms: [
        // AirPlayReceiverController uses @Observable (Observation framework),
        // matching PipelineHelpers' own minimum.
        .macOS(.v14)
    ],
    products: [
        .library(name: "AirPlayReceiver", targets: ["AirPlayReceiver"])
    ],
    dependencies: [
        pipelineHelpersDep,
    ],
    targets: [
        .target(
            name: "AirPlayReceiver",
            dependencies: [
                .product(name: "PipelineRunner", package: "PipelineHelpers")
            ],
            resources: [
                // The vendored shairport-sync binary plus a Frameworks/
                // subfolder of its bundled dylibs (install names rewritten to
                // @executable_path/../Frameworks/..., matching the same
                // convention AntennaHead already uses for its own vendored
                // dylibs). Regenerate with scripts/build-shairport-sync.sh.
                .copy("Resources")
            ]
        ),
        .testTarget(
            name: "AirPlayReceiverTests",
            dependencies: ["AirPlayReceiver"]
        )
    ]
)
