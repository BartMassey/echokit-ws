# EchoKit Firmware — Developer Orientation

## What this is

`echokit_box` is the firmware for EchoKit, a voice-assistant device
built around the **ESP32-S3**. It captures speech over a microphone,
streams it to a remote EchoKit server
(`github.com/second-state/echokit_server`) over a WebSocket, plays
back Opus-compressed TTS audio, and renders a GIF-driven
avatar/status UI on an attached color LCD. The firmware is written
in Rust on top of ESP-IDF (`esp-idf-svc` 0.51) using **`std`**, with
Tokio's current-thread runtime driving the async side and dedicated
FreeRTOS tasks doing real-time audio.

Source of truth for specifics:

- Crate manifest: `Cargo.toml`
- Entry point: `src/main.rs`
- State machine: `src/app.rs`
- Wire protocol types: `src/protocol.rs`

## Build / toolchain

- **Target:** `xtensa-esp32s3-espidf` (Xtensa fork of Rust;
  `rust-toolchain.toml` pins channel `esp`). `init.sh` installs
  `rustup`, `espup`, `espflash`, `ldproxy`, and `cargo-generate`.
- **Build system:** `build.rs` is a one-liner that hands off to
  `embuild::espidf::sysenv::output()`. ESP-IDF is vendored in via
  `esp-idf-svc` and the custom components listed in `Cargo.toml`
  under `[[package.metadata.esp-idf-sys.extra_components]]`:
  - `espressif/esp-sr` — AFE/VAD/AEC/AGC and wake-word models.
  - `78/esp-opus` — Opus encoder/decoder.
  - Local `components/hal_driver` — C drivers (I²C, ES8311 codec,
    XL9555 GPIO expander, parallel LCD) exposed to Rust via bindgen
    headers in `components/*/bindgen.h` /
    `components/hal_driver/wrapper.h`.
- **Flash layout:** `partitions.csv` — 16 MB flash with NVS (2 M),
  factory app (5 M), and a 3 M `model` SPIFFS partition where
  `esp-sr` models live.
- **sdkconfig:** `sdkconfig.defaults` enables SPI-RAM (OCT mode),
  1 kHz FreeRTOS tick, NimBLE, and selects SR models (`NSN_NSNET2`,
  `VADN_VADNET1_MEDIUM`, `WN9_HIESP`).
- **Feature flags** (in `Cargo.toml`) select the board variant:
  `boards` (default devkit), `box` (integrated enclosure), `cube` /
  `cube2`, plus `nfc_cube2`, `voice_interrupt`, `custom_ui`,
  `extra_server`. Only one board feature may be active at a time —
  `box`/`cube`/`cube2` all pull in `_no_default` to suppress
  `boards`. `package.sh` builds each of the three main variants and
  uses `espflash save-image --merge` to produce a single flashable
  image per variant.

## Source tree

```
src/
  main.rs         490  Boot, NVS load, provisioning decision, runtime spawn
  app.rs          567  State machine: Listening / Waiting / Speaking / Idle
  audio.rs        776  I2S + esp-sr AFE; capture and playback workers
  ws.rs           318  WebSocket client (tokio-websockets); Opus decode
  ui.rs           417  embedded-graphics rendering, GIF player, u8g2 fonts
  bt.rs           323  esp32-nimble BLE GATT provisioning server
  protocol.rs      67  ServerEvent / ClientCommand enums (msgpack + JSON)
  network.rs       85  WiFi station setup
  codec/opus.rs  1257  Safe Rust wrappers over 78/esp-opus bindings
  boards/
    mod.rs        617  Board abstraction; `start_hal!` / `start_audio_workers!` macros
    atom_box.rs   719  `box` variant: ES8311 + XL9555 + parallel LCD 320x240
    cube2.rs      322  `cube2` variant: dual I2S + SPI ST7789 240x240
    cube.rs       238  `cube` variant
    base.rs       259  `boards` devkit (DIY)
components/
  hal_driver/        C drivers: I2C, ES8311, XL9555, parallel LCD (~1600 LOC)
  esp_sr/            bindgen header only (remote component)
  78_opus/           bindgen header only (remote component)
```

Board selection uses macros (`start_hal!`, `start_audio_workers!`
in `boards/mod.rs`) that expand differently per feature flag, so
`main.rs` and `app.rs` stay hardware-agnostic.

