/// `0.85`, `12.4`, `250`: two significant-ish digits at low speeds, whole numbers once they're big.
String formatMbps(double mbps) {
  if (mbps >= 100) return mbps.toStringAsFixed(0);
  if (mbps >= 1) return mbps.toStringAsFixed(1);
  return mbps.toStringAsFixed(2);
}

/// `5.2 Mbps`, `850 kbps`. Values and units are joined with a no-break space here and below, so a
/// narrow line never strands a unit away from its number.
String formatBitrate(int bitsPerSecond) {
  if (bitsPerSecond >= 1000000) return '${formatMbps(bitsPerSecond / 1000000)}\u00A0Mbps';
  return '${(bitsPerSecond / 1000).round()}\u00A0kbps';
}

/// `23 ms`, or `0.8 ms` on a very short round trip.
String formatMs(double ms) => '${formatMsValue(ms)}\u00A0ms';

/// [formatMs] without the unit, for tiles that label it separately.
String formatMsValue(double ms) => ms < 10 ? ms.toStringAsFixed(1) : '${ms.round()}';

/// `1 h 02 min`, `4 min 05 s`, `12 s`.
String formatStreamDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (h > 0) return '$h\u00A0h ${m.toString().padLeft(2, '0')}\u00A0min';
  if (m > 0) return '$m\u00A0min ${s.toString().padLeft(2, '0')}\u00A0s';
  return '${d.inMilliseconds < 1000 && d > Duration.zero ? 1 : s}\u00A0s';
}
