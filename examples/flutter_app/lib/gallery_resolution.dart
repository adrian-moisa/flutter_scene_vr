import 'package:flutter/material.dart';

String pixelDimensions(Size size) => size.isEmpty
    ? 'unavailable'
    : '${size.width.round()}×${size.height.round()} px';

/// Preserves aspect ratio and derives sizes from this platform's viewport or
/// runtime recommendation. These conservative choices never supersample.
class GalleryResolutionControl extends StatelessWidget {
  const GalleryResolutionControl({
    required this.base,
    required this.scale,
    required this.onChanged,
    this.enabled = true,
    this.immersive = false,
    super.key,
  });
  final Size base;
  final double scale;
  final ValueChanged<double> onChanged;
  final bool enabled;
  final bool immersive;

  @override
  Widget build(BuildContext context) {
    final choices = {0.5, 0.67, 0.75, 1.0, scale}.toList()..sort();
    double pixels(double value) =>
        immersive ? value.roundToDouble() : value.ceilToDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          immersive ? 'Eye resolution' : 'Scene resolution',
          style: TextStyle(
            fontSize: immersive ? 22 : 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        DecoratedBox(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Theme.of(context).colorScheme.outline),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<double>(
                key: const ValueKey('scene-render-resolution'),
                isExpanded: true,
                itemHeight: 56,
                iconSize: 28,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
                value: scale,
                onChanged: enabled && !base.isEmpty
                    ? (value) {
                        if (value != null) onChanged(value);
                      }
                    : null,
                items: [
                  for (final value in choices)
                    DropdownMenuItem(
                      value: value,
                      child: Text(
                        '${(value * 100).round()}% · ${pixelDimensions(Size(pixels(base.width * value), pixels(base.height * value)))}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          immersive
              ? '100% = recommended pixels per eye. Panel resolution stays fixed.'
              : '100% = viewport × device pixel ratio. UI resolution stays fixed.',
          style: TextStyle(fontSize: immersive ? 18 : 14, height: 1.35),
        ),
        Text(
          '${(scale * scale * 100).round()}% of baseline scene pixels · applies live',
          style: TextStyle(fontSize: immersive ? 18 : 14, height: 1.35),
        ),
      ],
    );
  }
}
