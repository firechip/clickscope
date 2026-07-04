import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

bool _verbose = false;

/// Whether verbose diagnostic logging is enabled. Off by default so a normal
/// run is quiet — the UI already surfaces connection state and errors, so the
/// console only needs to carry telemetry-layer tracing when explicitly asked.
bool get verboseLogging => _verbose;

/// Decide the log level once, at startup, from the process arguments and the
/// environment. Enabled by `--verbose` / `-v`, or a non-empty CLICKSCOPE_VERBOSE
/// / CLICKSCOPE_DEBUG env var (handy for `snap run`, where passing args is
/// awkward). Call before anything logs.
void initLogging(List<String> args) {
  _verbose = args.contains('--verbose') ||
      args.contains('-v') ||
      _envFlag('CLICKSCOPE_VERBOSE') ||
      _envFlag('CLICKSCOPE_DEBUG');
}

bool _envFlag(String name) {
  final v = Platform.environment[name];
  return v != null &&
      v.isNotEmpty &&
      v != '0' &&
      v.toLowerCase() != 'false' &&
      v.toLowerCase() != 'no';
}

/// A verbose diagnostic line — a no-op unless [verboseLogging] is on. Tagged
/// `[clickscope]` so it is easy to grep out of a shared desktop console.
void logv(String message) {
  if (_verbose) debugPrint('[clickscope] $message');
}
