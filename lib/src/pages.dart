import 'dart:async';

import 'package:flusbserial/flusbserial.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yaru/yaru.dart';

import 'providers.dart';
import 'telemetry.dart';
import 'widgets.dart';

// ============================================================ Dashboard =====

class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});
  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  final Set<String> _show = {'x', 'y', 'z', 'mag'};
  double _window = 20;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(telemetryProvider);
    return YaruDetailPage(
      appBar: YaruWindowTitleBar(
        title: const Text('Dashboard'),
        border: BorderSide.none,
        backgroundColor: Colors.transparent,
        actions: [_recordButton(context, s)],
      ),
      body: LayoutBuilder(
        builder: (context, c) {
          final wide = c.maxWidth > 820;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const _ConnectionPanel(),
              const SizedBox(height: 16),
              _controls(context),
              const SizedBox(height: 8),
              SizedBox(
                height: 340,
                child: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 3, child: _chartCard(s)),
                          const SizedBox(width: 16),
                          SizedBox(width: 240, child: _sideRail(s)),
                        ],
                      )
                    : _chartCard(s),
              ),
              if (!wide) ...[const SizedBox(height: 16), SizedBox(height: 300, child: _sideRail(s))],
            ],
          );
        },
      ),
    );
  }

  Widget _recordButton(BuildContext context, TelemetryState s) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Tooltip(
        message: s.recording ? 'Stop recording (${s.recordCount} rows)' : 'Record to CSV',
        child: YaruIconButton(
          icon: Icon(s.recording ? YaruIcons.media_stop : YaruIcons.media_record,
              color: s.recording ? Theme.of(context).colorScheme.error : null),
          onPressed: () => ref.read(telemetryProvider.notifier).toggleRecording(),
        ),
      ),
    );
  }

  Widget _controls(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        AxisChip(label: 'X', color: AxisColors.x, selected: _show.contains('x'), onTap: () => _toggle('x')),
        AxisChip(label: 'Y', color: AxisColors.y, selected: _show.contains('y'), onTap: () => _toggle('y')),
        AxisChip(label: 'Z', color: AxisColors.z, selected: _show.contains('z'), onTap: () => _toggle('z')),
        AxisChip(label: '|a|', color: AxisColors.mag, selected: _show.contains('mag'), onTap: () => _toggle('mag')),
        const SizedBox(width: 12),
        const Text('Window'),
        for (final w in const [10.0, 20.0, 60.0])
          ChoiceChip(
            label: Text('${w.toStringAsFixed(0)}s'),
            selected: _window == w,
            onSelected: (_) => setState(() => _window = w),
          ),
      ],
    );
  }

  Widget _chartCard(TelemetryState s) {
    return YaruBorderContainer(
      padding: const EdgeInsets.fromLTRB(8, 20, 20, 8),
      child: ScopeChart(samples: s.samples, windowSeconds: _window, show: _show),
    );
  }

  Widget _sideRail(TelemetryState s) {
    final a = s.latest;
    String mg(int? v) => v == null ? '—' : v.toString();
    return YaruBorderContainer(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: Center(child: TiltIndicator(sample: a))),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Readout(label: 'X', value: mg(a?.x), color: AxisColors.x),
              Readout(label: 'Y', value: mg(a?.y), color: AxisColors.y),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Readout(label: 'Z', value: mg(a?.z), color: AxisColors.z),
              Readout(
                  label: '|a|',
                  value: a == null ? '—' : a.magnitude.toStringAsFixed(0),
                  color: AxisColors.mag),
            ],
          ),
        ],
      ),
    );
  }

  void _toggle(String k) => setState(() {
        if (!_show.remove(k)) _show.add(k);
      });
}

// ------------------------------------------------------- connection panel ----

class _ConnectionPanel extends ConsumerStatefulWidget {
  const _ConnectionPanel();
  @override
  ConsumerState<_ConnectionPanel> createState() => _ConnectionPanelState();
}

