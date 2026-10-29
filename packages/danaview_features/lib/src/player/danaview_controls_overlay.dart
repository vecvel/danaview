import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import '../controllers/player_controller.dart';
import '../controllers/providers.dart';
import 'danaview_player_actions.dart';

enum TimeDisplayMode {
  currentAndTotal,
  remaining,
}

enum _BarItem { previous, next, volume, subtitles, audio, speed, queue, settings }

enum _SeekSide { back, forward }

const List<double> _rowSpeeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0];
const List<double> _sheetSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

class DanaviewControlsOverlay extends ConsumerStatefulWidget {
  final VoidCallback onOpenSettings;
  final VoidCallback onOpenQueue;
  final VoidCallback onToggleDiagnostics;
  final bool isLocked;
  final VoidCallback onToggleLock;

  /// Shows a back chevron at the start of the top bar when set.
  final VoidCallback? onBack;

  /// Space taken at the top by the desktop title bar, which also shows the title.
  final double topInset;

  /// Opens the video editor (ARCH §17.1). Null hides the top-bar Edit button and the Playback
  /// sheet's "Edit video" row; the screen passes null for remote media and while locked.
  final VoidCallback? onEditVideo;

  const DanaviewControlsOverlay({
    super.key,
    required this.onOpenSettings,
    required this.onOpenQueue,
    required this.onToggleDiagnostics,
    required this.isLocked,
    required this.onToggleLock,
    this.onBack,
    this.topInset = 0,
    this.onEditVideo,
  });

  @override
  ConsumerState<DanaviewControlsOverlay> createState() => _DanaviewControlsOverlayState();
}

class _DanaviewControlsOverlayState extends ConsumerState<DanaviewControlsOverlay> {
  static const Duration _hideDelay = Duration(seconds: 3);
  static const Duration _lockHideDelay = Duration(milliseconds: 2500);

