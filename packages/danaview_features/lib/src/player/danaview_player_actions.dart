import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_platform/danaview_platform.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import '../controllers/providers.dart';
import '../library/media_picker.dart';
import 'screen_orientation_policy.dart';

/// Height the bottom control bar occupies above the safe area, plus a small gap.
double playerControlsReserve(BuildContext context) => context.isTouchPlatform ? 118 : 98;

/// Whether this window draws its own [DanaviewTitleBar] (desktop, outside touch layouts).
bool hasDesktopWindowChrome(BuildContext context) => PlatformBridge.isDesktop && !context.isTouchPlatform;

/// Above the control bar; on short (landscape phone) screens just below the top bar instead, so it
/// can't cover the centre play button.
void showPlayerToast(BuildContext context, String message, {DanaviewToastKind kind = DanaviewToastKind.info}) {
  final short = MediaQuery.sizeOf(context).height < 560;
  DanaviewToast.show(
    context,
    message,
    kind: kind,
    // On desktop the controls' top bar sits under the window title bar and ends at about 84.
    topOffset: short ? (hasDesktopWindowChrome(context) ? DanaviewTitleBar.height + 52 : 64) : null,
    bottomOffset: playerControlsReserve(context),
  );
}

/// True once something was opened; the engine may report playback before the controller knows the source.
bool playerHasMedia(PlayerState state) =>
    state.currentSource != null || state.status != PlaybackStatus.idle;

/// Picks videos and plays them, or appends them to the queue when [append] is true.
Future<void> openVideoFiles(BuildContext context, WidgetRef ref, {bool append = false}) async {
  final List<MediaRef> refs;
  try {
    refs = await pickVideoRefs();
  } on MediaPickerException catch (e) {
    if (context.mounted) {
      showPlayerToast(context, e.message, kind: DanaviewToastKind.error);
    }
    return;
  }
  if (refs.isEmpty) return;
  final queueCtrl = ref.read(queueControllerProvider.notifier);
  if (append) {
    await queueCtrl.addToQueue(refs);
  } else {
    await queueCtrl.playFrom(refs);
  }
}

String formatPlaybackDuration(Duration d) {
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

String formatPlaybackSpeed(double speed) {
  final fixed = speed.toStringAsFixed(2);
  final trimmed = fixed.replaceFirst(RegExp(r'\.?0+$'), '');
  return '${trimmed}x';
}

String playerErrorMessage(PlayerError error) {
  return switch (error) {
    FileNotFound() => "Couldn't find this video. It may have been moved or deleted.",
    UnsupportedFormat() => "This video's format isn't supported.",
    DecoderInitFailed() => 'Hardware decoding failed, so Danaview switched to software decoding.',
    NetworkUnreachable() => "Can't reach this stream. Check your connection and try again.",
    YtdlpFailed() => "Couldn't load this online video. Check the link and try again.",
    PermissionDenied() => "Danaview doesn't have permission to open this video.",
    AudioDeviceLost() => 'The audio device was disconnected.',
    AudioOutputUnavailable() => 'No audio output available',
    PlaybackWarning() || GenericPlayerError() => "Couldn't play this video.",
  };
}

/// Problems playback recovers from are informational, not failures.
DanaviewToastKind playerErrorToastKind(PlayerError error) => switch (error) {
      AudioOutputUnavailable() || DecoderInitFailed() || PlaybackWarning() => DanaviewToastKind.info,
      _ => DanaviewToastKind.error,
    };

/// Orientation policy for the player: phones keep the library upright, the player follows the
/// device (or the orientation the rotate button locked), and tablets rotate freely everywhere.
///
/// A thin wrapper over [ScreenOrientationPolicy] that keeps the player's call sites unchanged:
/// each player screen is an owner in the policy's stack (mode [OrientationMode.followDevice]), so
/// an editor opened over it can enter and release without leaving the player without an owner.
abstract final class PlayerOrientation {
  static Future<void> applyAppDefault() => ScreenOrientationPolicy.applyAppDefault();

  static Future<void> enter(Object owner) => ScreenOrientationPolicy.enter(owner, OrientationMode.followDevice);

  /// Flips between portrait and landscape and holds it there regardless of how the device is held.
  static Future<void> toggle(Orientation current) {
    final owner = ScreenOrientationPolicy.topOwner;
    return owner == null ? Future<void>.value() : ScreenOrientationPolicy.toggle(owner, current);
  }

  /// Restoring the app default also rotates a phone back upright, however the player was held.
  /// Does nothing once [owner] has released.
  static Future<void> release(Object owner) => ScreenOrientationPolicy.release(owner);
}
