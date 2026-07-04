# Vendored: flusbserial (patched)

This is a **vendored, patched copy** of
[`flusbserial`](https://github.com/AsCress/flusbserial) by Anashuman Singh
(MIT — see `LICENSE`), pinned into Clickscope so that clones and `snapcraft`
builds are fully self-contained (no external git fetch, and no dependency on
the host git version).

## Why vendored rather than a git dependency

`pub` runs the git bundled inside the Flutter snap (git 2.25.1, core20). That
git cannot parse an SSH-signing `~/.gitconfig` (`gpg.format = ssh`, git ≥ 2.34)
and aborts every command, so a `git:` dependency fails to resolve on such hosts.
A vendored `path:` dependency needs no git at all.

## Local changes vs upstream

Applied on top of upstream `master` — a single fix to
`lib/src/flusbserial/cdc_serial_device.dart` that makes a `CdcSerialDevice`
reopenable (upstream could not reconnect):

- `usbInterface` was `static late final` (shared + write-once) → the second
  `open()` in a process threw `LateInitializationError`. Now per-instance and
  reassignable.
- `close()` released the interface *after* a call that could throw, leaking the
  claim ("device in use"), never called `libusb_close`, and never reset
  `deviceHandle`. Now best-effort control-line off, then always
  release + close + null the handle.
- `open()` returned `false` on claim/endpoint failure without closing the
  handle, tripping `assert(deviceHandle == nullptr)` on the next attempt. Now
  cleans up on every failure path.

The same fix lives on the fork at
<https://github.com/firechip/flusbserial> (branch `fix/cdc-reopen-lifecycle`,
tag `cdc-reopen-fix-v1`) and is offered upstream.