## Architecture and data flow

### Boot sequence (`main.rs`)

1. Take ESP peripherals, mount eventfs VFS, open NVS namespace
   `"setting"`.
2. `Setting::load_from_nvs` reads `ssid`, `pass`, `server_url`,
   two GIF blobs (`background_gif`, `avatar_gif`), AFE tuning
   (`afe_linear_gain`, `agc_tl_dbfs`, `agc_cg_db`), and a `state`
   flag. `DEFAULT_SERVER_URL` can be baked in at compile time via
   env var (`main.rs:58`).
3. Start HAL workers (LCD, buttons, I²C), render the background
   GIF.
4. **Provisioning branch** — if button K0 is held at boot or
   `need_init()` is true (missing ssid/pass/server, or `state==1`):
   start the BLE GATT server (`bt::bt`), show a setup screen
   pointing at `https://echokit.dev/setup/`, and the device name
   `EchoKit-<MAC>`. A companion web app writes config into the
   GATT characteristics; each write persists to NVS. After setup
   the device self-restarts (`esp_restart`).
5. **Normal branch** — apply AFE tuning globals, `network::wifi(...)`
   to connect, `ws::Server::new` to dial the configured WebSocket
   URL (sends `dev_id` plus query params for opus / vowel /
   stream_asr). WiFi or WebSocket failure writes `state=1` and
   reboots into setup.
6. Spawn the audio workers (`start_audio_workers!`), spawn a
   button listener that debounces K0 into `Event::K0` (short) or
   `Event::K0_` (long-hold), and `block_on(app::main_work(...))`.

### Runtime loop (`app.rs`)

`app::main_work` runs a state machine over an mpsc event stream
combining:

- `Event::MicAudioChunk(Vec<i16>)` from the AFE worker
- `Event::K0` / `Event::K0_` from button driver
- `Event::ServerEvent(...)` from the WebSocket task (deserialised
  MessagePack `ServerEvent`)
- `Event::ServerUrl(...)` (only with `extra_server` feature)

States are **Idle → Listening → Waiting → Speaking → Idle**. K0
starts a turn: the device sends a `ClientCommand::StartChat`
(JSON over a text frame), plays a local "hello" beep, toggles
`VAD_ACTIVE`, and begins streaming 16 kHz mono i16 mic chunks as
binary frames. With `voice_interrupt`, holding K0 during TTS
playback cancels playback.

### Audio (`audio.rs`)

Capture and playback each run on pinned FreeRTOS tasks (Core 1)
spawned from the board module. The capture path feeds PCM into the
ESP-SR **AFE** (AEC + NS + AGC + VAD) configured
`AGC_MODE_WEBRTC` / `AEC_MODE_VOIP_HIGH_PERF` / `VAD_MODE_4`. AFE
output drains into a `sync_channel` and is shipped to Tokio as
`Event::MicAudioChunk`. Playback consumes a `SendBuffer` fed by
`ServerEvent::AudioChunki16` (decoded Opus samples) and writes via
I²S to the speaker codec. Tuning constants (`AFE_LINEAR_GAIN`,
`AGC_TARGET_LEVEL_DBFS`, `AGC_COMPRESSION_GAIN_DB`) are `static
mut` set at boot from NVS — changing them at runtime needs a
restart.

### Protocol (`src/protocol.rs`)

The wire format is asymmetric. **Server → device** is MessagePack
(`rmp_serde`) in binary frames; **device → server** uses JSON for
control (text frames) and raw PCM bytes for audio (binary frames).

```rust
enum ServerEvent {
    HelloStart, HelloChunk { data: Vec<u8> }, HelloEnd,
    ASR { text: String },
    Action { action: String },
    StartAudio { text: String },
    AudioChunk { data: Vec<u8> },                     // opus
    AudioChunkWithVowel { data: Vec<u8>, vowel: u8 }, // opus + mouth shape
    AudioChunki16 { data: Vec<i16>, vowel: u8 },      // post-decode internal
    EndAudio, StartVideo, EndVideo, EndResponse, EndVad,
}

#[serde(tag = "event")]
enum ClientCommand { StartRecord, StartChat, Submit, Text { input: String } }
```

`ws.rs` owns the client connection, does reconnect-with-retry, and
decodes Opus before forwarding `AudioChunki16` onward. The `vowel`
byte drives avatar mouth animation in `ui.rs`.

