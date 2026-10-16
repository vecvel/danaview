// OWNER: QA-10
//
// Support code of the QA-10 store suite (integration_test/editor_store): run configuration, the
// media layout of the session, host requests with typed results, the V-D1 fsync probe (dart:ffi
// over tool/fsync_probe.c) and small store helpers (bundle paths, byte corruption, newer-schema
// documents).
//
// The suite reuses the shared E2E suite's wiring and handshake (integration_test/editor/support,
// QA-00): `E2eApp` boots the real app with the production engine, `E2eHandshake` posts requests
// the host driver (tool/qa10_host.py, same file protocol as QA-00's e2e_host.sh) carries out.
//
// Media layout (ARCH §9.1 routes):
//
//   <Documents>/qa10/originals/frame_counter_1080p30.mp4   documentsReference (Files import)
//   <Documents>/qa10/originals/still_4k.jpg                documentsReference
//   <Documents>/qa10/relink/clap_flash_av.mp4              the relink target (documentsReference)
//   <host>/originals/tone_under_video.mp4                  iOS Files pick outside the container:
//                                                          security-scoped bookmark (V-D3)
//   <host>/scratch/clap_flash_av.mp4                       bookmark; deleted by the test so the
//                                                          relink flow has a missing file
//   <cache>/danaview/editor/work/picks/qa10-*/tone_1khz.wav  a Photos-style temporary copy: the
//                                                          managed-copy route (media/ is created
//                                                          and excluded from backup, V-D4)
//
// `<host>` is `--dart-define=DV_QA10_HOST_DIR` (iOS Simulator: a Mac folder the simulator reads in
// place; the host driver creates it). Without it the external (bookmark) media are left out and
// the checks that need them report "not run" with the reason.

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:danaview_editor_core/codec.dart' show ProjectHeader;
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../editor/support/e2e.dart';

/// Run configuration of the QA-10 suite.
abstract final class Qa10Config {
  /// Host folder with `originals/` and `scratch/` (see the file header); empty when not given.
  static const String hostDir = String.fromEnvironment('DV_QA10_HOST_DIR');

  /// Whether the external (bookmark) media are available.
  static bool get hasHostMedia =>
      hostDir.isNotEmpty && File(hostOriginal).existsSync() && Platform.isIOS;

  /// `<host>/originals/tone_under_video.mp4`: the bookmarked original (V-D3).
  static String get hostOriginal => '$hostDir/originals/${Fx.toneUnderVideo}';

  /// `<host>/scratch/clap_flash_av.mp4`: the bookmarked file the relink step removes.
  static String get hostScratch => '$hostDir/scratch/${Fx.clapFlash}';

  /// The state key of the suite (`E2eHandshake.saveState`).
  static const String stateKey = 'qa10';
}

/// The session's media under Documents (see the file header).
abstract final class Qa10Media {
  /// `<Documents>/qa10`.
  static String get dir => '${E2eApp.world.runtime.roots.documents}/qa10';

  /// The Documents original video.
  static String get video => '$dir/originals/${Fx.frameCounter}';

  /// The Documents original still.
  static String get still => '$dir/originals/${Fx.still4k}';

  /// The relink target (a byte copy of the scratch file).
  static String get relinkTarget => '$dir/relink/${Fx.clapFlash}';

  /// Copies the fixtures into Documents (the seed phase; the host snapshots them right after).
  static void stage() {
    for (final (name, target) in [(Fx.frameCounter, video), (Fx.still4k, still), (Fx.clapFlash, relinkTarget)]) {
      final source = File('${E2eConfig.fixturesDir}/$name');
      if (!source.existsSync()) {
        throw StateError('Fixture $name is not staged in ${E2eConfig.fixturesDir} (pass DV_E2E_FIXTURES)');
      }
      final out = File(target);
      if (out.existsSync()) continue;
      out.parent.createSync(recursive: true);
      source.copySync(out.path);
    }
  }

  /// A Photos-style temporary copy of fixture [name] under `work/picks/` (managed-copy route).
  static PickedMedia temporaryPick(String name) {
    final roots = E2eApp.world.runtime.roots;
    final dir = Directory('${roots.picksDir}/qa10-${DateTime.now().microsecondsSinceEpoch}')..createSync(recursive: true);
    final copy = File('${E2eConfig.fixturesDir}/$name').copySync('${dir.path}/$name');
    return PickedMedia(
      uri: Uri.file(copy.path).toString(),
      displayName: name,
      origin: MediaOrigin.photos,
      isTemporaryCopy: true,
      sizeBytes: copy.lengthSync(),
    );
  }

  /// A Files pick of [path] (no bookmark: the port makes one or relativizes it).
  static PickedMedia filesPick(String path) => E2ePicker.pickOf(path);
}

/// Requests to the QA-10 host driver (tool/qa10_host.py) and their result files.
abstract final class Qa10Host {
  /// Whether a host driver serves the handshake.
  static bool get available => E2eHandshake.available;

  /// Asks the host to read the iOS backup-exclusion attribute of [paths] (name → absolute path)
  /// and returns, per name, `{exists, excluded, xattr}` (V-D4).
  static Future<Map<String, Map<String, Object?>>> backupAttributes(WidgetTester tester, Map<String, String> paths) async {
    final ack = await E2eHandshake.request(tester, 'backupAttrs', args: {'paths': paths}, timeout: const Duration(seconds: 60));
    expect(ack.ok, isTrue, reason: 'host could not read the attributes: ${ack.detail}');
    final f = File('${E2eConfig.outDir}/qa10-backup-attrs.json');
    final body = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
    return {for (final e in body.entries) e.key: (e.value! as Map).cast<String, Object?>()};
  }

