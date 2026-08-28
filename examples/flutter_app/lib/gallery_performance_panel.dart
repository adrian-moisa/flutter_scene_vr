import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'gallery_resolution.dart';
import 'gallery_viewport.dart';

/// A compact readout; sampling continues in the controller when this is closed.
class GalleryFpsPanel extends StatelessWidget {
  const GalleryFpsPanel({
    required this.controller,
    required this.onClose,
    super.key,
  });
  final GalleryViewportController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final view = View.of(context);
      final sizes = controller.scene?.screenResolutions ?? {};
      final history = controller.fpsHistory;
      final ready = controller.scene != null;
      return Material(
        color: theme.brightness == Brightness.light
            ? Colors.white
            : colors.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: DefaultTextStyle(
          style: TextStyle(
            color: colors.onSurface,
            fontSize: 12,
            height: 1.4,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 8, 0),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Performance',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: onClose,
                      tooltip: 'Close performance panel',
                      iconSize: 18,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final primary = Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const _Eyebrow('SCENE FPS'),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  ready
                                      ? controller.sceneFps.toStringAsFixed(1)
                                      : '—',
                                  style: const TextStyle(
                                    fontSize: 44,
                                    height: 1.15,
                                    fontWeight: FontWeight.w500,
                                    letterSpacing: -1.5,
                                  ),
                                ),
                              ),
                              Text(
                                'Render submissions',
                                style: TextStyle(
                                  color: colors.onSurfaceVariant,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          );
                          final secondary = Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _MetricRow(
                                'Flutter',
                                ready
                                    ? '${controller.flutterFps.toStringAsFixed(1)} fps'
                                    : '—',
                              ),
                              _MetricRow(
                                'Raster',
                                ready
                                    ? '${controller.rasterMs.toStringAsFixed(1)} ms'
                                    : '—',
                              ),
                            ],
                          );
                          if (constraints.maxWidth < 280 ||
                              MediaQuery.textScalerOf(context).scale(12) > 16) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                primary,
                                const SizedBox(height: 12),
                                secondary,
                              ],
                            );
                          }
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(flex: 5, child: primary),
                              const SizedBox(width: 20),
                              Expanded(flex: 4, child: secondary),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 20),
                      const Row(
                        children: [
                          Expanded(child: _Eyebrow('RECENT FPS')),
                          _Eyebrow('1 s samples'),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Semantics(
                        label: 'Recent scene FPS, up to 30 samples',
                        image: true,
                        child: SizedBox(
                          height: 44,
                          child: RepaintBoundary(
                            child: CustomPaint(
                              painter: _FpsTrace(
                                history,
                                colors.primary,
                                colors.outlineVariant,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const _Eyebrow('RESOLUTION'),
                      const SizedBox(height: 8),
                      if (sizes.isEmpty)
                        const _MetricRow('Scene render', 'Waiting for frame'),
                      for (final entry in sizes.entries) ...[
                        _MetricRow(
                          sizes.length == 1
                              ? 'Scene render'
                              : 'Scene ${entry.key + 1}',
                          pixelDimensions(entry.value.render),
                        ),
                        _MetricRow(
                          'Output viewport',
                          pixelDimensions(entry.value.display),
                        ),
                        if (!entry.value.display.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2, bottom: 8),
                            child: Text(
                              '${(entry.value.render.width * entry.value.render.height / (entry.value.display.width * entry.value.display.height) * 100).toStringAsFixed(0)}% of viewport pixels',
                              style: TextStyle(
                                fontSize: 11,
                                color: colors.primary,
                              ),
                            ),
                          ),
                      ],
                      _MetricRow(
                        'Flutter backing',
                        pixelDimensions(view.physicalSize),
                      ),
                      const SizedBox(height: 12),
                      _Disclosure(
                        title: 'Display & measurement details',
                        storageKey: 'fps-display-details',
                        children: [
                          _MetricRow(
                            'Flutter logical',
                            pixelDimensions(
                              view.physicalSize / view.devicePixelRatio,
                            ),
                          ),
                          _MetricRow(
                            'Pixel ratio',
                            '${view.devicePixelRatio.toStringAsFixed(2)}×',
                          ),
                          _MetricRow(
                            'Reported screen',
                            pixelDimensions(view.display.size),
                          ),
                          _MetricRow(
                            'Reported refresh',
                            view.display.refreshRate > 0
                                ? '${view.display.refreshRate.toStringAsFixed(0)} Hz'
                                : 'Unavailable',
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Scene FPS counts the busiest scene’s render submissions. It does not measure GPU completions or physical display refresh. Raster is the mean Flutter raster time.',
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Screen size comes from the OS or browser. Physical panel pixels may not be exposed. Resolution settings change scene targets; Flutter UI keeps its backing size.',
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      _Disclosure(
                        title: 'Camera controls',
                        storageKey: 'fps-camera-controls',
                        children: [
                          const _MetricRow('WASD / arrows', 'Move'),
                          const _MetricRow('Drag', 'Orbit pivot'),
                          const _MetricRow('Middle-drag', 'Orbit pivot'),
                          const _MetricRow('Scroll', 'Zoom toward pivot'),
                          const _MetricRow('Shift', 'Move faster'),
                          const _MetricRow('R', 'Reset camera'),
                          const SizedBox(height: 8),
                          Text(
                            'Click the scene to focus. In split-screen examples, navigation moves the primary view. Settings keep their own input.',
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _Eyebrow extends StatelessWidget {
  const _Eyebrow(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.8,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

class _MetricRow extends StatelessWidget {
  const _MetricRow(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
        ),
      ],
    ),
  );
}

class _Disclosure extends StatelessWidget {
  const _Disclosure({
    required this.title,
    required this.storageKey,
    required this.children,
  });
  final String title, storageKey;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => ExpansionTile(
    key: PageStorageKey(storageKey),
    tilePadding: EdgeInsets.zero,
    childrenPadding: const EdgeInsets.only(bottom: 12),
    minTileHeight: 42,
    shape: const Border(),
    collapsedShape: const Border(),
    title: Text(
      title,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
    ),
    children: [
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ],
  );
}

/// This chart repaints only on the existing one-second stats notification.
class _FpsTrace extends CustomPainter {
  const _FpsTrace(this.points, this.color, this.gridColor);
  final List<double> points;
  final Color color, gridColor;
  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final baseline = size.height - 2;
    canvas.drawLine(
      Offset(0, baseline),
      Offset(size.width, baseline),
      Paint()..color = gridColor.withValues(alpha: 0.5),
    );
    if (points.isEmpty) return;
    final maximum = math.max(1.0, points.reduce(math.max) * 1.1);
    final line = Path();
    Offset position(int index) => Offset(
      size.width * (30 - points.length + index) / 29,
      baseline - points[index] / maximum * (size.height - 4),
    );
    final first = position(0);
    line.moveTo(first.dx, first.dy);
    for (var i = 1; i < points.length; i++) {
      final point = position(i);
      line.lineTo(point.dx, point.dy);
    }
    final last = position(points.length - 1);
    final fill = Path.from(line)
      ..lineTo(last.dx, baseline)
      ..lineTo(first.dx, baseline)
      ..close();
    canvas.drawPath(fill, Paint()..color = color.withValues(alpha: 0.08));
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(last, 2.5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_FpsTrace oldDelegate) =>
      points != oldDelegate.points ||
      color != oldDelegate.color ||
      gridColor != oldDelegate.gridColor;
}
