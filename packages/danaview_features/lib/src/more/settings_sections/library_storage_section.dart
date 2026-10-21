// OWNER: HOM-17
//
// Settings › Library storage (ARCH v1.2 §5.2, V2-115, V2-V1): how much the Danaview folders hold,
// how much waits in Recently deleted (it still counts, V2-08), and what backups carry. On iOS and
// macOS the library is in device and iCloud backups; on Android the plain note says cloud Auto
// Backup stops at 25 MB per app, so a larger library moves only with a direct device-to-device
// transfer (HOM plan §8.1). The app root hands [buildLibraryStorageSettingsSection] to
// `SettingsSections.libraryStorage` with DANAVIEW_FILES_HOME on.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import '../../library/files/library_store_providers.dart';
import '../../library/library_format.dart';
import '../../library/library_widgets.dart';
import '../../tools/media_tool_format.dart';

/// For `SettingsSections(libraryStorage: buildLibraryStorageSettingsSection)`.
Widget buildLibraryStorageSettingsSection(BuildContext context) => const LibraryStorageSettingsSection();

/// The Library storage header, the two size rows and the backup note.
class LibraryStorageSettingsSection extends ConsumerWidget {
  const LibraryStorageSettingsSection({super.key});

  static const String header = 'Library storage';
  static const String foldersTitle = 'Danaview folders';
  static const String trashTitle = 'Recently deleted';
  static const String trashSubtitle = 'Kept for 30 days, still uses space';
  static const String appleNote =
      'Danaview folders stay on this device and are included in your device and iCloud backups.';
  static const String androidNote = "Danaview folders are included in Android backups. Google's cloud backup "
      'holds up to 25 MB per app, so a larger library is not in the cloud backup; it moves to a new phone '
      'only with a direct phone-to-phone transfer.';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(libraryStorageUsageProvider) ?? LibraryStorageUsage.empty;
    final android = Theme.of(context).platform == TargetPlatform.android;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const DanaviewLibrarySectionHeader(header),
        DanaviewLibraryGroup(
          children: [
            _SizeRow(
              key: const ValueKey('library-storage-folders'),
              icon: Icons.folder_rounded,
              title: foldersTitle,
              subtitle: formatCount(usage.liveCount, 'file'),
              bytes: usage.liveBytes,
            ),
            _SizeRow(
              key: const ValueKey('library-storage-trash'),
              icon: Icons.delete_outline_rounded,
              title: trashTitle,
              subtitle: usage.trashedCount == 0 ? trashSubtitle : '${formatCount(usage.trashedCount, 'file')} · $trashSubtitle',
              bytes: usage.trashedBytes,
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(DanaviewSpacing.xs, DanaviewSpacing.sm, DanaviewSpacing.xs, 0),
          child: Text(android ? androidNote : appleNote, style: DanaviewTextStyles.caption),
        ),
      ],
    );
  }
}

class _SizeRow extends StatelessWidget {
  const _SizeRow({super.key, required this.icon, required this.title, required this.subtitle, required this.bytes});

  final IconData icon;
  final String title;
  final String subtitle;
  final int bytes;

  @override
  Widget build(BuildContext context) {
    final size = formatDataSize(bytes);
    return Semantics(
      container: true,
      label: '$title, $size, $subtitle',
      excludeSemantics: true,
      child: DanaviewLibraryRow(
        leading: DanaviewTileIcon(icon, color: DanaviewColors.primaryLight, size: 40),
        title: title,
        subtitle: subtitle,
        subtitleMaxLines: 2,
        trailing: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 96),
          child: Text(
            size,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: DanaviewTextStyles.caption.copyWith(color: DanaviewColors.textPrimary),
          ),
        ),
      ),
    );
  }
}