### UI (`ui.rs` + `boards/*.rs`)

RGB565 framebuffer drawn with `embedded-graphics`; text via
`u8g2-fonts`; GIF animation via the `image` crate. Two GIFs are
user-configurable over BLE: a static background and the avatar.
`boards::ui::new_chat_ui` builds a `ChatUI` with state text
("Listening…", "Thinking…") and a text region that shows ASR
results and server URL errors. QR code for the provisioning URL
comes from the `qrcode` crate.

## Configuration

All persistent config lives in the NVS namespace `"setting"`:

| Key                  | Type  | Source                                            |
|----------------------|-------|---------------------------------------------------|
| `ssid`, `pass`       | str   | BLE GATT write                                    |
| `server_url`         | str   | BLE, or `DEFAULT_SERVER_URL` env at compile time  |
| `background_gif`     | blob  | BLE chunked upload                                |
| `avatar_gif`         | blob  | BLE chunked upload                                |
| `afe_linear_gain`    | blob  | BLE (4-byte f32 LE)                               |
| `agc_tl_dbfs`        | i32   | BLE                                               |
| `agc_cg_db`          | i32   | BLE                                               |
| `state`              | u8    | internal (1 = force setup)                        |

The GATT server (`bt.rs`) exposes ~11 characteristics under one
service; the companion web app at `echokit.dev/setup/` is the
primary UI. To force re-provisioning the firmware writes `state=1`
and reboots, which takes the `need_init()` branch in `main.rs`.

## Key dependencies

- `esp-idf-svc` 0.51 — WiFi, I²S, GPIO, NVS, HTTP.
- `tokio` 1.43 (`rt`, `net`, `time`, `io-*`, `macros`) —
  single-thread runtime.
- `tokio-websockets` 0.13 (`client`, `sha1_smol`) — WS client.
- `esp32-nimble` 0.11 — BLE peripheral stack.
- `embedded-graphics` / `embedded-text` / `u8g2-fonts` — UI
  primitives.
- `image` (png/gif/webp) — animated background/avatar.
- `rmp-serde`, `serde_json`, `serde` — wire formats.
- `qrcode`, optional `ndef` (NFC on `nfc_cube2`).

## Where to make common changes

- **Add or change a server event:** edit `src/protocol.rs`, then
  add a handler branch in `app::main_work` (`src/app.rs`) and, if
  it carries audio, wire decode in `src/ws.rs`.
- **Tune audio behavior:** `src/audio.rs` — AFE mode, VAD
  threshold, buffer sizes, and the three AGC/gain statics. For
  per-device tuning prefer new NVS keys in
  `main.rs::Setting::load_from_nvs` + a matching BLE
  characteristic in `src/bt.rs`.
- **Support a new board:** add `src/boards/<name>.rs`, a Cargo
  feature entry, and arms in the `start_hal!` /
  `start_audio_workers!` macros in `src/boards/mod.rs`. Implement
  LCD init, button worker, and audio worker following
  `atom_box.rs` or `cube2.rs`.
- **Change the UI:** `src/ui.rs` for drawing primitives and GIF;
  `src/boards/<variant>/ui` (inside each board module) for the
  `ChatUI` layout.
- **Reconfigure flash layout / models:** `partitions.csv` and
  `sdkconfig.defaults` (note the `model` SPIFFS partition used by
  `esp-sr`).
- **Build for a variant:** `cargo build --release
  --no-default-features --features box` (or `cube2`, etc).
  `package.sh` does all three plus the merged image.

## Gotchas worth knowing up front

- The runtime is **current-thread Tokio**. Don't call blocking
  work from async tasks — the audio path already uses dedicated
  OS threads and sync channels on purpose.
- `ESP-SR` models and `esp-opus` are pulled as remote IDF
  components; first build is slow and cache-sensitive.
- Feature flags are mutually exclusive for boards (`box` pulls
  `_no_default`). Passing two at once won't compile cleanly.
- WiFi or server connection failure is a reboot-to-setup, not a
  retry loop. If you want soft-retry semantics, change the error
  path in `main.rs:376-416`.
- Several audio tuning knobs are `static mut` globals read once
  at boot (`main.rs:360-364`). Runtime tuning requires a restart
  unless you rework the access pattern.