class _ConnectionPanelState extends ConsumerState<_ConnectionPanel> {
  List<UsbDevice> _devices = const [];
  UsbDevice? _selected;
  bool _scanning = false;
  bool _autoConnected = false;

  @override
  void initState() {
    super.initState();
    _rescan();
  }

  Future<void> _rescan() async {
    setState(() => _scanning = true);
    final all = await ref.read(telemetryProvider.notifier).scan();
    final list = [...all]..sort((a, b) {
        final ab = isLikelyBoard(a.vendorId) ? 0 : 1;
        final bb = isLikelyBoard(b.vendorId) ? 0 : 1;
        return ab != bb ? ab - bb : a.identifier.compareTo(b.identifier);
      });
    if (!mounted) return;
    final board = list.where((d) => isLikelyBoard(d.vendorId)).firstOrNull;
    setState(() {
      _devices = list;
      _selected = board ?? list.firstOrNull;
      _scanning = false;
    });
    // Auto-connect once, on first open, to the detected board.
    if (!_autoConnected &&
        board != null &&
        !ref.read(telemetryProvider).isConnected) {
      _autoConnected = true;
      unawaited(ref.read(telemetryProvider.notifier).connect(board));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(telemetryProvider);
    final notifier = ref.read(telemetryProvider.notifier);
    final theme = Theme.of(context);
    return YaruSection(
      headline: const Text('Connection'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<UsbDevice>(
                    initialValue: _selected,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Serial device',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (final d in _devices)
                        DropdownMenuItem(
                          value: d,
                          child: Text(
                            '${backendLabel(d.vendorId, d.productId)}  ·  addr ${d.identifier}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: s.isConnected ? null : (d) => setState(() => _selected = d),
                  ),
                ),
                const SizedBox(width: 8),
                YaruIconButton(
                  icon: _scanning
                      ? const SizedBox(width: 18, height: 18, child: YaruCircularProgressIndicator(strokeWidth: 2))
                      : const Icon(YaruIcons.refresh),
                  onPressed: s.isConnected || _scanning ? null : _rescan,
                  tooltip: 'Rescan',
                ),
                const SizedBox(width: 8),
                _connectButton(context, s, notifier),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [
                _stat(context, 'State', _stateLabel(s), _stateColor(context, s.status), dot: true),
                _stat(context, 'Rate', s.isConnected ? '${s.fps.toStringAsFixed(1)} Hz' : '—', theme.colorScheme.onSurface),
                _stat(context, 'WHO_AM_I', s.whoAmI.isEmpty ? '—' : '${s.whoAmI} ${s.whoAmIOk ? "OK" : ""}',
                    s.whoAmI.isEmpty ? theme.disabledColor : (s.whoAmIOk ? const Color(0xFF2EB398) : theme.colorScheme.error)),
                _crcStat(context, s),
              ],
            ),
            const SizedBox(height: 8),
            Text(s.message, style: theme.textTheme.bodySmall?.copyWith(color: theme.disabledColor)),
            if (s.recording)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  Icon(YaruIcons.media_record, size: 14, color: theme.colorScheme.error),
                  const SizedBox(width: 6),
                  Expanded(child: Text('Recording ${s.recordCount} rows → ${s.recordPath}',
                      overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall)),
                ]),
              ),
          ],
        ),
      ),
    );
  }

  Widget _connectButton(BuildContext context, TelemetryState s, TelemetryController n) {
    if (s.status == ConnStatus.connecting) {
      return const SizedBox(width: 120, child: Center(child: YaruCircularProgressIndicator(strokeWidth: 3)));
    }
    if (s.isConnected) {
      return OutlinedButton.icon(
        onPressed: n.disconnect,
        icon: const Icon(YaruIcons.network_offline, size: 18),
        label: const Text('Disconnect'),
      );
    }
    return FilledButton.icon(
      onPressed: _selected == null ? null : () => n.connect(_selected!),
      icon: const Icon(YaruIcons.media_play, size: 18),
      label: const Text('Connect'),
    );
  }

  Widget _stat(BuildContext context, String label, String value, Color color, {bool dot = false}) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: t.labelSmall),
        const SizedBox(height: 2),
        Row(mainAxisSize: MainAxisSize.min, children: [
          if (dot) ...[
            Container(width: 9, height: 9, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 6),
          ],
          Text(value, style: t.titleMedium?.copyWith(color: dot ? null : color)),
        ]),
      ],
    );
  }

  Widget _crcStat(BuildContext context, TelemetryState s) {
    final t = Theme.of(context).textTheme;
    final rate = s.crcRate;
    final barColor = rate < 0.001
        ? const Color(0xFF2EB398)
        : rate < 0.02
            ? const Color(0xFFF39C12)
            : Theme.of(context).colorScheme.error;
    return SizedBox(
      width: 150,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('CRC', style: t.labelSmall),
          const SizedBox(height: 2),
          Text('${s.crcErrors} / ${s.framesOk + s.crcErrors}  (${(rate * 100).toStringAsFixed(2)}%)',
              style: t.titleMedium),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: rate.clamp(0, 1) == 0 ? 0.02 : (rate * 10).clamp(0.02, 1),
              minHeight: 4,
              color: barColor,
              backgroundColor: Theme.of(context).dividerColor,
            ),
          ),
        ],
      ),
    );
  }

  String _stateLabel(TelemetryState s) => switch (s.status) {
        ConnStatus.connected => 'Streaming',
        ConnStatus.connecting => 'Connecting',
        ConnStatus.error => 'Error',
        ConnStatus.disconnected => 'Idle',
      };

  Color _stateColor(BuildContext context, ConnStatus st) => switch (st) {
        ConnStatus.connected => const Color(0xFF2EB398),
        ConnStatus.connecting => const Color(0xFFF39C12),
        ConnStatus.error => Theme.of(context).colorScheme.error,
        ConnStatus.disconnected => Theme.of(context).disabledColor,
      };
}

