/// Typical average bitrates of streamed video at each quality (H.264-class codecs).
enum StreamQuality {
  sd480('480p', 'SD', 1.5),
  hd720('720p', 'HD', 3),
  fullHd1080('1080p', 'Full HD', 5),
  qhd1440('1440p', 'Quad HD', 9),
  uhd4k('4K', 'Ultra HD', 16);

  const StreamQuality(this.label, this.description, this.megabitsPerSecond);

  final String label;
  final String description;
  final double megabitsPerSecond;
}

/// Data math for the usage calculator, in decimal units as carriers bill them
/// (1 Mbps = 1,000,000 bits per second, 1 GB = 1,000,000,000 bytes).
abstract final class DataUsageMath {
  static const double bytesPerGigabyte = 1e9;

  /// Bytes used by [duration] of video at [megabitsPerSecond].
  static double bytesFor(double megabitsPerSecond, Duration duration) {
    if (megabitsPerSecond <= 0 || duration <= Duration.zero) return 0;
    return megabitsPerSecond * 1e6 / 8 * duration.inMicroseconds / 1e6;
  }

  static double bytesPerHour(double megabitsPerSecond) => bytesFor(megabitsPerSecond, const Duration(hours: 1));

  /// How long [bytes] of data lasts at [megabitsPerSecond], rounded down to whole seconds.
  static Duration watchTimeFor(double megabitsPerSecond, double bytes) {
    if (megabitsPerSecond <= 0 || bytes <= 0) return Duration.zero;
    return Duration(seconds: (bytes * 8 / (megabitsPerSecond * 1e6)).floor());
  }
}
