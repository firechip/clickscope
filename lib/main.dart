import 'package:flusbserial/flusbserial.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yaru/yaru.dart';

import 'src/pages.dart';
import 'src/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await YaruWindowTitleBar.ensureInitialized();
  try {
    UsbSerialDevice.init();
    UsbSerialDevice.setAutoDetachKernelDriver(true);
  } catch (_) {
    // libusb unavailable — the UI still runs, discovery just returns nothing.
  }
  runApp(const ProviderScope(child: ClickscopeApp()));
}

class ClickscopeApp extends ConsumerWidget {
  const ClickscopeApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
  static const _icons = [YaruIcons.monitor, YaruIcons.terminal, YaruIcons.settings];

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
