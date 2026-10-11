import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vwish_data/vwish_data.dart';
import 'package:vwish_domain/vwish_domain.dart';
import 'package:vwish_ui_kit/vwish_ui_kit.dart';

import '../controllers/providers.dart';
import '../library/library_controller.dart';
import '../library/library_format.dart';
import '../library/library_providers.dart';
import '../library/library_widgets.dart';
import 'media_tool_format.dart';
import 'media_tool_widgets.dart';
import 'storage_usage.dart';

export 'storage_usage.dart'
    show
        CacheClearResult,
        FolderUsage,
        StorageClearAction,
        StorageClearOutcome,
        StorageContributor,
        StorageContributorUsage,
        StorageOpenAction,
        StorageUsage,
        StorageUsageService,
        storageContributorsProvider,
        storageUsageServiceProvider;

/// Storage & history: space used by the app's videos and cache, what the library remembers, and
/// ways to clear history, resume points and the cache. Videos themselves are never deleted.
///
/// Storage kept by other packages (the video editor, the speech model) appears in its own sections
/// through [storageContributorsProvider] (ARCH §17.10): each contributor shows its size, can open
/// the screen that manages it, and offers its own confirmed clean-up when it has one.
class VwishStorageScreen extends ConsumerStatefulWidget {
  const VwishStorageScreen({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  ConsumerState<VwishStorageScreen> createState() => _VwishStorageScreenState();
}

class _VwishStorageScreenState extends ConsumerState<VwishStorageScreen> {
  StorageUsage? _usage;
  bool _measuring = true;
  bool _busy = false;

  /// Bumped by every measurement so a slow, superseded one can't replace a newer result.
  int _token = 0;

  List<StorageContributor> _contributors = const [];
  final Map<String, StreamSubscription<StorageContributorUsage>> _subscriptions = {};
  final Map<String, StorageContributorUsage> _contributorUsage = {};
  final Set<String> _contributorFailed = {};

  @override
  void initState() {
    super.initState();
    _measure();
    ref.listenManual<List<StorageContributor>>(
      storageContributorsProvider,
      (_, next) => _watchContributors(next),
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    _cancelContributors();
    super.dispose();
  }

  void _cancelContributors() {
    for (final subscription in _subscriptions.values) {
      subscription.cancel();
    }
    _subscriptions.clear();
  }

  /// (Re)starts measuring every contributor; the last figures stay on screen meanwhile.
  void _watchContributors(List<StorageContributor> contributors) {
    _cancelContributors();
    _contributors = contributors;
    final ids = {for (final contributor in contributors) contributor.id};
    _contributorUsage.removeWhere((id, _) => !ids.contains(id));
    _contributorFailed.removeWhere((id) => !ids.contains(id));
    for (final contributor in contributors) {
      _subscriptions[contributor.id] = contributor.watchUsage().listen(
        (usage) {
          if (!mounted) return;
          setState(() {
            _contributorUsage[contributor.id] = usage;
            _contributorFailed.remove(contributor.id);
          });
        },
        onError: (Object e) {
          debugPrint('[Storage] Measuring ${contributor.id} failed: $e');
          if (mounted) setState(() => _contributorFailed.add(contributor.id));
        },
      );
    }
  }

  Future<void> _measure() async {
    final token = ++_token;
    if (!_measuring) setState(() => _measuring = true);
    StorageUsage? usage;
    try {
      usage = await ref.read(storageUsageServiceProvider).measure();
    } catch (e) {
      debugPrint('[Storage] Measuring failed: $e');
    }
    if (!mounted || token != _token) return;
    setState(() {
      _usage = usage ?? _usage;
      _measuring = false;
    });
  }

  Future<void> _refresh() async {
    _watchContributors(_contributors);
    await ref.read(libraryControllerProvider.notifier).refresh();
    await _measure();
  }

  /// History and playlist items, each once: the videos whose resume points the app can list.
  List<MediaRef> _knownMedia(LibraryState library) {
    final controller = ref.read(libraryControllerProvider.notifier);
    final seen = <String>{};
    return [
      for (final media in [
        for (final item in library.recent) item.media,
        for (final playlist in library.playlists) ...controller.playlistItems(playlist.name),
      ])
        if (seen.add(media.id)) media,
    ];
  }

  /// Runs one clean-up at a time and reports how it went.
  Future<void> _run(Future<String> Function() action, {required String failure}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final message = await action();
      if (mounted) {
        VwishToast.show(context, message, kind: VwishToastKind.success, icon: Icons.check_circle_rounded);
      }
    } on _ClearBlocked catch (blocked) {
      if (mounted) VwishToast.show(context, blocked.reason, icon: Icons.info_outline_rounded);
    } catch (e) {
      debugPrint('[Storage] $failure: $e');
      if (mounted) {
        VwishToast.show(context, failure, kind: VwishToastKind.error, icon: Icons.error_outline_rounded);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearHistory(int count) async {
    final confirmed = await showVwishConfirm(
      context,
      title: 'Clear watch history',
      message: 'Continue watching and the resume points of ${formatCount(count, 'video')} will be cleared. '
          'Your videos, playlists and folders stay.',
      confirmLabel: 'Clear',
      destructive: true,
      icon: Icons.history_rounded,
    );
    if (!confirmed || !mounted) return;
    await _run(failure: "Couldn't clear the watch history.", () async {
      await ref.read(libraryControllerProvider.notifier).clearHistory();
      return 'Watch history cleared';
    });
  }

  Future<void> _clearResumePoints(List<MediaRef> media) async {
    final confirmed = await showVwishConfirm(
      context,
      title: 'Clear resume points',
      message: '${formatCount(media.length, 'video')} will start from the beginning next time. '
          'Your watch history stays.',
      confirmLabel: 'Clear',
      destructive: true,
      icon: Icons.restart_alt_rounded,
    );
    if (!confirmed || !mounted) return;
    await _run(failure: "Couldn't clear the resume points.", () async {
      final session = ref.read(sessionRepositoryProvider);
      for (final item in media) {
        await session.clearResumePosition(item.id);
      }
      await ref.read(libraryControllerProvider.notifier).refresh();
      return 'Resume points cleared';
    });
  }

  Future<void> _clearCache() async {
    final confirmed = await showVwishConfirm(
      context,
      title: 'Clear cache',
      // Only phones and tablets copy picked videos; computers open them where they are.
      message: context.isTouchPlatform
          ? 'Temporary files Vwish made, such as copies of picked videos, will be deleted. '
              'Your videos and library stay.'
          : 'Temporary files Vwish made will be deleted. Your videos and library stay.',
      confirmLabel: 'Clear',
      icon: Icons.cleaning_services_rounded,
    );
    if (!confirmed || !mounted) return;
    await _run(failure: "Couldn't clear the cache.", () async {
      final current = ref.read(playerControllerProvider).currentMediaRef;
      final result = await ref.read(storageUsageServiceProvider).clearCache(
        keep: {if (current != null && !current.isRemote) current.pathOrUri},
      );
      await _measure();
      final freed = result.files == 0 ? 'Cache cleared' : 'Freed ${formatDataSize(result.bytes)}';
      return result.kept == 0 ? freed : '$freed. Files in use were kept.';
    });
  }

  /// Asks with the contributor's own copy, then runs its clean-up and measures it again.
  Future<void> _clearContributor(StorageContributor contributor, StorageClearAction action) async {
    final blocked = _contributorUsage[contributor.id]?.clearBlockedReason;
    if (blocked != null) {
      VwishToast.show(context, blocked, icon: Icons.info_outline_rounded);
      return;
    }
    final confirmed = await showVwishConfirm(
      context,
      title: action.confirmTitle,
      message: action.confirmMessage,
      confirmLabel: action.confirmLabel,
      destructive: action.destructive,
      icon: action.icon ?? Icons.cleaning_services_rounded,
    );
    if (!confirmed || !mounted) return;
    await _run(failure: "Couldn't finish: ${action.label}.", () async {
      final outcome = await action.run();
      if (mounted) _watchContributors(_contributors);
      final reason = outcome.blockedReason;
      if (reason != null) throw _ClearBlocked(reason);
      final freed = outcome.freedBytes;
      return outcome.message ?? (freed > 0 ? 'Freed ${formatDataSize(freed)}' : 'Cleared');
    });
  }

  /// Contributors grouped by section, in the order they were listed.
  Map<String, List<StorageContributor>> get _sections {
    final sections = <String, List<StorageContributor>>{};
    for (final contributor in _contributors) {
      (sections[contributor.section] ??= []).add(contributor);
    }
    return sections;
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(libraryControllerProvider);
    final session = ref.watch(sessionRepositoryProvider);
    final resumable = [
      for (final media in _knownMedia(library))
        if (session.getResumeInfo(media.id) != null) media,
    ];
    final usage = _usage;
    final cache = usage?.cache;
    final loaded = library.hasLoaded;
    String count(int value, String noun) => loaded ? formatCount(value, noun) : '…';

    return VwishRefreshOnReturn(
      onReturn: _refresh,
      child: MediaToolPage(
        title: 'Storage & history',
        onBack: widget.onBack,
        children: [
          _summary(usage),
          const VwishLibrarySectionHeader('Videos'),
          ..._videos(usage),
          for (final MapEntry(key: section, value: contributors) in _sections.entries) ...[
            VwishLibrarySectionHeader(section),
            _contributorGroup(contributors),
            MediaToolFootnote(contributors.map((contributor) => contributor.subtitle).join(' ')),
          ],
          const VwishLibrarySectionHeader('History & library'),
          MediaInfoGroup(
            rows: [
              MediaInfoRow('Watch history', count(library.recent.length, 'video')),
              MediaInfoRow('Resume points', count(resumable.length, 'saved position')),
              MediaInfoRow('Playlists', count(library.playlists.length, 'playlist')),
              MediaInfoRow('Library folders', count(library.userFolders.length, 'folder')),
            ],
          ),
          const VwishLibrarySectionHeader('Clean up'),
          VwishLibraryGroup(
            children: [
              _actionRow(
                icon: Icons.history_rounded,
                color: VwishColors.warning,
                title: 'Clear watch history',
                subtitle: library.recent.isEmpty ? 'History is empty' : 'Continue watching and its resume points',
                onTap: library.recent.isEmpty ? null : () => _clearHistory(library.recent.length),
              ),
              _actionRow(
                icon: Icons.restart_alt_rounded,
                color: VwishColors.primaryLight,
                title: 'Clear resume points',
                subtitle: resumable.isEmpty ? 'No saved positions' : 'Start videos from the beginning; history stays',
                onTap: resumable.isEmpty ? null : () => _clearResumePoints(resumable),
              ),
              _actionRow(
                icon: Icons.cleaning_services_rounded,
                color: VwishColors.cyan,
                title: 'Clear cache',
                subtitle: switch (cache) {
                  null when _measuring => 'Calculating…',
                  null => 'There is no cache on this device',
                  FolderUsage(files: 0) => 'The cache is empty',
                  _ => 'Frees ${cache.complete ? 'about' : 'at least'} ${formatDataSize(cache.bytes)} '
                      'of temporary files',
                },
                onTap: cache == null || cache.files == 0 ? null : _clearCache,
              ),
            ],
          ),
          const MediaToolFootnote(
            'Clearing never deletes your videos, playlists or library folders. Resume points are counted '
            'for the videos in your history and playlists.',
          ),
        ],
      ),
    );
  }

  Widget _summary(StorageUsage? usage) {
    final videos = usage?.deviceVideos;
    final cache = usage?.cache;
    final sections = _sections;
    final contributorBytes = _contributorUsage.values.fold(0, (total, usage) => total + usage.bytes);
    final caption = switch (usage) {
      null when _measuring => 'Adding up videos and temporary files.',
      null => "The app's folders couldn't be read.",
      StorageUsage(deviceVideos: null) => 'Temporary files only. Your videos stay in their own folders.',
      _ => 'Videos on this device and temporary files.',
    };
    return MediaResultCard(
      eyebrow: 'Space used by Vwish',
      value: usage == null
          ? (_measuring ? 'Calculating…' : 'Unavailable')
          : formatDataSize(usage.totalBytes + contributorBytes),
      caption: usage == null || sections.isEmpty
          ? caption
          : '$caption ${sections.keys.join(', ')} ${sections.length == 1 ? 'is' : 'are'} included.',
      stats: [
        if (videos != null) (label: 'Videos', value: _size(videos)),
        if (cache != null) (label: 'Cache', value: _size(cache)),
        for (final MapEntry(key: section, value: contributors) in sections.entries)
          if (contributors.any((contributor) => _contributorUsage.containsKey(contributor.id)))
            (label: section, value: formatDataSize(_bytesOf(contributors))),
      ],
    );
  }

  int _bytesOf(List<StorageContributor> contributors) =>
      contributors.fold(0, (total, contributor) => total + (_contributorUsage[contributor.id]?.bytes ?? 0));

  /// One row per contributor (its size, and a chevron when it opens a screen), plus a row for its
  /// clean-up when it has one.
  Widget _contributorGroup(List<StorageContributor> contributors) {
    return VwishLibraryGroup(
      children: [
        for (final contributor in contributors) ...[
          _contributorRow(contributor),
          if (contributor.clearAction case final action?) _contributorClearRow(contributor, action),
        ],
      ],
    );
  }

  bool _contributorMeasuring(StorageContributor contributor) =>
      !_contributorUsage.containsKey(contributor.id) && !_contributorFailed.contains(contributor.id);

  String _contributorSize(StorageContributor contributor) {
    final usage = _contributorUsage[contributor.id];
    if (usage == null) return _contributorMeasuring(contributor) ? 'Calculating…' : "Couldn't be measured";
    final size = formatDataSize(usage.bytes);
    final amount = usage.complete ? size : 'At least $size';
    return usage.detail == null ? amount : '${usage.detail} · $amount';
  }

  Widget _contributorRow(StorageContributor contributor) {
    final open = contributor.openAction;
    final size = _contributorSize(contributor);
    return VwishLibraryRow(
      key: ValueKey('storage-contributor-${contributor.id}'),
      leading: VwishTileIcon(contributor.icon, color: contributor.color, size: 40),
      title: contributor.title,
      subtitle: size,
      subtitleMaxLines: 2,
      trailing: _contributorMeasuring(contributor)
          ? const Padding(padding: EdgeInsets.all(VwishSpacing.sm), child: VwishSpinner(size: 18))
          : open == null
              ? null
              : const Icon(Icons.chevron_right_rounded, color: VwishColors.textMuted),
      onTap: open == null ? null : () => open.onOpen(context),
      semanticLabel: open == null ? '${contributor.title}. $size' : '${contributor.title}. $size. ${open.label}',
    );
  }

  Widget _contributorClearRow(StorageContributor contributor, StorageClearAction action) {
    final usage = _contributorUsage[contributor.id];
    final blocked = usage?.clearBlockedReason;
    final subtitle = switch (usage) {
      null => _contributorMeasuring(contributor) ? 'Calculating…' : "Couldn't be measured",
      _ when blocked != null => blocked,
      StorageContributorUsage(bytes: 0) => 'Nothing to clear',
      _ => 'Frees ${usage.complete ? 'about' : 'at least'} ${formatDataSize(usage.bytes)}',
    };
    final enabled = usage != null && usage.bytes > 0 && blocked == null;
    return KeyedSubtree(
      key: ValueKey('storage-contributor-${contributor.id}-clear'),
      child: _actionRow(
        icon: action.icon ?? Icons.cleaning_services_rounded,
        color: action.destructive ? VwishColors.errorLight : contributor.color,
        title: action.label,
        subtitle: subtitle,
        onTap: enabled ? () => _clearContributor(contributor, action) : null,
      ),
    );
  }

  List<Widget> _videos(StorageUsage? usage) {
    if (usage == null) {
      return [
        VwishLibraryGroup(
          children: [
            VwishLibraryRow(
              leading: const VwishTileIcon.glyph(VwishGlyphKind.device, size: 40),
              title: 'Videos',
              subtitle: _measuring ? 'Calculating…' : "Couldn't be measured",
              trailing: _measuring
                  ? const Padding(padding: EdgeInsets.all(VwishSpacing.sm), child: VwishSpinner(size: 18))
                  : null,
            ),
          ],
        ),
      ];
    }
    final videos = usage.deviceVideos;
    if (videos == null) {
      return const [
        VwishLibraryGroup(
          children: [
            VwishLibraryRow(
              leading: VwishTileIcon.glyph(VwishGlyphKind.folderVideo, size: 40),
              title: 'Nothing is copied',
              subtitle: 'On this computer Vwish plays videos from their own folders, '
                  'so they take no extra space.',
              subtitleMaxLines: 4,
            ),
          ],
        ),
      ];
    }
    return [
      VwishLibraryGroup(
        children: [
          VwishLibraryRow(
            leading: const VwishTileIcon.glyph(VwishGlyphKind.device, size: 40),
            title: LibraryRepository.deviceFolderLabel,
            subtitle: videos.files == 0
                ? 'No videos yet'
                : '${formatThousands(videos.files)} ${videos.files == 1 ? 'video' : 'videos'} · ${_size(videos)}',
            subtitleMaxLines: 2,
          ),
        ],
      ),
      MediaToolFootnote(_manageVideosHint(context)),
    ];
  }

  String _manageVideosHint(BuildContext context) {
    const intro = "Vwish never deletes videos, so clearing here won't free their space.";
    switch (Theme.of(context).platform) {
      case TargetPlatform.iOS:
        final device = MediaQuery.sizeOf(context).shortestSide >= 600 ? 'iPad' : 'iPhone';
        return '$intro To remove them, open the Files app and go to On My $device › Vwish.';
      case TargetPlatform.android:
        return '$intro They are kept in the app\'s private storage; clearing its storage in Android '
            'Settings removes them.';
      default:
        return intro;
    }
  }

  Widget _actionRow({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
  }) {
    final enabled = onTap != null && !_busy;
    return Opacity(
      opacity: onTap == null ? 0.55 : 1,
      child: VwishLibraryRow(
        leading: VwishTileIcon(icon, color: color, size: 40),
        title: title,
        subtitle: subtitle,
        subtitleMaxLines: 2,
        onTap: enabled ? onTap : null,
        semanticLabel: '$title. $subtitle',
      ),
    );
  }
}

/// `1.2 GB`, or `At least 1.2 GB` when part of the folder couldn't be read.
String _size(FolderUsage usage) {
  final size = formatDataSize(usage.bytes);
  return usage.complete ? size : 'At least $size';
}

/// A contributor's clean-up reported that something still uses its data.
class _ClearBlocked implements Exception {
  const _ClearBlocked(this.reason);

  final String reason;
}
