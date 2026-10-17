// OWNER: CORE-03
//
// Per-clip audio properties (ARCH §6.6).

import 'package:meta/meta.dart';

import '../time/time.dart';

/// Audio properties of a media clip.
///
/// [volume] is a linear gain in [0, 2] (1 = 0 dB, 2 ≈ +6 dB) and is keyframable; fades are on the
/// frame grid and each is at most half the clip duration. Gains above 1 are applied per sample on
/// both platforms (iOS: `MTAudioProcessingTap`, Android: `GainProcessor`; ARCH §13.2/§13.3).
@immutable
final class AudioProps {
  /// Creates audio properties; the default is unity gain, unmuted, no fades.
  const AudioProps({this.volume = 1, this.muted = false, this.fadeIn = 0, this.fadeOut = 0});

  /// Unity gain, no fades.
  static const AudioProps unity = AudioProps();

  /// Linear gain in [0, 2].
  final double volume;

  /// Clip mute (track mute/solo are separate, on the track).
  final bool muted;

  /// Fade-in length in µs (on grid).
  final TimeUs fadeIn;

  /// Fade-out length in µs (on grid).
  final TimeUs fadeOut;

  /// A copy with the given fields replaced.
  AudioProps copyWith({double? volume, bool? muted, TimeUs? fadeIn, TimeUs? fadeOut}) => AudioProps(
        volume: volume ?? this.volume,
        muted: muted ?? this.muted,
        fadeIn: fadeIn ?? this.fadeIn,
        fadeOut: fadeOut ?? this.fadeOut,
      );

  @override
  bool operator ==(Object other) =>
      other is AudioProps &&
      other.volume == volume &&
      other.muted == muted &&
      other.fadeIn == fadeIn &&
      other.fadeOut == fadeOut;

  @override
  int get hashCode => Object.hash(volume, muted, fadeIn, fadeOut);
}
