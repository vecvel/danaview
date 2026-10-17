import 'package:flutter/material.dart';
import 'package:danaview_domain/danaview_domain.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

String formatCount(int count, String noun) => count == 1 ? '1 $noun' : '$count ${noun}s';

/// `1:02:03` or `4:05`.
String formatClock(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// `1h 5m`, `2h`, `12m`, or `10s` under a minute (never below `1s`).
String formatShortDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  if (d < const Duration(minutes: 1)) return '${d.inSeconds < 1 ? 1 : d.inSeconds}s';
  if (h == 0) return '${m}m';
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}

String? mediaHost(MediaRef media) {
  if (!media.isRemote) return null;
  final host = Uri.tryParse(media.pathOrUri)?.host ?? '';
  return host.isEmpty ? null : host;
}

/// `S01E02` / `E07`, or null when the file name had no episode number.
String? episodeLabel(MediaRef media) {
  if (media.episodeNumber <= 0) return null;
  final episode = 'E${media.episodeNumber.toString().padLeft(2, '0')}';
  return media.seasonNumber > 0 ? 'S${media.seasonNumber.toString().padLeft(2, '0')}$episode' : episode;
}

String fileExtensionLabel(String path) {
  final name = path.split(RegExp(r'[/\\]')).last;
  final dot = name.lastIndexOf('.');
  return dot <= 0 || dot == name.length - 1 ? 'Video' : name.substring(dot + 1).toUpperCase();
}

String parentFolderName(String path) {
  final parts = path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).toList();
  return parts.length >= 2 ? parts[parts.length - 2] : path;
}

IconData mediaIcon(MediaRef media) {
  if (!media.isRemote) return Icons.movie_rounded;
  final scheme = Uri.tryParse(media.pathOrUri)?.scheme.toLowerCase();
  return scheme == 'http' || scheme == 'https' ? Icons.language_rounded : Icons.podcasts_rounded;
}

Color mediaIconColor(MediaRef media) => media.isRemote ? DanaviewColors.cyan : DanaviewColors.primaryLight;

/// Secondary line for a media row: missing state, time left, host, length, then [fallback].
String mediaSubtitle(MediaRef media, ResumeInfo? resume, {required bool exists, required String fallback}) {
  if (!exists) return 'File not found';
  if (resume != null && resume.position > Duration.zero) {
    if (resume.duration > Duration.zero) return '${formatShortDuration(resume.remaining)} left';
    return 'Resume from ${formatClock(resume.position)}';
  }
  final host = mediaHost(media);
  if (host != null) return host;
  if (media.duration > Duration.zero) return formatShortDuration(media.duration);
  return fallback;
}