  /// Asks the host to compare the originals with the baseline it took after the seed phase
  /// (D-44). [allowedNew] are Documents-relative paths that may appear (the kept export copy).
  /// Returns the host's report.
  static Future<Map<String, Object?>> compareOriginals(WidgetTester tester, {List<String> allowedNew = const []}) async {
    final ack = await E2eHandshake.request(tester, 'compareOriginals', args: {'allowedNew': allowedNew}, timeout: const Duration(minutes: 3));
    final f = File('${E2eConfig.outDir}/qa10-originals-report.json');
    final body = f.existsSync() ? jsonDecode(f.readAsStringSync()) as Map<String, Object?> : <String, Object?>{'ok': false, 'error': 'no report'};
    body['ackOk'] = ack.ok;
    body['ackDetail'] = ack.detail;
    return body;
  }
}

/// The V-D1 fsync probe: counters of the interposed fsync(2) (tool/fsync_probe.c), when the host
/// injected it (`SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`); unavailable otherwise.
final class Qa10FsyncProbe {
  Qa10FsyncProbe._(this._count, this._full, this._paths);

  final int Function() _count;
  final int Function() _full;
  final int Function(ffi.Pointer<ffi.Uint8>, int) _paths;

  /// The probe, or null when the dylib is not loaded in this process.
  static Qa10FsyncProbe? load() {
    final lib = ffi.DynamicLibrary.process();
    if (!lib.providesSymbol('dv_qa10_fsync_count')) return null;
    return Qa10FsyncProbe._(
      lib.lookupFunction<ffi.Long Function(), int Function()>('dv_qa10_fsync_count'),
      lib.lookupFunction<ffi.Long Function(), int Function()>('dv_qa10_fullfsync_count'),
      lib.lookupFunction<ffi.Int Function(ffi.Pointer<ffi.Uint8>, ffi.Int), int Function(ffi.Pointer<ffi.Uint8>, int)>('dv_qa10_fsync_paths'),
    );
  }

  /// fsync(2) calls so far.
  int get fsyncCalls => _count();

  /// fcntl(F_FULLFSYNC) calls so far.
  int get fullFsyncCalls => _full();

  /// The newest records, `"fsync <path>"` / `"full <path>"`, oldest first.
  List<String> records() {
    const cap = 128 * 1100;
    final buf = _malloc(cap);
    try {
      _paths(buf, cap);
      final bytes = <int>[];
      for (var i = 0; i < cap; i++) {
        final b = buf[i];
        if (b == 0) break;
        bytes.add(b);
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      return text.isEmpty ? const [] : text.split('\n');
    } finally {
      _free(buf);
    }
  }

  static final ffi.DynamicLibrary _libc = ffi.DynamicLibrary.process();
  static final ffi.Pointer<ffi.Uint8> Function(int) _malloc =
      _libc.lookupFunction<ffi.Pointer<ffi.Uint8> Function(ffi.Size), ffi.Pointer<ffi.Uint8> Function(int)>('malloc');
  static final void Function(ffi.Pointer<ffi.Uint8>) _free =
      _libc.lookupFunction<ffi.Void Function(ffi.Pointer<ffi.Uint8>), void Function(ffi.Pointer<ffi.Uint8>)>('free');
}

/// Store helpers for the on-disk checks.
abstract final class Qa10Store {
  /// The repository of the running app.
  static FileProjectRepository get repo => E2eApp.world.runtime.repository;

  /// The roots of the running app.
  static StoreRoots get roots => E2eApp.world.runtime.roots;

  /// `project.dnproj` of [id].
  static File mainOf(ProjectId id) => File('${roots.projectDir(id.value)}/project.dnproj');

  /// `project.dnproj.bak` of [id].
  static File bakOf(ProjectId id) => File('${mainOf(id).path}.bak');

  /// Flips bytes in the body of the document at [f] (keeps its length: a torn sector / bit rot).
  static void corrupt(File f) {
    final bytes = f.readAsBytesSync();
    final headerEnd = bytes.indexOf(0x0A);
    final at = headerEnd + 1 + (bytes.length - headerEnd - 1) ~/ 2;
    for (var i = at; i < at + 8 && i < bytes.length - 1; i++) {
      bytes[i] = bytes[i] ^ 0x5A;
    }
    f.writeAsBytesSync(bytes, flush: true);
  }

  /// Rewrites the header of [id]'s main document with [schema] / [minReader] (the body and its
  /// checksum unchanged): a document "saved by a newer app" (D-12).
  static void markNewer(ProjectId id, {required int schema, required int minReader}) {
    final f = mainOf(id);
    final doc = DnprojFormat.parse(f.readAsBytesSync());
    final ProjectHeader header = doc.header.copyWith(schema: schema, minReader: minReader);
    f.writeAsBytesSync(DnprojFormat.encode(header, doc.body), flush: true);
    // The Projects list caches the header in meta.json; a stale one is rebuilt from the document.
    final meta = File('${roots.projectDir(id.value)}/meta.json');
    if (meta.existsSync()) meta.deleteSync();
  }

  /// What "opening never writes" compares: size, modification time and the bytes.
  static String fingerprint(File f) => '${f.lengthSync()}|${f.lastModifiedSync().microsecondsSinceEpoch}|${base64Encode(f.readAsBytesSync())}';

  /// The summary of [id] from the app's Projects list scan (the scan of this launch).
  static Future<ProjectSummary?> summaryOf(ProjectId id) async {
    final list = await repo.watchSummaries().first;
    for (final s in list) {
      if (s.id == id) return s;
    }
    return null;
  }
}

/// One line of evidence for the report (grep `DV_QA10`).
void qa10Report(String check, String result, [String detail = '']) {
  print('DV_QA10 $check: $result${detail.isEmpty ? '' : ' | $detail'}');
}
