import 'package:meta/meta.dart';

@immutable
class EqualizerBand {
  final int frequency; // 31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 Hz
  final double gain;     // -12.0 to +12.0 dB

  const EqualizerBand({
    required this.frequency,
    this.gain = 0.0,
  });

  EqualizerBand copyWith({double? gain}) => EqualizerBand(
        frequency: frequency,
        gain: gain ?? this.gain,
      );

  String get label {
    if (frequency >= 1000) {
      return '${frequency ~/ 1000}k';
    }
    return '$frequency';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EqualizerBand &&
          runtimeType == other.runtimeType &&
          frequency == other.frequency &&
          gain == other.gain;

  @override
  int get hashCode => frequency.hashCode ^ gain.hashCode;
}

@immutable
class AudioFilter {
  final List<EqualizerBand> equalizerBands;
  final bool nightModeDrc;         // dynamic range compression (dynaudnorm)
  final bool loudnessNormalization; // loudnorm=I=-16
  final String channelDownmix;      // 'auto', 'stereo', 'mono', '5.1'

  const AudioFilter({
    this.equalizerBands = defaultBands,
    this.nightModeDrc = false,
    this.loudnessNormalization = false,
    this.channelDownmix = 'auto',
  });

  static const List<EqualizerBand> defaultBands = [
    EqualizerBand(frequency: 31, gain: 0.0),
    EqualizerBand(frequency: 62, gain: 0.0),
    EqualizerBand(frequency: 125, gain: 0.0),
    EqualizerBand(frequency: 250, gain: 0.0),
    EqualizerBand(frequency: 500, gain: 0.0),
    EqualizerBand(frequency: 1000, gain: 0.0),
    EqualizerBand(frequency: 2000, gain: 0.0),
    EqualizerBand(frequency: 4000, gain: 0.0),
    EqualizerBand(frequency: 8000, gain: 0.0),
    EqualizerBand(frequency: 16000, gain: 0.0),
  ];

  static const Map<String, List<double>> presets = {
    'Flat': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    'Rock': [4.5, 3.5, 2.0, 0.0, -1.0, -0.5, 1.5, 3.0, 4.0, 4.5],
    'Pop': [-1.5, -0.5, 1.0, 3.0, 4.5, 4.0, 2.5, 0.5, -1.0, -1.5],
    'Bass Boost': [6.0, 5.0, 3.5, 2.0, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0],
    'Vocal / Dialogue': [-3.0, -2.0, -1.0, 1.0, 3.5, 4.0, 3.5, 2.0, 0.0, -2.0],
    'Classical': [4.0, 3.0, 2.5, 2.0, -1.5, -1.5, 0.0, 2.0, 3.0, 3.5],
    'Cinema': [3.5, 2.5, 0.0, -1.0, 1.5, 2.5, 3.0, 2.0, 3.5, 4.0],
  };

  AudioFilter copyWith({
    List<EqualizerBand>? equalizerBands,
    bool? nightModeDrc,
    bool? loudnessNormalization,
    String? channelDownmix,
  }) {
    return AudioFilter(
      equalizerBands: equalizerBands ?? this.equalizerBands,
      nightModeDrc: nightModeDrc ?? this.nightModeDrc,
      loudnessNormalization: loudnessNormalization ?? this.loudnessNormalization,
      channelDownmix: channelDownmix ?? this.channelDownmix,
    );
  }

  AudioFilter applyPreset(String presetName) {
    final gains = presets[presetName];
    if (gains == null || gains.length != equalizerBands.length) return this;
    final updated = List<EqualizerBand>.generate(
      equalizerBands.length,
      (i) => equalizerBands[i].copyWith(gain: gains[i]),
    );
    return copyWith(equalizerBands: updated);
  }
}
