import 'dart:math' as math;

import 'package:danaview_data/danaview_data.dart';

import '../library/library_format.dart';

/// [value] with up to [decimals] places and no trailing zeros: `2.25`, `1.5`, `675`.
String _trimmed(double value, int decimals) {
  final text = value.toStringAsFixed(decimals);
  if (!text.contains('.')) return text;
  return text.replaceFirst(RegExp(r'\.?0+$'), '');
}

/// Joins a value and its unit so a narrow line never strands the unit (`5` / `Mbps`). Every
/// formatter below uses it; [mediaInfoSummary] turns it back into a plain space for the clipboard.
const String _nbsp = '\u00A0';

/// `850 bytes`, `12.4 MB`, `2.25 GB`, in decimal units as storage and data plans count them.
String formatDataSize(num bytes) {
  if (bytes < 1000) {
    final whole = bytes.round();
    return whole == 1 ? '1${_nbsp}byte' : '$whole${_nbsp}bytes';
  }
  const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
  var value = bytes / 1000;
  var unit = 0;
  // 999.6 would print as "1000 KB" with no decimals, so it moves up a unit first.
  while (value >= 999.5 && unit < units.length - 1) {
    value /= 1000;
    unit++;
  }
  final decimals = value >= 100 ? 0 : (value >= 10 ? 1 : 2);
  return '${_trimmed(value, decimals)}$_nbsp${units[unit]}';
}