// =============================================================== Console =====

class ConsolePage extends ConsumerWidget {
  const ConsolePage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final log = ref.watch(telemetryProvider.select((s) => s.log));
    return YaruDetailPage(
      appBar: const YaruWindowTitleBar(
        title: Text('Console'),
        border: BorderSide.none,
        backgroundColor: Colors.transparent,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: YaruBorderContainer(
          padding: const EdgeInsets.all(12),
          color: Theme.of(context).colorScheme.surfaceContainerLowest,
          child: log.isEmpty
              ? Center(
                  child: Text('Device banner and text lines appear here.',
                      style: Theme.of(context).textTheme.bodyMedium))
              : ListView.builder(
                  reverse: true,
                  itemCount: log.length,
                  itemBuilder: (context, i) => Text(
                    log[log.length - 1 - i],
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  ),
                ),
        ),
      ),
    );
  }
}

// =============================================================== Settings ====

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return YaruDetailPage(
      appBar: const YaruWindowTitleBar(
        title: Text('Settings'),
        border: BorderSide.none,
        backgroundColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          YaruSection(
            headline: const Text('Appearance'),
            child: Column(
              children: [
                for (final m in ThemeMode.values)
                  YaruRadioListTile<ThemeMode>(
                    value: m,
                    groupValue: mode,
                    onChanged: (v) => ref.read(themeModeProvider.notifier).set(v!),
                    title: Text(switch (m) {
                      ThemeMode.system => 'Follow system',
                      ThemeMode.light => 'Light',
                      ThemeMode.dark => 'Dark',
                    }),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const YaruSection(
            headline: Text('About'),
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Clickscope', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  SizedBox(height: 6),
                  Text('A live oscilloscope for MikroElektronika Click-board '
                      'accelerometer telemetry, streamed over USB CDC as COBS/CRC '
                      'frames by the clickforge firmware.'),
                  SizedBox(height: 8),
                  Text('Wire format: COBS(payload)+0x00, payload = '
                      '[X i16 LE][Y i16 LE][Z i16 LE][CRC16-CCITT LE], milli-g.',
                      style: TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
