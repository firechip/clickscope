import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'telemetry.dart';

/// Axis colors shared by the chart and the legend.
class AxisColors {
  static const x = Color(0xFFE95420); // Ubuntu orange
  static const y = Color(0xFF2EB398);
  static const z = Color(0xFF3584E4);
  static const mag = Color(0xFF9141AC);
}

/// Live scrolling X/Y/Z (+ magnitude) chart. Animation is disabled
/// (`duration: Duration.zero`) — the single biggest win for a smooth stream.
class ScopeChart extends StatelessWidget {
  const ScopeChart({
    super.key,
    required this.samples,
    required this.windowSeconds,
    required this.show, // {'x','y','z','mag'}
  });

  final List<Sample> samples;
  final double windowSeconds;
  final Set<String> show;

  @override
  Widget build(BuildContext context) {
    if (samples.isEmpty) {
      return const _EmptyChart();
    }
    final refMs = samples.last.t.millisecondsSinceEpoch.toDouble();
    double tx(Sample s) => (s.t.millisecondsSinceEpoch - refMs) / 1000.0;

    final bars = <LineChartBarData>[
      if (show.contains('x')) _bar(samples.map((s) => FlSpot(tx(s), s.x.toDouble())), AxisColors.x),
      if (show.contains('y')) _bar(samples.map((s) => FlSpot(tx(s), s.y.toDouble())), AxisColors.y),
      if (show.contains('z')) _bar(samples.map((s) => FlSpot(tx(s), s.z.toDouble())), AxisColors.z),
      if (show.contains('mag')) _bar(samples.map((s) => FlSpot(tx(s), s.magnitude)), AxisColors.mag),
    ];

    final grid = Theme.of(context).dividerColor.withValues(alpha: 0.25);
    return RepaintBoundary(
      child: LineChart(
        duration: Duration.zero,
        LineChartData(
          minX: -windowSeconds,
          maxX: 0,
          lineBarsData: bars,
          clipData: const FlClipData.all(),
          lineTouchData: const LineTouchData(enabled: false),
          gridData: FlGridData(
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) => FlLine(color: grid, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 26,
                interval: windowSeconds / 4,
                getTitlesWidget: (v, meta) => Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('${v.toStringAsFixed(0)}s',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
              ),
            ),
            leftTitles: AxisTitles(
              axisNameWidget: const Text('mg'),
              axisNameSize: 18,
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 48,
                getTitlesWidget: (v, meta) => Text(v.toStringAsFixed(0),
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            ),
          ),
        ),
      ),
    );
  }

  LineChartBarData _bar(Iterable<FlSpot> spots, Color c) => LineChartBarData(
        spots: spots.toList(growable: false),
        color: c,
        barWidth: 1.6,
        isCurved: false,
        dotData: const FlDotData(show: false),
      );
}

class _EmptyChart extends StatelessWidget {
  const _EmptyChart();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.show_chart,
              size: 48, color: Theme.of(context).disabledColor),
          const SizedBox(height: 12),
          Text('Waiting for telemetry…',
              style: Theme.of(context).textTheme.bodyLarge),
        ],
      ),
    );
  }
}

/// A bubble-level style tilt visual: the dot sits where gravity points
/// (X/Y in the plane), its color/ring encodes Z (up/down). ±1000 mg = full.
class TiltIndicator extends StatelessWidget {
  const TiltIndicator({super.key, required this.sample});
  final Sample? sample;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: CustomPaint(
        painter: _TiltPainter(
          sample: sample,
          fg: Theme.of(context).colorScheme.onSurface,
          grid: Theme.of(context).dividerColor,
          accent: AxisColors.x,
        ),
      ),
    );
  }
}

class _TiltPainter extends CustomPainter {
  _TiltPainter({
    required this.sample,
    required this.fg,
    required this.grid,
    required this.accent,
  });
  final Sample? sample;
  final Color fg, grid, accent;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = min(size.width, size.height) / 2 - 8;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = grid;
    canvas.drawCircle(c, r, ring);
    canvas.drawCircle(c, r * 0.66, ring..color = grid.withValues(alpha: 0.5));
    canvas.drawCircle(c, r * 0.33, ring);
    canvas.drawLine(Offset(c.dx - r, c.dy), Offset(c.dx + r, c.dy), ring);
    canvas.drawLine(Offset(c.dx, c.dy - r), Offset(c.dx, c.dy + r), ring);

    final s = sample;
    if (s == null) return;
    final nx = (s.x / 1000.0).clamp(-1.0, 1.0);
    final ny = (s.y / 1000.0).clamp(-1.0, 1.0);
    final pos = Offset(c.dx + nx * r, c.dy - ny * r);
    // Z: green when ~ +1 g (flat, facing up), red when inverted.
    final zg = (s.z / 1000.0).clamp(-1.0, 1.0);
    final dotColor = Color.lerp(
        const Color(0xFFC0392B), const Color(0xFF2EB398), (zg + 1) / 2)!;
    canvas.drawCircle(pos, 10, Paint()..color = dotColor.withValues(alpha: 0.35));
    canvas.drawCircle(pos, 6, Paint()..color = dotColor);
  }

  @override
  bool shouldRepaint(_TiltPainter old) => old.sample != sample;
}

/// Coloured legend chip that toggles a series on/off.
class AxisChip extends StatelessWidget {
  const AxisChip({
    super.key,
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      selected: selected,
      onSelected: (_) => onTap(),
      showCheckmark: false,
      avatar: CircleAvatar(backgroundColor: color, radius: 6),
      label: Text(label),
    );
  }
}

/// A big numeric readout (value + unit + label), used for X/Y/Z/|a|.
class Readout extends StatelessWidget {
  const Readout({
    super.key,
    required this.label,
    required this.value,
    required this.color,
    this.unit = 'mg',
  });
  final String label;
  final String value;
  final String unit;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(label, style: t.labelMedium),
        ]),
        const SizedBox(height: 2),
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Text(value,
              style: t.headlineSmall?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()])),
          const SizedBox(width: 3),
          Text(unit, style: t.bodySmall),
        ]),
      ],
    );
  }
}
