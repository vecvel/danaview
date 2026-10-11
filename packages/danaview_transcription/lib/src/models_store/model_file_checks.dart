// OWNER: AI-09
//
// Integrity checks of a model file (ai.md §5.3 step 5): streaming SHA-256 in a background isolate
// and the ggml magic check (V-A5).

library;

import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

/// First four bytes of every whisper / VAD ggml file: `GGML_FILE_MAGIC` 0x67676d6c ("ggml") written
/// as a little-endian uint32 by the converters, so the bytes on disk read `6c 6d 67 67` ("lmgg").
/// whisper.cpp v1.9.4 compares exactly this value for both the speech and the VAD loader (V-A5).
const List<int> ggmlMagicBytes = [0x6c, 0x6d, 0x67, 0x67];

/// Whether the file at [path] starts with the ggml magic.
Future<bool> hasGgmlMagic(String path) async {
  RandomAccessFile? raf;
  try {
    raf = await File(path).open();
    final head = await raf.read(4);
    if (head.length != 4) return false;
    for (var i = 0; i < 4; i++) {
      if (head[i] != ggmlMagicBytes[i]) return false;
    }
    return true;
  } on FileSystemException {
    return false;
  } finally {
    await raf?.close();
  }
}

/// Lowercase hex SHA-256 of the file at [path], streamed in 1 MiB blocks inside [Isolate.run] so
/// the UI thread never hashes a 181 MiB file. Throws [FileSystemException] when unreadable.
Future<String> sha256OfFile(String path) => Isolate.run(() => sha256OfFileSync(path));

/// Synchronous worker of [sha256OfFile] (also used by tests).
String sha256OfFileSync(String path) {
  final raf = File(path).openSync();
  try {
    final output = _DigestSink();
    final sink = sha256.startChunkedConversion(output);
    while (true) {
      final block = raf.readSync(1024 * 1024);
      if (block.isEmpty) break;
      sink.add(block);
    }
    sink.close();
    return output.value.toString();
  } finally {
    raf.closeSync();
  }
}

final class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
