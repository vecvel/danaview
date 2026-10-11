import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Fast content-based media identification.
/// Implements §7.1: sha1(first 64 KB + last 64 KB + size)
class MediaIdentityService {
  static const int _chunkSize = 64 * 1024; // 64 KB

  static Future<String> computeQuickHash(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      return '';
    }

    final size = await file.length();
    if (size == 0) return '';

    final raf = await file.open(mode: FileMode.read);
    try {
      // First 64 KB
      final firstChunkSize = size < _chunkSize ? size : _chunkSize;
      final firstBytes = await raf.read(firstChunkSize);

      // Last 64 KB
      Uint8List lastBytes = Uint8List(0);
      if (size > _chunkSize) {
        final lastOffset = (size - _chunkSize).clamp(0, size);
        await raf.setPosition(lastOffset);
        final lastChunkSize = (size - lastOffset).clamp(0, _chunkSize);
        lastBytes = await raf.read(lastChunkSize);
      }

      final buffer = BytesBuilder();
      buffer.add(firstBytes);
      buffer.add(lastBytes);
      buffer.add(utf8.encode(':$size'));

      final digest = sha1.convert(buffer.toBytes());
      return digest.toString();
    } finally {
      await raf.close();
    }
  }
}
