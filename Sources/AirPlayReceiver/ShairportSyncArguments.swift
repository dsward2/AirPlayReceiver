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
    /// Written to a file and passed with `-c` (see `make`'s `configFilePath`).
    ///
    /// `allow_session_interruption`: without it, a classic-AirPlay (RAOP)
    /// shairport-sync refuses — accepts then immediately closes — every new
    /// RTSP connection while any session still holds the play lock. Music.app
    /// on the same Mac could leave a session behind in exactly that state
    /// after pausing for more than a few seconds or switching its output away
    /// (the old RTSP socket sat in CLOSED, status stuck on "Receiving audio"),
    /// after which every reconnect failed with "The network connection was
    /// reset." until the receiver was restarted. With it, the next client's
    /// connection terminates the stale session and takes over.
    ///
    /// `session_timeout` is shairport-sync 5.1's own default, spelled out so
    /// it's reviewable here; 60 s is also the minimum it accepts (anything
    /// lower but non-zero is rejected with a warning and replaced by 60).
    /// Only settings with no command-line equivalent belong in this file —
    /// everything else stays in the argv below.
    static let configFileContents = """
        sessioncontrol =
        {
            allow_session_interruption = "yes";
            session_timeout = 60;
        };

        """

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
    /// - Parameter configFilePath: a file holding `configFileContents`, passed
    ///   with `-c`. `nil` omits `-c`, leaving shairport-sync on its built-in
    ///   defaults (its compiled-in default config path doesn't exist in this
    ///   embedded context, which it handles gracefully) — the receiver still
    ///   works, it just can't recover from a stale session without a restart.
    static func make(deviceName: String, password: String?, sessionMarkerPath: String,
                     metadataPipePath: String, configFilePath: String?) -> [String] {
        var args: [String] = []
        if let configFilePath {
            args.append(contentsOf: ["-c", configFilePath])
        }
        args += [
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
