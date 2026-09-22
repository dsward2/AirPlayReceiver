import Foundation

/// Builds the vendored `shairport-sync` binary's argv from a plain config
/// struct, so the exact CLI flags this package relies on are centralized in
/// one reviewable place.
///
/// Built with `--with-ssl=openssl --with-dns_sd --with-stdout --with-pipe
/// --with-soxr --with-metadata` and no `--with-airplay-2` (see
/// scripts/build-shairport-sync.sh) — classic AirPlay 1 (RAOP) only, emitting
/// raw S16LE 44100 Hz stereo PCM on stdout, plus a metadata pipe for track
/// title/artist/album (see `AirPlayReceiverController`'s metadata-pipe reader).
enum ShairportSyncArguments {
    /// - Parameter sessionMarkerPath: a file path shairport-sync's `-B`/`-E`
    ///   hooks touch when a play session begins and remove when it ends (via
    ///   `/usr/bin/touch`/`/bin/rm -f`, run through its own shell so no new
    ///   helper binary is needed). The caller polls for the file's existence
    ///   to know whether an AirPlay client is actively streaming, as opposed
    ///   to just connected/idle. No `-w`/`--wait-cmd`: the hook runs
    ///   fire-and-forget so it can't add latency to playback starting/stopping.
    /// - Parameter metadataPipePath: a FIFO shairport-sync writes track
    ///   metadata to while `--with-metadata` is compiled in — see
    ///   `AirPlayReceiverController.startMetadataPipeReading`.
    static func make(deviceName: String, password: String?, sessionMarkerPath: String,
                     metadataPipePath: String) -> [String] {
        // No --configfile is passed: shairport-sync's default config path won't
        // resolve in this embedded context, which it already handles gracefully
        // (falls back to built-in defaults) rather than erroring out.
        var args: [String] = [
            "-a", deviceName,
            "-o", "stdout",
            "-B", "/usr/bin/touch '\(sessionMarkerPath)'",
            "-E", "/bin/rm -f '\(sessionMarkerPath)'",
            "--metadata-enable",
            "--metadata-pipename", metadataPipePath
        ]
        if let password, !password.isEmpty {
            args.append(contentsOf: ["--password", password])
        }
        return args
    }
}
