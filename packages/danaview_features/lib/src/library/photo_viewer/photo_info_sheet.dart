// OWNER: HOM-11
//
// The photo viewer's info sheet (ARCH v1.2 V2-106, §1.4; BUILD_PLAN HOM-11): a kit sheet listing
// [photoInfoRows] as label/value pairs. Values wrap (never clip) and the sheet scrolls, so nothing
// overflows at 280–1280 px and text scale 0.85–1.35; each row is one semantics node reading
// "Label: value". It stays live: it watches [photoInfoProvider], so a favourite or rename made
// meanwhile shows at once.

import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../photos/photo_grid_item.dart';
import 'photo_info.dart';

/// Shows the info sheet of [item].
Future<void> showPhotoInfoSheet(BuildContext context, PhotoGridItem item) => showDanaviewSheet<void>(
      context,
      title: 'File info',
      builder: (context) => PhotoInfoPanel(item: item),
    );

/// The rows of the info sheet (also usable inline, e.g. a side panel on wide screens).
class PhotoInfoPanel extends ConsumerWidget {
  /// The panel of [item].
  const PhotoInfoPanel({super.key, required this.item});

  /// The photo.
  final PhotoGridItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(photoInfoProvider(item));
    return info.when(
      loading: () => const Padding(
        key: ValueKey('photo-info-loading'),
        padding: EdgeInsets.all(DanaviewSpacing.xl),
        child: Center(child: DanaviewSpinner()),
      ),
      error: (_, __) => const Padding(
        key: ValueKey('photo-info-error'),
        padding: EdgeInsets.all(DanaviewSpacing.lg),
        child: Text('This photo’s details can’t be read.', style: TextStyle(color: DanaviewColors.textSecondary)),
      ),
      data: (info) {
        final rows = photoInfoRows(info);
        return SingleChildScrollView(
          key: const ValueKey('photo-info-rows'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [for (final row in rows) _InfoRow(row: row)],
          ),
        );
      },
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.row});

  final PhotoInfoRow row;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return MergeSemantics(
      key: ValueKey('photo-info-${row.id}'),
      child: Semantics(
        label: '${row.label}: ${row.value}',
        excludeSemantics: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: DanaviewSpacing.sm),
          child: LayoutBuilder(builder: (context, constraints) {
            final label = Text(
              row.label,
              style: (text.bodySmall ?? const TextStyle()).copyWith(color: DanaviewColors.textSecondary),
            );
            final value = Text(
              row.value,
              softWrap: true,
              style: (text.bodyMedium ?? const TextStyle()).copyWith(color: DanaviewColors.textPrimary),
            );
            // Side by side when there is room, stacked on narrow screens and large text.
            if (constraints.maxWidth < 360) {
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [label, const SizedBox(height: 2), value]);
            }
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 128, child: label),
              const SizedBox(width: DanaviewSpacing.md),
              Expanded(child: value),
            ]);
          }),
        ),
      ),
    );
  }
}
