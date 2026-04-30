#!/bin/sh
#
# BUILD.sh -- set up, fetch, or build-and-flash EchoKit DIY firmware.
#
# Three subcommands:
#   setup   One-time install of the ESP Rust toolchain (via espup)
#           and the flashing tools (espflash, cargo-espflash, ldproxy).
#   dist    Download the official prebuilt DIY firmware and flash it.
#           Useful as a known-good fallback.
#   custom  Build the firmware from this source tree and flash the
#           result. Assumes `setup` has been run.
#
# After flashing, the device boots into BLE provisioning mode on first
# run; use https://echokit.dev/setup/ to configure WiFi and the
# server URL.

# Exit on error; treat unset variables as errors.
set -eu

# Print usage to stderr and exit non-zero.
usage() {
    cat >&2 <<EOF
usage: $0 {setup|dist|custom}

  setup   Install the ESP Rust toolchain and flashing tools.
  dist    Download and flash the stock EchoKit DIY firmware.
  custom  Build the firmware in this tree and flash it.
EOF
    exit 1
}

# Require exactly one subcommand; reject bare invocation.
[ $# -ge 1 ] || usage

# espup writes ~/export-esp.sh, which exports LIBCLANG_PATH and a few
# related vars that the ESP-IDF bindgen step needs. Source it if it's
# there and we haven't already (LIBCLANG_PATH empty). On a fresh
# machine this file doesn't exist yet; that's fine -- `setup` creates
# it, and later invocations will pick it up.
if [ -z "${LIBCLANG_PATH:-}" ] && [ -f "$HOME/export-esp.sh" ]; then
    . "$HOME/export-esp.sh"
fi

case "$1" in
setup)
    # Install espup from /tmp rather than the project directory.
    # rust-toolchain.toml here pins the `esp` channel, which doesn't
    # exist until espup runs -- invoking cargo from inside the project
    # would fail trying to resolve that channel. /tmp is guaranteed
    # not to have a stray rust-toolchain.toml of its own.
    (cd /tmp && cargo install --locked espup)

    # Download and install the Xtensa Rust toolchain, LLVM, and the
    # GCC cross toolchain. Several GB; takes a while on first run.
    espup install

    # Install the flashing tools. Safe to run from the project dir
    # now that the `esp` channel exists.
    cargo install --locked cargo-espflash espflash ldproxy
    ;;
dist)
    # Fetch the latest prebuilt DIY firmware image. -L follows
    # redirects; -o names the output file.
    curl -L -o echokit-fw-dist https://echokit.dev/firmware/echokit_boards

    # Show attached serial ports so the user can confirm the device
    # is visible before flashing. On ESP32-S3 boards with two USB
    # ports, only the JTAG/SLAVE port is flashable.
    espflash list-ports

    # Flash at 16 MB (matches partitions.csv) and drop straight into
    # the serial monitor so boot logs are visible.
    #
    # After boot, point the device at ws://edge.echokit.dev/ws
    # (ws://indie.echokit.dev/ws in the US) via the setup portal.
    espflash flash --monitor --flash-size 16mb echokit-fw-dist
    ;;
custom)
    # Release build; default features select the DIY (`boards`)
    # variant. The binary lands under target/xtensa-esp32s3-espidf.
    cargo build --release

    # Stash a copy next to the script so the artifact is easy to
    # find, share, or re-flash without rebuilding.
    cp target/xtensa-esp32s3-espidf/release/echokit echokit-fw

    # Flash and monitor. Same 16 MB size as `dist`.
    espflash flash --monitor --flash-size 16mb echokit-fw
    ;;
*)
    # Unknown subcommand -- print usage and exit.
    usage
    ;;
esac
