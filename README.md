# echokit-ws: Build Embedded Rust with AI — GOSIM Paris 2026
Bart Massey 2026

Here are most of the materials you will need to work with
the [EchoKit](https://echokit.dev) and play with Rust
Embedded at the [Build Embedded Rust with AI
Workshop](https://paris2026.gosim.org/schedule/build-embedded-rust-with-ai/)
at GOSIM Paris 2026.

## What You Need

* An EchoKit.

* A laptop with 10+GB of disk space, Bluetooth, and a USB 3
  port (Type A or USB-C). The EchoKit uses a lot of power,
  so you may have trouble with a USB 2 port.

## Set Up EchoKit

Use the Quick Start guide at
<https://echokit.dev/docs/get-started/echokit-diy>.

Use the conference WiFi and use `ws://edge.echokit.dev/ws`
as the EchoKit Server.

## Get Rust

Go to <https://rustup.rs> and follow the instructions there
to get Rust installed on your machine.

At this point, you may choose to skip to the **Linux
Quick Start** instructions below if you have Linux skill and
experience.

## Get an ESP-32 Rust Embedded Environment

*In this directory* (where this README is):

* Use `cargo install --locked espup` to get an ESP-32
  build environment. 

* Run `espup install` to set up the build environment.

* Run `cargo install --locked cargo-espflash espflash ldproxy`
  to get tools for running the built code on your box.

* *For a Linux or Mac host:* Source the environment
  variables needed by the build environment via
  `. "$HOME/export-esp.sh"`. Windows *should* be fine
  without this.

## Install Stock EchoKit Firmware

Move to the `echokit_boards` directory to get code running
on your EchoKit.

* You'll want
  <https://echokit.dev/firmware/echokit_boards>.
  Use `curl` if you have it via

  ```sh
  curl -L -o echokit-fw-dist https://echokit.dev/firmware/echokit_boards
  ```

  or just use your browser and then name the firmware `echokit-fw-dist`.

* Plug the *bottom-left USB port* on the EchoKit into
  your laptop.

  Try `espflash list-ports`: you should see something like

  ```
  /dev/ttyACM0  1001:303A  Espressif  USB JTAG/serial debug unit
  ```

  If so, skip the next step.

* *If you can't see the EchoKit on USB:* Put your EchoKit in
  boot mode by holding down the right-hand EchoKit board
  button labeled BOOT, then pressing and releasing the
  left-hand button labeled RESET, then promptly releasing
  the BOOT button.

  The screen will go black. You can then use `espflash
  list-ports` again to verify that things are good

  If this doesn't work, unplug the EchoKit and start
  over. It can be a tiny bit fiddly.

* Once the EchoKit is ready, flash the stock firmware.

  ```sh
  espflash flash --monitor --flash-size 16mb echokit-fw-dist
  ```

  When you see `waiting for download` and things have
  stopped, hit RESET. Your EchoKit should now be running
  the stock firmware.

## Build And Install From Source
  
* Build the firmware: `cargo build --release`. This will
  take a really long time for first build. You will get some
  warnings.

* Grab a copy of the built firmware for convenience.

  ```sh
  cp target/xtensa-esp32s3-espidf/release/echokit echokit-fw
  ```

  (You can install from the `target` directly, but I prefer
  to keep a built binary around anyway.)

* Flash as before:

  ```sh
  espflash flash --monitor --flash-size 16mb echokit-fw
  ```

  You are now running EchoKit firmware you built yourself.

## Linux Quick Start

Use this rather than the above if you want to get going
quickly on a Linux machine. This may work for Mac, not
tested. Note that WSL2 USB is fiddly: I don't recommend
trying this there unless you have a bunch of WSL2 skill and
experience.

* Read `BUILD.sh` there carefully to understand what's going
  on.
  
* Read the instructions above on hooking up and setting up
  your EchoKit itself.
  
* Move to the `echokit_box` directory.

* Make sure `curl` is installed on your machine, then run

  ```sh
  bash ../BUILD.sh setup
  . "$HOME/export-esp.sh"
  bash ../BUILD.sh dist
  bash ../BUILD.sh custom
  ```