/// `1,523,456,789`.
String formatThousands(int value) {
  final digits = value.abs().toString();
  final buffer = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// `5 Mbps`, `12.5 Mbps`.
String formatMbps(double megabitsPerSecond) =>
    '${_trimmed(megabitsPerSecond, megabitsPerSecond >= 100 ? 0 : 1)}${_nbsp}Mbps';

/// `8.2 Mbps`, `128 kbps`.
String formatBitRate(num bitsPerSecond) {
  if (bitsPerSecond >= 1e6) return formatMbps(bitsPerSecond / 1e6);
  if (bitsPerSecond >= 1e3) return '${(bitsPerSecond / 1e3).round()}${_nbsp}kbps';
  return '${bitsPerSecond.round()}${_nbsp}bps';
}

/// `23.976 fps`, `29.97 fps`, `30 fps`.
String formatFrameRate(double fps) => '${_trimmed(fps, 3)}${_nbsp}fps';

/// `48 kHz`, `44.1 kHz`.
String formatSampleRate(int hertz) => '${_trimmed(hertz / 1000, 2)}${_nbsp}kHz';

/// `5.1`, `6.1` or `7.1` for surround layouts; null otherwise.
String? surroundName(int channels) => const {6: '5.1', 7: '6.1', 8: '7.1'}[channels];

/// `Mono`, `Stereo`, `5.1 (6 channels)`.
String formatChannels(int channels) {
  if (channels == 1) return 'Mono';
  if (channels == 2) return 'Stereo';
  final surround = surroundName(channels);
  return surround == null ? '$channels channels' : '$surround ($channels channels)';
}

/// `4 h 26 min`, `45 min`, `2 h`; `Under a minute` for anything shorter.
String formatWatchTime(Duration d) {
  if (d < const Duration(minutes: 1)) return d > Duration.zero ? 'Under a minute' : '0${_nbsp}min';
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  if (h == 0) return '$m${_nbsp}min';
  return m == 0 ? '$h${_nbsp}h' : '$h${_nbsp}h $m${_nbsp}min';
}

/// `4K`, `1080p`, `720p`…, named from the longer side so portrait and widescreen videos match
/// their landscape equivalents; null below 360p.
String? resolutionName(int width, int height) {
  final long = math.max(width, height);
  final short = math.min(width, height);
  return switch ((long, short)) {
    (>= 7600, _) => '8K',
    (>= 3800, _) || (_, >= 2100) => '4K',
    (>= 2500, _) || (_, >= 1400) => '1440p',
    (>= 1900, _) || (_, >= 1060) => '1080p',
    (>= 1260, _) || (_, >= 700) => '720p',
    (>= 840, _) || (_, >= 470) => '480p',
    (_, >= 350) => '360p',
    _ => null,
  };
}

/// `1920 × 1080 (1080p)`.
String formatResolution(int width, int height) {
  final name = resolutionName(width, height);
  return name == null ? '$width × $height' : '$width × $height ($name)';
}

String formatContainer(MediaContainer container) {
  if (container == MediaContainer.unknown) return container.label;
  if (container.label.toUpperCase() == container.shortName) return container.label;
  return '${container.label} (${container.shortName})';
}

const _languageNames = {
  'en': 'English', 'eng': 'English',
  'es': 'Spanish', 'spa': 'Spanish',
  'fr': 'French', 'fre': 'French', 'fra': 'French',
  'de': 'German', 'ger': 'German', 'deu': 'German',
  'it': 'Italian', 'ita': 'Italian',
  'pt': 'Portuguese', 'por': 'Portuguese',
  'nl': 'Dutch', 'dut': 'Dutch', 'nld': 'Dutch',
  'sv': 'Swedish', 'swe': 'Swedish',
  'no': 'Norwegian', 'nb': 'Norwegian', 'nor': 'Norwegian', 'nob': 'Norwegian',
  'da': 'Danish', 'dan': 'Danish',
  'fi': 'Finnish', 'fin': 'Finnish',
  'pl': 'Polish', 'pol': 'Polish',
  'cs': 'Czech', 'cze': 'Czech', 'ces': 'Czech',
  'hu': 'Hungarian', 'hun': 'Hungarian',
  'ro': 'Romanian', 'rum': 'Romanian', 'ron': 'Romanian',
  'el': 'Greek', 'gre': 'Greek', 'ell': 'Greek',
  'tr': 'Turkish', 'tur': 'Turkish',
  'ru': 'Russian', 'rus': 'Russian',
  'uk': 'Ukrainian', 'ukr': 'Ukrainian',
  'ar': 'Arabic', 'ara': 'Arabic',
  'he': 'Hebrew', 'heb': 'Hebrew',
  'fa': 'Persian', 'per': 'Persian', 'fas': 'Persian',
  'hi': 'Hindi', 'hin': 'Hindi',
  'bn': 'Bengali', 'ben': 'Bengali',
  'ur': 'Urdu', 'urd': 'Urdu',
  'ta': 'Tamil', 'tam': 'Tamil',
  'te': 'Telugu', 'tel': 'Telugu',
  'ml': 'Malayalam', 'mal': 'Malayalam',
  'th': 'Thai', 'tha': 'Thai',
  'vi': 'Vietnamese', 'vie': 'Vietnamese',
  'id': 'Indonesian', 'ind': 'Indonesian',
  'ms': 'Malay', 'may': 'Malay', 'msa': 'Malay',
  'fil': 'Filipino', 'tl': 'Tagalog', 'tgl': 'Tagalog',
  'zh': 'Chinese', 'chi': 'Chinese', 'zho': 'Chinese',
  'ja': 'Japanese', 'jpn': 'Japanese',
  'ko': 'Korean', 'kor': 'Korean',
};

/// `Japanese`, `Portuguese (pt-BR)`; unknown codes are shown as written.
String formatLanguage(String code) {
  final parts = code.split(RegExp('[-_]'));
  final name = _languageNames[parts.first.toLowerCase()];
  if (name == null) return code;
  return parts.length > 1 ? '$name ($code)' : name;
}

/// `90°` clockwise.
String formatRotation(int degrees) => '$degrees°';

/// `H.264 (AVC) · 1920 × 1080 (1080p) · 23.976 fps` for one-line summaries.
String describeTrack(MediaTrackInfo track) {
  final parts = <String>[
    track.codec,
    if (track.profile != null) track.profile!,
    if (track.width != null && track.height != null) formatResolution(track.width!, track.height!),
    if (track.frameRate != null) formatFrameRate(track.frameRate!),
    if (track.bitDepth != null) '${track.bitDepth}-bit',
    if (track.hdr != null) track.hdr!,
    if (track.rotation != 0) 'rotated ${formatRotation(track.rotation)}',
    if (track.channels != null) formatChannels(track.channels!),
    if (track.sampleRate != null) formatSampleRate(track.sampleRate!),
    if (track.bitrate != null) formatBitRate(track.bitrate!),
    if (track.language != null) formatLanguage(track.language!),
    if (track.name != null) '"${track.name}"',
    if (track.isDefault && track.kind == MediaTrackKind.subtitle) 'default',
    if (track.isForced) 'forced',
    if (track.encrypted) 'encrypted',
  ];
  return parts.join(' · ');
}

/// What "fast start" means for this file, or null when it doesn't apply.
String? formatFastStart(MediaFileInfo info) {
  final fastStart = info.fastStart;
  if (fastStart == null) return null;
  if (info.fragmented) return 'Fragmented, ready for streaming';
  return fastStart ? 'Optimized (fast start)' : 'Not optimized: the index is at the end';
}

/// A plain-text report of [info] for the clipboard.
String mediaInfoSummary(MediaFileInfo info) {
  final lines = <String>[
    'File: ${info.fileName}',
    'Size: ${formatDataSize(info.sizeBytes)} (${formatThousands(info.sizeBytes)} bytes)',
    'Format: ${formatContainer(info.container)}',
    if (info.duration != null) 'Duration: ${formatClock(info.duration!)}',
    if (info.overallBitrate != null) 'Overall bitrate: ${formatBitRate(info.overallBitrate!)}',
    if (info.title != null) 'Title: ${info.title}',
    if (info.encoder != null) 'Written by: ${info.encoder}',
    if (formatFastStart(info) case final streaming?) 'Streaming: $streaming',
  ];
  void addTracks(String label, List<MediaTrackInfo> tracks) {
    for (var i = 0; i < tracks.length; i++) {
      lines.add('$label${tracks.length > 1 ? ' ${i + 1}' : ''}: ${describeTrack(tracks[i])}');
    }
  }

  addTracks('Video', info.videoTracks);
  addTracks('Audio', info.audioTracks);
  addTracks('Subtitles', info.subtitleTracks);
  for (final warning in info.warnings) {
    lines.add('Note: $warning');
  }
  return lines.join('\n').replaceAll(_nbsp, ' ');
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// `3 Oct 2026, 09:41` in local time.
String formatDateTime(DateTime time) {
  final t = time.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.day} ${_months[t.month - 1]} ${t.year}, ${two(t.hour)}:${two(t.minute)}';
}

/// The last segment of a path, with either separator.
String fileNameOf(String path) {
  final parts = path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}
