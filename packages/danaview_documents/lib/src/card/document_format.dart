// OWNER: HOM-23
//
// Labels, icons and number formats shared by the file card and the document viewers' bars (HOM
// plan §8.4: icon, name, size, dates). Pure formatting; nothing logs (rule 30).

import 'package:danaview_library/danaview_library.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';
import 'package:flutter/widgets.dart';
// Icons only (rule 31 bans Material chrome widgets, not the icon font).
import 'package:flutter/material.dart' show Icons;

import '../router/viewer_file.dart';

/// The type label of [file] ("PDF document", "Spreadsheet", …).
String documentTypeLabel(ViewerFile file) {
  switch (file.kind) {
    case FileKind.photo:
      return 'Photo';
    case FileKind.video:
      return 'Video';
    case FileKind.audio:
      return 'Audio';
    case FileKind.document:
    case FileKind.other:
      break;
  }
  final ext = file.extension;
  return switch (file.effectiveDocKind ?? DocumentKind.other) {
    DocumentKind.pdf => 'PDF document',
    DocumentKind.word => 'Document',
    DocumentKind.excel => 'Spreadsheet',
    DocumentKind.powerpoint => 'Presentation',
    DocumentKind.text => file.isDelimited ? 'Table (${(ext ?? 'csv').toUpperCase()})' : 'Text',
    DocumentKind.other => ext == null ? 'File' : '${ext.toUpperCase()} file',
  };
}

/// The icon of [file]'s type.
IconData documentIcon(ViewerFile file) => switch (file.kind) {
      FileKind.photo => Icons.image_outlined,
      FileKind.video => Icons.movie_outlined,
      FileKind.audio => Icons.audiotrack_outlined,
      FileKind.document || FileKind.other => switch (file.effectiveDocKind ?? DocumentKind.other) {
          DocumentKind.pdf => Icons.picture_as_pdf_outlined,
          DocumentKind.word => Icons.description_outlined,
          DocumentKind.excel => Icons.table_chart_outlined,
          DocumentKind.powerpoint => Icons.slideshow_outlined,
          DocumentKind.text => file.isDelimited ? Icons.grid_on_outlined : Icons.article_outlined,
          DocumentKind.other => Icons.insert_drive_file_outlined,
        },
    };

/// The accent of [file]'s type icon (always on a dark tile; contrast ≥ 3:1 for the glyph).
Color documentAccent(ViewerFile file) => switch (file.effectiveDocKind) {
      DocumentKind.pdf => DanaviewColors.errorLight,
      DocumentKind.word => DanaviewColors.primaryLight,
      DocumentKind.excel => DanaviewColors.success,
      DocumentKind.powerpoint => DanaviewColors.warning,
      _ => DanaviewColors.textSecondary,
    };

/// [bytes] as "512 bytes", "1.2 KB", "34 MB", "1.05 GB" (1000-based, as the system file apps).
String formatByteSize(int bytes) {
  if (bytes < 1000) return bytes == 1 ? '1 byte' : '$bytes bytes';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = bytes / 1000;
  var u = 0;
  while (v >= 1000 && u < units.length - 1) {
    v /= 1000;
    u++;
  }
  final digits = v >= 100 ? 0 : (v >= 10 ? 1 : 2);
  var s = v.toStringAsFixed(digits);
  if (s.contains('.')) s = s.replaceFirst(RegExp(r'\.?0+$'), '');
  return '$s ${units[u]}';
}

const List<String> _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// [time] in local time as "23 Oct 2026, 14:05".
String formatDocumentDate(DateTime time) {
  final t = time.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.day} ${_months[t.month - 1]} ${t.year}, ${two(t.hour)}:${two(t.minute)}';
}

/// A count with thousands separators ("12,345").
String formatCount(int n) {
  final s = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}
