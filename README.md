# AirPlayReceiver

A Swift Package providing AirPlay 1 (classic RAOP) audio-receiver support,
shared between [AntennaHead](https://github.com/dsward2/AntennaHead) and
[ControlBooth](https://github.com/dsward2/ControlBooth).

It wraps a vendored `shairport-sync` binary and feeds its decoded PCM into the
same pipeline architecture both apps already use for `rtl_fm`:

```
shairport-sync (--output=stdout, 44100 Hz/16-bit/stereo)
  -> sox (resample to 48000 Hz)
  -> PCMUDPSender (--host --port --exit-with-parent)
```

assembled with `TaskItem`/`TaskPipelineManager` from
[PipelineHelpers](https://github.com/dsward2/PipelineHelpers), the same way
AntennaHead's `SDRController` builds its rtl_fm chain.

## Scope: AirPlay 1 only

This package deliberately supports classic AirPlay (RAOP) only, not AirPlay 2.
shairport-sync's own `configure.ac` notes AirPlay 2 isn't supported on macOS
(no working `nqptp` companion daemon), and AirPlay 2 additionally pulls in a
much larger dependency tree (ffmpeg, libsodium, glib) for no benefit here.

## Public API

`AirPlayReceiverController` (in `Sources/AirPlayReceiver/AirPlayReceiverController.swift`)
is a `@MainActor @Observable` class: construct it with a `Configuration`
(device name, UDP destination host/port, optional password), then call
`start()`/`stop()`/`updateConfiguration(_:)`. It resolves the vendored
`shairport-sync` binary at `Contents/Helpers/shairport-sync` in the host app's
bundle — see "Embedding" below for how it gets there.

## Embedding in a host app

The package resource bundle contains `shairport-sync` plus a `Frameworks/`
folder of its dylib dependencies (install names already rewritten to
`@executable_path/../Frameworks/<name>`, matching the same convention
AntennaHead already uses for its own vendored dylibs). Each host app needs one
Run Script build phase that copies:

- `shairport-sync` → `Contents/Helpers/shairport-sync` (chmod +x, ad-hoc codesign)
- everything in `Frameworks/` → `Contents/Frameworks/` (ad-hoc codesign each)

out of the resolved package's resource bundle
(`AirPlayReceiver_AirPlayReceiver.bundle`) in `$(BUILT_PRODUCTS_DIR)`.

## Important operational constraint: RTSP port 5000

Classic AirPlay (non-AirPlay-2) builds of shairport-sync hard-code RTSP port
**5000** (`shairport.c`, unconditional `config.port = 5000;` when
`CONFIG_AIRPLAY_2` isn't compiled in — a `--port`/config-file override has no
effect). Only one process on a Mac can hold that port.

**macOS's own built-in AirPlay Receiver** (System Settings → General → AirDrop
& Handoff → AirPlay Receiver) also listens on port 5000 via Control Center when
enabled. If it's on, this package's `shairport-sync` will fail to start with
`could not establish a service on port 5000`. Users who want ControlBooth or
AntennaHead to act as an AirPlay speaker need to turn macOS's built-in AirPlay
Receiver **off** first.

## Regenerating the vendored binary

Run `scripts/build-shairport-sync.sh` (requires MacPorts with `autoconf`,
`automake`, `libtool`, `pkgconfig`, `popt`, `libconfig-hr`, `openssl3`, `soxr`
installed — `sudo port install popt libconfig-hr` if missing). It downloads a
pinned, checksummed shairport-sync release, builds it with a minimal
`--with-ssl=openssl --with-dns_sd --with-stdout --with-pipe --with-soxr`
configuration (no `--with-metadata`/`--with-ffmpeg`/`--with-airplay-2`, which
would pull in ffmpeg for no benefit here), then bundles the resulting binary's
non-system dylib dependencies alongside it with rewritten install names.
Commit the resulting `Sources/AirPlayReceiver/Resources/` after regenerating.

**arm64-only for now.** Add an x86_64 MacPorts prefix + a `lipo` step to the
script if Intel Mac support is ever needed.
