import 'dart:async';
import 'dart:io' show Platform, ProcessSignal, exit;
import 'dart:ui' show AppExitResponse;

import 'package:flusbserial/flusbserial.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yaru/yaru.dart';

import 'src/log.dart';
import 'src/pages.dart';
import 'src/providers.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  initLogging(args); // --verbose / -v / CLICKSCOPE_VERBOSE
  await YaruWindowTitleBar.ensureInitialized();
  try {
    UsbSerialDevice.init();
    UsbSerialDevice.setAutoDetachKernelDriver(true);
    // Route flusbserial's own traces through our logger so they get the same
    // [clickscope] tag and --verbose gating as the app's lines.
    UsbSerialDevice.logHandler = logv;
  } catch (_) {
    // libusb unavailable — the UI still runs, discovery just returns nothing.
  }
  runApp(const ProviderScope(child: ClickscopeApp()));
}

class ClickscopeApp extends ConsumerStatefulWidget {
  const ClickscopeApp({super.key});

  @override
  ConsumerState<ClickscopeApp> createState() => _ClickscopeAppState();
}

class _ClickscopeAppState extends ConsumerState<ClickscopeApp> {
  late final AppLifecycleListener _lifecycle;
  final List<StreamSubscription<ProcessSignal>> _signalSubs = [];

  @override
  void initState() {
    super.initState();
    // The Yaru title-bar close button calls gtk_window_close(); the Flutter
    // engine routes that (via window_delete_event_cb → System.requestAppExit)
    // to onExitRequested here. We synchronously cancel the 16 ms render timer
    // BEFORE returning exit, so the engine stops posting the redraw idle
    // callbacks that would otherwise fire on the freed FlView during teardown
    // and spew the "FlutterEngineRemoveView" + FlView/GtkWidget CRITICAL
    // cascade. quiesce() must not block (no awaited libusb close) or exit would
    // stall on the platform thread.
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        ref.read(telemetryProvider.notifier).quiesce();
        return AppExitResponse.exit;
      },
    );
    _installSignalHandlers();
  }

  // Termination signals (Ctrl+C=SIGINT, `kill`/`snap stop`=SIGTERM, terminal
  // hangup=SIGHUP) don't go through the window-close path, so release the USB
  // device here too — otherwise the port is left claimed until the kernel
  // reclaims the fd. Dart delivers signals as ordinary event-loop events, NOT
  // in an async-signal-handler context, so (unlike a C handler) it is safe to
  // run the libusb teardown here. We deliberately do NOT catch crash signals
  // (SIGSEGV/SIGBUS): the process memory is untrustworthy and the kernel
  // already reclaims every fd — including the usbfs handle — on process death.
  void _installSignalHandlers() {
    if (kIsWeb || !(Platform.isLinux || Platform.isMacOS)) return;
    for (final sig in const [
      ProcessSignal.sigint,
      ProcessSignal.sigterm,
      ProcessSignal.sighup,
    ]) {
      try {
        _signalSubs.add(sig.watch().listen(_onExitSignal));
      } catch (_) {
        // Not every signal is watchable on every platform; skip quietly.
      }
    }
  }

  bool _exiting = false;
  void _onExitSignal(ProcessSignal sig) {
    if (_exiting) return;
    _exiting = true;
    logv('$sig received — releasing the device and exiting');
    // quiesce() cancels the timers, stops the read loop and fire-and-forget
    // closes the device (flusbserial lowers DTR/RTS, releases the interface and
    // — with auto-detach — re-attaches the kernel driver). Give it a brief
    // moment to land, then exit; the kernel reclaims the fd regardless.
    ref.read(telemetryProvider.notifier).quiesce();
    Future<void>.delayed(const Duration(milliseconds: 250), () => exit(0));
  }

  @override
  void dispose() {
    for (final s in _signalSubs) {
      s.cancel();
    }
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(themeModeProvider);
    return YaruTheme(
      builder: (context, yaru, child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        onGenerateTitle: (_) => 'Clickscope',
        theme: yaru.theme,
        darkTheme: yaru.darkTheme,
        themeMode: mode,
        home: const AppShell(),
      ),
    );
  }
}

class AppShell extends StatelessWidget {
  const AppShell({super.key});

  static const _titles = ['Dashboard', 'Console', 'Settings'];
  static const _icons = [
    YaruIcons.monitor,
    YaruIcons.terminal,
    YaruIcons.settings
  ];

  @override
  Widget build(BuildContext context) {
    return YaruMasterDetailPage(
      length: _titles.length,
      appBar: const YaruWindowTitleBar(
        title: Text('Clickscope'),
        leading: Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Icon(YaruIcons.meter_middle),
        ),
      ),
      paneLayoutDelegate: const YaruFixedPaneDelegate(
        paneSize: 232,
      ),
      tileBuilder: (context, index, selected, availableWidth) => YaruMasterTile(
        leading: Icon(_icons[index]),
        title: Text(_titles[index]),
      ),
      pageBuilder: (context, index) => switch (index) {
        0 => const DashboardPage(),
        1 => const ConsolePage(),
        _ => const SettingsPage(),
      },
    );
  }
}
