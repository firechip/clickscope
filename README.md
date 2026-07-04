# Clickscope

**A live oscilloscope for MikroElektronika Click-board accelerometer telemetry.**

Clickscope is an Ubuntu-native (Flutter + [Yaru](https://pub.dev/packages/yaru))
desktop app that connects to a board running the
[clickforge](https://github.com/firechip) firmware, decodes its COBS/CRC
telemetry off USB CDC-ACM, and shows the 3-axis accelerometer stream live —
scrolling X/Y/Z (+ magnitude) plot, a bubble-level tilt view, numeric readouts,
link-quality stats, a device console, and CSV recording.

![Clickscope](doc/screenshot.png)

## What it shows

The firmware (Zephyr, FreeRTOS, RT-Thread, TinyGo, Rust, MicroPython, Ruby,
Forth, …) streams the onboard LIS2DH12 as **COBS-framed binary telemetry**:

```
frame   = COBS(payload) + 0x00                                (≤ 10 bytes)
payload = [X int16 LE][Y int16 LE][Z int16 LE][CRC16-CCITT LE]  (8 bytes)
```

X/Y/Z are already in **milli-g** (the firmware sends `raw16 >> 4`), and each
frame is CRC-16/CCITT-FALSE checked. Clickscope decodes with the published
[`cobs_codec`](https://pub.dev/packages/cobs_codec) package + a matching CRC,
so a corrupted frame is dropped, not plotted.

## Features

- **Auto-discovery** of the board over USB, labelled by firmware (VID:PID → RTOS).
- **Real-time chart** (fl_chart, animation-free) — X/Y/Z + derived magnitude,
  per-axis toggles, 10 / 20 / 60 s windows.
- **Tilt indicator** — a bubble-level driven by the gravity vector.
- **Live stats** — streaming rate (Hz), `WHO_AM_I` health, and a rolling
  CRC-error rate bar.
- **Console** — the device's ASCII banner and any text lines.
- **Record to CSV** — one click writes `~/clickscope-<timestamp>.csv`.
- **Yaru look & feel** — light/dark/system, Ubuntu accent, CSD title bar.

> **Safety:** Clickscope always opens at **115200 baud**. It will never open at
> 1200 baud — on these boards that is the "touch" that reboots into the UF2
> bootloader.

## Run from source

```bash
flutter pub get
flutter run -d linux        # or: flutter build linux --release
```

Requires the Flutter Linux desktop toolchain and `libusb-1.0`. Reading a serial
device needs permission — add yourself to the `dialout` group once:

```bash
sudo usermod -aG dialout $USER   # then log out / back in
```

## Install on Ubuntu

**Snap** (see `snap/snapcraft.yaml`):

```bash
snapcraft                                   # builds clickscope_*.snap
sudo snap install --dangerous clickscope_*.snap
sudo snap connect clickscope:serial-port    # grant USB-serial access
```

**Portable tarball** (no packaging tools):

```bash
flutter build linux --release
tar czf clickscope-linux-x64.tar.gz -C build/linux/x64/release/bundle .
# unpack anywhere and run ./clickscope
```

## Layout

```
lib/
  main.dart            entry, Yaru theme, master-detail shell
  src/telemetry.dart   Sample + COBS (cobs_codec) / CRC decode + firmware-id map
  src/providers.dart   Riverpod controller: serial IO, framing, ring buffer, CSV
  src/widgets.dart     ScopeChart, TiltIndicator, readouts
  src/pages.dart       Dashboard, Console, Settings
test/telemetry_test.dart   decode / CRC / label unit tests
```

## License

MIT © Firechip / Alexander Salas Bastidas