  /// After a double-tap seek, single taps on the same side keep seeking for this long.
  static const Duration _seekStreakWindow = Duration(milliseconds: 800);
  static const double _buttonSize = 40;
  static const double _barPadding = 12;
  static const TextStyle _timeStyle = TextStyle(
    fontSize: 12.5,
    fontWeight: FontWeight.w600,
    color: DanaviewColors.textPrimary,
    fontFeatures: [FontFeature.tabularFigures()],
  );
  static const TextStyle _speedStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w600);

  bool _isVisible = true;
  Timer? _hideTimer;
  TimeDisplayMode _timeMode = TimeDisplayMode.currentAndTotal;

  bool _lockVisible = true;
  Timer? _lockHideTimer;

  Offset? _doubleTapPosition;
  _SeekSide _seekSide = _SeekSide.forward;
  bool _seekActive = false;
  int _seekTotal = 0;
  int _seekPulse = 0;
  Timer? _seekStreakTimer;

  static bool get _supportsOrientationLock =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android);

  static bool get _isDesktop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);

  @override
  void initState() {
    super.initState();
    _scheduleHide();
    if (widget.isLocked) _scheduleLockHide();
  }

  @override
  void didUpdateWidget(DanaviewControlsOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isLocked == widget.isLocked) return;
    _hideTimer?.cancel();
    _isVisible = true;
    if (widget.isLocked) {
      _lockVisible = true;
      _scheduleLockHide();
    } else {
      _lockHideTimer?.cancel();
      _scheduleHide();
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _lockHideTimer?.cancel();
    _seekStreakTimer?.cancel();
    super.dispose();
  }

  void _scheduleLockHide() {
    _lockHideTimer?.cancel();
    _lockHideTimer = Timer(_lockHideDelay, () {
      if (mounted && widget.isLocked) setState(() => _lockVisible = false);
    });
  }

  /// While locked, any tap (or mouse movement) brings the unlock button back for a moment.
  void _revealLock() {
    if (!_lockVisible) setState(() => _lockVisible = true);
    _scheduleLockHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_hideDelay, () {
      if (mounted && ref.read(playerControllerProvider).isPlaying) {
        setState(() => _isVisible = false);
      }
    });
  }

  void _reveal() {
    if (!_isVisible) setState(() => _isVisible = true);
    _scheduleHide();
  }

  void _hide() {
    _hideTimer?.cancel();
    setState(() => _isVisible = false);
  }

  /// Left and right thirds seek on touch screens; the middle keeps its tap behaviour.
  _SeekSide? _seekSideAt(Offset position, double width) {
    if (!context.isTouchPlatform || width <= 0) return null;
    if (position.dx < width * 0.35) return _SeekSide.back;
    if (position.dx > width * 0.65) return _SeekSide.forward;
    return null;
  }

  void _onBackgroundTap(Offset position, double width) {
    final side = _seekSideAt(position, width);
    if (side != null && _seekActive && side == _seekSide) {
      _seek(side);
      return;
    }
    if (context.isTouchPlatform) {
      _isVisible ? _hide() : _reveal();
      return;
    }
    ref.read(playerControllerProvider.notifier).togglePlay();
    _reveal();
  }

  void _onBackgroundDoubleTap(double width) {
    final position = _doubleTapPosition;
    final side = position == null ? null : _seekSideAt(position, width);
    if (side != null) {
      _seek(side);
      return;
    }
    final playerCtrl = ref.read(playerControllerProvider.notifier);
    if (context.isTouchPlatform) {
      playerCtrl.togglePlay();
    } else {
      playerCtrl.toggleFullscreen();
    }
    _reveal();
  }

  void _seek(_SeekSide side) {
    final step = ref.read(doubleTapSeekProvider);
    ref
        .read(playerControllerProvider.notifier)
        .seekBy(Duration(seconds: side == _SeekSide.back ? -step : step));
    HapticFeedback.selectionClick();
    final continuing = _seekActive && side == _seekSide;
    setState(() {
      _seekTotal = continuing ? _seekTotal + step : step;
      _seekSide = side;
      _seekActive = true;
      _seekPulse++;
    });
    _seekStreakTimer?.cancel();
    _seekStreakTimer = Timer(_seekStreakWindow, () {
      if (mounted) setState(() => _seekActive = false);
    });
  }

  void _toggleOrientation() => PlayerOrientation.toggle(MediaQuery.orientationOf(context));

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(playerControllerProvider.select((s) => s.isPlaying), (_, playing) {
      if (playing) {
        _scheduleHide();
      } else {
        _reveal();
      }
    });
    final state = ref.watch(playerControllerProvider);
    final queue = ref.watch(queueControllerProvider);

    if (widget.isLocked) return _buildLocked(context);

    final padding = MediaQuery.paddingOf(context);
    final topBar = _buildTopBar(state, padding);
    if (!playerHasMedia(state)) {
      return Stack(children: [Positioned(top: 0, left: 0, right: 0, child: topBar)]);
    }

    final playerCtrl = ref.read(playerControllerProvider.notifier);
    final showSpinner = state.isBuffering || state.status == PlaybackStatus.loading;

    return MouseRegion(
      onHover: (_) => _reveal(),
      child: Stack(
        children: [
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) => _onBackgroundTap(details.localPosition, constraints.maxWidth),
                onDoubleTapDown: (details) => _doubleTapPosition = details.localPosition,
                onDoubleTap: () => _onBackgroundDoubleTap(constraints.maxWidth),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_isVisible,
              child: AnimatedOpacity(
                opacity: _isVisible ? 1.0 : 0.0,
                duration: DanaviewMotion.slow,
                curve: DanaviewMotion.curve,
                child: Listener(
                  onPointerDown: (_) => _reveal(),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: IgnorePointer(
                          child: _Scrims(
                            padding: padding,
                            topInset: widget.topInset,
                            bottomReserve: playerControlsReserve(context),
                          ),
                        ),
                      ),
                      Positioned(top: 0, left: 0, right: 0, child: topBar),
                      if (!state.isPlaying && !showSpinner) Center(child: _buildCenterPlay(state, playerCtrl)),
                      Positioned(left: 0, right: 0, bottom: 0, child: _buildBottomBar(state, queue, padding)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (showSpinner) const IgnorePointer(child: Center(child: DanaviewSpinner(size: 36))),
          Positioned.fill(
            child: IgnorePointer(
              child: _SeekIndicator(
                side: _seekSide,
                seconds: _seekTotal,
                visible: _seekActive,
                pulse: _seekPulse,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Built outside the fading controls so no in-flight hide animation of theirs can affect it. The
  /// unlock button fades away on its own; any tap brings it back without unlocking.
  Widget _buildLocked(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return MouseRegion(
      onHover: (_) => _revealLock(),
      child: Stack(
        key: const ValueKey('locked'),
        children: [
          Positioned.fill(
            child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: _revealLock),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(bottom: bottomInset + 24),
              child: IgnorePointer(
                ignoring: !_lockVisible,
                child: AnimatedOpacity(
                  opacity: _lockVisible ? 1.0 : 0.0,
                  duration: DanaviewMotion.slow,
                  curve: DanaviewMotion.curve,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(shape: BoxShape.circle, boxShadow: DanaviewShadows.subtle),
                    child: DanaviewIconButton(
                      icon: Icons.lock_rounded,
                      variant: DanaviewIconButtonVariant.filled,
                      size: 52,
                      iconSize: 24,
                      semanticLabel: 'Unlock controls',
                      onPressed: widget.onToggleLock,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCenterPlay(PlayerState state, PlayerController playerCtrl) {
    final ended = state.isEnded;
    return DecoratedBox(
      decoration: const BoxDecoration(shape: BoxShape.circle, boxShadow: DanaviewShadows.subtle),
      child: DanaviewIconButton(
        icon: ended ? Icons.replay_rounded : Icons.play_arrow_rounded,
        variant: DanaviewIconButtonVariant.primary,
        size: 64,
        iconSize: 34,
        tooltip: ended ? 'Replay' : 'Play',
        onPressed: ended
            ? () async {
                await playerCtrl.seek(Duration.zero);
                await playerCtrl.play();
              }
            : playerCtrl.play,
      ),
    );
  }

  Widget _buildTopBar(PlayerState state, EdgeInsets padding) {
    final title = widget.topInset == 0 ? state.currentMediaRef?.title : null;
    final hasMedia = playerHasMedia(state);
    return Padding(
      padding: EdgeInsets.fromLTRB(8 + padding.left, padding.top + widget.topInset + 6, 8 + padding.right, 12),
      child: Row(
        children: [
          if (widget.onBack != null)
            DanaviewIconButton(
              icon: Icons.arrow_back_ios_new_rounded,
              iconSize: 18,
              tooltip: 'Back',
              semanticLabel: 'Back',
              onPressed: widget.onBack,
            ),
          Expanded(
            child: title == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      title,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: DanaviewTextStyles.headline,
                    ),
                  ),
          ),
          if (hasMedia) ...[
            if (widget.onEditVideo != null)
              DanaviewIconButton(
                key: const ValueKey('player-edit-video'),
                icon: Icons.movie_edit,
                iconSize: 20,
                tooltip: 'Edit video (E)',
                semanticLabel: 'Edit this video',
                onPressed: widget.onEditVideo,
              ),
            DanaviewIconButton(
              icon: Icons.lock_open_rounded,
              iconSize: 20,
              tooltip: 'Lock controls',
              onPressed: widget.onToggleLock,
            ),
            DanaviewIconButton(
              icon: Icons.info_outline_rounded,
              iconSize: 20,
              tooltip: 'Stats for nerds (I)',
              onPressed: widget.onToggleDiagnostics,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBottomBar(PlayerState state, QueueState queue, EdgeInsets padding) {
    final playerCtrl = ref.read(playerControllerProvider.notifier);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _barPadding + padding.left,
        12,
        _barPadding + padding.right,
        8 + padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: DanaviewSeekBar(
              position: state.position,
              duration: state.duration,
              buffer: state.cacheEnd,
              chapters: state.chapters,
              abLoop: state.abLoop,
              onSeek: playerCtrl.seek,
            ),
          ),
          const SizedBox(height: 2),
          LayoutBuilder(
            builder: (context, constraints) => _buildControlsRow(context, state, queue, constraints.maxWidth),
          ),
        ],
      ),
    );
  }

  /// Lays out the control row for [width]: essentials always stay inline, the rest are added by
  /// priority while they fit, and everything else is reachable from the "more" sheet.
  Widget _buildControlsRow(BuildContext context, PlayerState state, QueueState queue, double width) {
    final playerCtrl = ref.read(playerControllerProvider.notifier);
    final queueCtrl = ref.read(queueControllerProvider.notifier);
    final touch = context.isTouchPlatform;
    final button = touch ? math.max(_buttonSize, DanaviewSpacing.minTapTarget) : _buttonSize;
    final compact = width < DanaviewBreakpoints.compact;
    final rotate = _supportsOrientationLock;
    final fullscreen = _isDesktop;
    final hasPrevious = queue.hasPrevious || state.position.inSeconds > 5;
    final speedLabel = formatPlaybackSpeed(state.speed);

    final candidates = <_BarItem, double>{
      if (queue.hasNext) _BarItem.next: button,
      if (hasPrevious) _BarItem.previous: button,
      _BarItem.settings: button,
      _BarItem.subtitles: button,
      _BarItem.queue: button,
      _BarItem.speed: _textWidth(context, speedLabel, _speedStyle) + 42 + 8,
      if (state.tracks.audioTracks.length > 1) _BarItem.audio: button,
      if (!compact) _BarItem.volume: (touch ? DanaviewSpacing.minTapTarget : 36) + 96 + 40 + 4,
    };

    final fullTime = _formatTime(state.position, state.duration, _timeMode);
    final fullTimeWidth = _timeExtent(context, state.duration);
    final mandatory = button + (rotate ? button : 0) + (fullscreen ? button : 0);
    final everything = mandatory + fullTimeWidth + candidates.values.fold(0.0, (sum, w) => sum + w);
    final showMore = compact || everything > width;

    final shown = <_BarItem>{};
    if (showMore) {
      var used = mandatory + button + fullTimeWidth;
      for (final MapEntry(key: item, value: extent) in candidates.entries) {
        if (used + extent <= width) {
          shown.add(item);
          used += extent;
        }
      }
    } else {
      shown.addAll(candidates.keys);
    }
    final timeFits = mandatory + (showMore ? button : 0) + fullTimeWidth <= width;
    final timeLabel = timeFits || _timeMode == TimeDisplayMode.remaining
        ? fullTime
        : formatPlaybackDuration(state.position);

    return Row(
      children: [
        DanaviewIconButton(
          icon: state.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          iconSize: 28,
          tooltip: state.isPlaying ? 'Pause (Space)' : 'Play (Space)',
          onPressed: playerCtrl.togglePlay,
        ),
        if (shown.contains(_BarItem.previous))
          DanaviewIconButton(
            icon: Icons.skip_previous_rounded,
            iconSize: 24,
            tooltip: 'Previous',
            onPressed: queueCtrl.previous,
          ),
        if (shown.contains(_BarItem.next))
          DanaviewIconButton(
            icon: Icons.skip_next_rounded,
            iconSize: 24,
            tooltip: 'Next',
            onPressed: queueCtrl.next,
          ),
        if (shown.contains(_BarItem.volume))
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: DanaviewVolumeSlider(
              volume: state.volume,
              muted: state.muted,
              onVolumeChanged: playerCtrl.setVolume,
              onToggleMute: playerCtrl.toggleMute,
            ),
          ),
        Expanded(
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: _buildTime(timeLabel),
          ),
        ),
        if (shown.contains(_BarItem.subtitles)) _buildSubtitleButton(state, playerCtrl),
        if (shown.contains(_BarItem.audio)) _buildAudioButton(state, playerCtrl),
        if (shown.contains(_BarItem.speed))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: DanaviewDropdown<double>(
              value: state.speed,
              compact: true,
              label: 'Speed',
              tooltip: 'Playback speed ([ / ])',
              menuWidth: 140,
              placeholder: speedLabel,
              options: [for (final s in _rowSpeeds) DanaviewOption(value: s, label: formatPlaybackSpeed(s))],
              onChanged: playerCtrl.setSpeed,
            ),
          ),
        if (shown.contains(_BarItem.queue))
          DanaviewIconButton(
            icon: Icons.playlist_play_rounded,
            iconSize: 24,
            tooltip: 'Queue (P)',
            onPressed: widget.onOpenQueue,
          ),
        if (shown.contains(_BarItem.settings))
          DanaviewIconButton(
            icon: Icons.settings_rounded,
            iconSize: 20,
            tooltip: 'Settings',
            onPressed: widget.onOpenSettings,
          ),
        if (rotate)
          DanaviewIconButton(
            icon: Icons.screen_rotation_rounded,
            iconSize: 20,
            tooltip: 'Rotate screen',
            onPressed: _toggleOrientation,
          ),
        if (fullscreen)
          DanaviewIconButton(
            icon: state.viewMode == ViewMode.fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
            iconSize: 24,
            tooltip: 'Fullscreen (F)',
            onPressed: playerCtrl.toggleFullscreen,
          ),
        if (showMore)
          DanaviewIconButton(
            icon: Icons.more_horiz_rounded,
            iconSize: 24,
            tooltip: 'More options',
            onPressed: () => _showMoreSheet(context),
          ),
      ],
    );
  }

  Widget _buildTime(String label) {
    final remaining = _timeMode == TimeDisplayMode.remaining;
    return DanaviewPressable(
      borderRadius: DanaviewRadius.controlAll,
      semanticLabel: remaining ? 'Time remaining $label' : 'Elapsed time $label',
      tooltip: remaining ? 'Show elapsed time' : 'Show remaining time',
      onTap: () => setState(() {
        _timeMode = remaining ? TimeDisplayMode.currentAndTotal : TimeDisplayMode.remaining;
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Text(label, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: _timeStyle),
      ),
    );
  }

  Widget _buildSubtitleButton(PlayerState state, PlayerController playerCtrl) {
    final tracks = state.tracks;
    final selectedId = tracks.selectedSubtitleTrackId;
    final isOn = selectedId != null && selectedId != 'no';
    return DanaviewMenuIconTrigger(
      icon: isOn ? Icons.subtitles_rounded : Icons.subtitles_off_outlined,
      iconSize: 20,
      tooltip: 'Subtitles (C)',
      menuWidth: 240,
      entries: [
        const DanaviewMenuHeader('Subtitles'),
        DanaviewMenuItem(label: 'Off', selected: !isOn, onTap: () => playerCtrl.setSubtitleTrack('no')),
        if (tracks.subtitleTracks.isNotEmpty) const DanaviewMenuDivider(),
        for (final track in tracks.subtitleTracks)
          DanaviewMenuItem(
            label: track.displayName,
            selected: track.id == selectedId,
            onTap: () => playerCtrl.setSubtitleTrack(track.id),
          ),
      ],
    );
  }

  Widget _buildAudioButton(PlayerState state, PlayerController playerCtrl) {
    final tracks = state.tracks;
    return DanaviewMenuIconTrigger(
      icon: Icons.audiotrack_rounded,
      iconSize: 20,
      tooltip: 'Audio track (#)',
      menuWidth: 240,
      entries: [
        const DanaviewMenuHeader('Audio track'),
        for (final track in tracks.audioTracks)
          DanaviewMenuItem(
            label: track.displayName,
            selected: track.id == tracks.selectedAudioTrackId,
            onTap: () => playerCtrl.setAudioTrack(track.id),
          ),
      ],
    );
  }

  void _showMoreSheet(BuildContext context) {
    showDanaviewSheet<void>(
      context,
      title: 'Playback',
      builder: (sheetContext) => Consumer(
        builder: (context, ref, _) {
          final state = ref.watch(playerControllerProvider);
          final queue = ref.watch(queueControllerProvider);
          final playerCtrl = ref.read(playerControllerProvider.notifier);
          final queueCtrl = ref.read(queueControllerProvider.notifier);
          final tracks = state.tracks;
          final hasPrevious = queue.hasPrevious || state.position.inSeconds > 5;
          final count = queue.items.length;

          void closeThen(VoidCallback action) {
            Navigator.of(sheetContext).pop();
            action();
          }

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (hasPrevious || queue.hasNext) ...[
                const SizedBox(height: 4),
                DanaviewButtonBar(
                  reverseWhenStacked: false,
                  children: [
                    if (hasPrevious)
                      DanaviewButton.secondary(
                        label: 'Previous',
                        icon: Icons.skip_previous_rounded,
                        onPressed: () => closeThen(queueCtrl.previous),
                      ),
                    if (queue.hasNext)
                      DanaviewButton.secondary(
                        label: 'Next',
                        icon: Icons.skip_next_rounded,
                        onPressed: () => closeThen(queueCtrl.next),
                      ),
                  ],
                ),
              ],
              const _SheetLabel('Volume'),
              _SheetVolumeRow(
                volume: state.volume,
                muted: state.muted,
                onChanged: playerCtrl.setVolume,
                onToggleMute: playerCtrl.toggleMute,
              ),
              const _SheetLabel('Speed'),
              DanaviewSegmentedControl<double>(
                value: state.speed,
                options: [for (final s in _sheetSpeeds) DanaviewOption(value: s, label: formatPlaybackSpeed(s))],
                onChanged: playerCtrl.setSpeed,
              ),
              const _SheetLabel('Subtitles'),
              DanaviewDropdown<String>(
                value: tracks.selectedSubtitleTrackId ?? 'no',
                expand: true,
                icon: Icons.subtitles_rounded,
                placeholder: 'Auto',
                options: [
                  const DanaviewOption(value: 'no', label: 'Off'),
                  for (final track in tracks.subtitleTracks) DanaviewOption(value: track.id, label: track.displayName),
                ],
                onChanged: playerCtrl.setSubtitleTrack,
              ),
              if (tracks.audioTracks.isNotEmpty) ...[
                const _SheetLabel('Audio track'),
                DanaviewDropdown<String>(
                  value: tracks.selectedAudioTrackId ?? '',
                  expand: true,
                  icon: Icons.audiotrack_rounded,
                  placeholder: 'Default',
                  enabled: tracks.audioTracks.length > 1,
                  options: [
                    for (final track in tracks.audioTracks) DanaviewOption(value: track.id, label: track.displayName),
                  ],
                  onChanged: playerCtrl.setAudioTrack,
                ),
              ],
              const SizedBox(height: 16),
              Container(height: DanaviewBorders.width, color: DanaviewColors.hairline),
              const SizedBox(height: 8),
              if (widget.onEditVideo case final onEdit?)
                DanaviewListTile(
                  key: const ValueKey('player-sheet-edit-video'),
                  leading: const DanaviewIconTile(Icons.movie_edit),
                  title: 'Edit video',
                  subtitle: 'Trim, add text, captions and more',
                  showChevron: true,
                  onTap: () => closeThen(onEdit),
                ),
              DanaviewListTile(
                leading: const DanaviewIconTile(Icons.playlist_play_rounded),
                title: 'Queue',
                subtitle: count == 1 ? '1 video' : '$count videos',
                showChevron: true,
                onTap: () => closeThen(widget.onOpenQueue),
              ),
              DanaviewListTile(
                leading: const DanaviewIconTile(Icons.settings_rounded),
                title: 'Settings',
                subtitle: 'Video, audio, subtitles and more',
                showChevron: true,
                onTap: () => closeThen(widget.onOpenSettings),
              ),
            ],
          );
        },
      ),
    );
  }

  double _timeExtent(BuildContext context, Duration duration) {
    final total = formatPlaybackDuration(duration);
    final widest = math.max(
      _textWidth(context, '$total / $total', _timeStyle),
      _textWidth(context, '-$total', _timeStyle),
    );
    return widest + 16;
  }

  static double _textWidth(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: DefaultTextStyle.of(context).style.merge(style)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width.ceilToDouble();
    painter.dispose();
    return width;
  }

  static String _formatTime(Duration pos, Duration dur, TimeDisplayMode mode) {
    if (mode == TimeDisplayMode.remaining && dur > Duration.zero) {
      final remaining = dur - pos;
      return '-${formatPlaybackDuration(remaining.isNegative ? Duration.zero : remaining)}';
    }
    return '${formatPlaybackDuration(pos)} / ${formatPlaybackDuration(dur)}';
  }
}

/// Near-solid shade behind the top and bottom bars that eases out toward the middle, so the
/// controls stay legible over bright frames without a hard edge.
class _Scrims extends StatelessWidget {
  const _Scrims({required this.padding, required this.topInset, required this.bottomReserve});

  static const double _alpha = 0.86;
  static const double _topBar = 56;
  static const double _fade = 64;

  final EdgeInsets padding;
  final double topInset;
  final double bottomReserve;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        if (height <= 0) return const SizedBox.shrink();
        double frac(double y) => (y / height).clamp(0.0, 1.0);
        final topSolid = padding.top + topInset + _topBar;
        final bottomSolid = math.max(height - padding.bottom - bottomReserve, topSolid);
        final mid = (topSolid + bottomSolid) / 2;
        final topClear = math.min(topSolid + _fade, math.max(mid, topSolid));
        final bottomClear = math.max(bottomSolid - _fade, math.min(mid, bottomSolid));
        Color shade(double alpha) => DanaviewColors.background.withValues(alpha: alpha);
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [
                0,
                frac(topSolid),
                frac((topSolid + topClear) / 2),
                frac(topClear),
                frac(bottomClear),
                frac((bottomClear + bottomSolid) / 2),
                frac(bottomSolid),
                1,
              ],
              colors: [
                shade(_alpha),
                shade(_alpha),
                shade(_alpha * 0.4),
                shade(0),
                shade(0),
                shade(_alpha * 0.4),
                shade(_alpha),
                shade(_alpha),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SheetLabel extends StatelessWidget {
  const _SheetLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return DanaviewSectionHeader(label, padding: const EdgeInsets.fromLTRB(4, 16, 4, 8));
  }
}

class _SheetVolumeRow extends StatelessWidget {
  const _SheetVolumeRow({
    required this.volume,
    required this.muted,
    required this.onChanged,
    required this.onToggleMute,
  });

  final double volume;
  final bool muted;
  final ValueChanged<double> onChanged;
  final VoidCallback onToggleMute;

  @override
  Widget build(BuildContext context) {
    final effective = muted ? 0.0 : volume.clamp(0.0, 300.0);
    final boosted = effective > 100;
    final accent = boosted ? DanaviewColors.boostBand : DanaviewColors.primary;
    return Row(
      children: [
        DanaviewIconButton(
          icon: effective == 0
              ? Icons.volume_off_rounded
              : effective <= 100
                  ? Icons.volume_down_rounded
                  : Icons.volume_up_rounded,
          iconSize: 20,
          color: boosted ? DanaviewColors.boostBand : DanaviewColors.textPrimary,
          tooltip: muted ? 'Unmute' : 'Mute',
          onPressed: onToggleMute,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: DanaviewSlider(
            value: effective,
            min: 0,
            max: 300,
            activeColor: accent,
            semanticLabel: 'Volume',
            semanticFormatter: (v) => '${v.round()}%',
            onChanged: onChanged,
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 48,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerEnd,
            child: Text(
              '${effective.round()}%',
              maxLines: 1,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: boosted ? DanaviewColors.boostBand : DanaviewColors.textSecondary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// "« 10s" / "10s »" bubble shown on the side a double tap seeks towards.
class _SeekIndicator extends StatelessWidget {
  const _SeekIndicator({required this.side, required this.seconds, required this.visible, required this.pulse});

  final _SeekSide side;
  final int seconds;
  final bool visible;

  /// Changes on every seek so the bubble slides in again.
  final int pulse;

  /// How far the bubble slides in, towards the side it seeks to (§11: a plain slide, no bounce).
  static const double _slide = 8;

  @override
  Widget build(BuildContext context) {
    final back = side == _SeekSide.back;
    // §11: with Reduce Motion on, the bubble only crossfades.
    final slide = MediaQuery.disableAnimationsOf(context) ? 0.0 : _slide;
    return LayoutBuilder(
      builder: (context, constraints) {
        final bubble = TweenAnimationBuilder<double>(
          key: ValueKey(pulse),
          tween: Tween(begin: 0.0, end: 1.0),
          duration: DanaviewMotion.fast,
          curve: DanaviewMotion.curve,
          builder: (context, t, child) => Opacity(
            opacity: 0.5 + 0.5 * t,
            child: Transform.translate(offset: Offset((back ? slide : -slide) * (1 - t), 0), child: child),
          ),
          child: Semantics(
            liveRegion: true,
            label: back ? 'Back $seconds seconds' : 'Forward $seconds seconds',
            child: ExcludeSemantics(
              child: DanaviewSurface(
                color: DanaviewColors.overlayDark,
                borderRadius: DanaviewRadius.toastAll,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (back) const Icon(Icons.fast_rewind_rounded, size: 22, color: DanaviewColors.textPrimary),
                    if (back) const SizedBox(width: 6),
                    Text(
                      '${seconds}s',
                      maxLines: 1,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: DanaviewColors.textPrimary,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (!back) const SizedBox(width: 6),
                    if (!back) const Icon(Icons.fast_forward_rounded, size: 22, color: DanaviewColors.textPrimary),
                  ],
                ),
              ),
            ),
          ),
        );
        return AnimatedOpacity(
          opacity: visible ? 1.0 : 0.0,
          duration: DanaviewMotion.normal,
          curve: DanaviewMotion.curve,
          child: Align(
            alignment: back ? const Alignment(-0.62, 0) : const Alignment(0.62, 0),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.3),
              child: FittedBox(fit: BoxFit.scaleDown, child: bubble),
            ),
          ),
        );
      },
    );
  }
}
