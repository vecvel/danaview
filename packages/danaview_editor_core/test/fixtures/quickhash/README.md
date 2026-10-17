<!-- OWNER: CORE-04 -->
# quickHash fixtures

`quickhash_vectors.json` holds the expected `quickHash` of seven synthetic files (1 byte, 64 KiB,
64 KiB + 1, 100 KiB, 128 KiB, 3 MiB and an empty file, whose hash is `''`). The files are not
committed: their content is the deterministic pattern `byte[i] = (i * 31 + (i >> 8) * 7 + 5) & 0xff`,
which `test/model/pool/quick_hash_test.dart` regenerates and hashes with `computeQuickHash`.

The hashes were produced **once** with the reference implementation, `MediaIdentityService.computeQuickHash`
in `packages/danaview_data/lib/src/scanner/media_identity.dart` (sha1 of the first 64 KiB, plus the last
64 KiB only when the file is larger than 64 KiB, plus `utf8(':$size')`; empty file -> `''`). To
regenerate (only if the reference algorithm ever changes on purpose), run from the repo root, with the
script below saved anywhere outside the repo:

```sh
dart --packages=packages/danaview_data/.dart_tool/package_config.json /path/to/gen_quickhash.dart \
  packages/danaview_editor_core/test/fixtures/quickhash/quickhash_vectors.json
```

```dart
// One-shot generator: writes the 6 synthetic files and records danaview_data's computeQuickHash.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:danaview_data/src/scanner/media_identity.dart';

int byteAt(int i) => (i * 31 + (i >> 8) * 7 + 5) & 0xff;

Future<void> main(List<String> args) async {
  final outPath = args[0];
  final dir = Directory.systemTemp.createTempSync('qh_');
  final cases = <(String, int)>[
    ('one_byte', 1),
    ('exactly_64k', 64 * 1024),
    ('64k_plus_1', 64 * 1024 + 1),
    ('100k', 100 * 1024),
    ('exactly_128k', 128 * 1024),
    ('3mib', 3 * 1024 * 1024),
  ];
  final out = <Map<String, Object?>>[];
  for (final (name, size) in cases) {
    final f = File('${dir.path}/$name.bin')
      ..writeAsBytesSync(Uint8List.fromList([for (var i = 0; i < size; i++) byteAt(i)]));
    out.add({'name': name, 'size': size, 'quickHash': await MediaIdentityService.computeQuickHash(f.path)});
  }
  final empty = File('${dir.path}/empty.bin')..writeAsBytesSync(Uint8List(0));
  out.add({'name': 'empty', 'size': 0, 'quickHash': await MediaIdentityService.computeQuickHash(empty.path)});
  final doc = {
    'schema': 1,
    'producedWith': 'packages/danaview_data/lib/src/scanner/media_identity.dart MediaIdentityService.computeQuickHash',
    'pattern': 'byte[i] = (i * 31 + (i >> 8) * 7 + 5) & 0xff',
    'cases': out,
  };
  File(outPath).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(doc)}\n');
  dir.deleteSync(recursive: true);
  stdout.writeln('wrote $outPath');
}
```
