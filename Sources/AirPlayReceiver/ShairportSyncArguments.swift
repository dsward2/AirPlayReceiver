import Foundation

/// Builds the vendored `shairport-sync` binary's argv from a plain config
/// struct, so the exact CLI flags this package relies on are centralized in
/// one reviewable place.
///
/// Built with `--with-ssl=openssl --with-dns_sd --with-stdout --with-pipe
/// --with-soxr` and no `--with-metadata`/`--with-airplay-2` (see
/// scripts/build-shairport-sync.sh) — classic AirPlay 1 (RAOP) only, emitting
/// raw S16LE 44100 Hz stereo PCM on stdout.
enum ShairportSyncArguments {
    static func make(deviceName: String, password: String?) -> [String] {
        // No --configfile is passed: shairport-sync's default config path won't
        // resolve in this embedded context, which it already handles gracefully
        // (falls back to built-in defaults) rather than erroring out.
        var args: [String] = [
            "-a", deviceName,
            "-o", "stdout"
        ]
        if let password, !password.isEmpty {
            args.append(contentsOf: ["--password", password])
        }
        return args
    }
}
