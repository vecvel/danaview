// OWNER: UX-24
//
// Helpers of the Filters panel tests: .cube sources, a media pool that applies imports to the
// session like the real service, a recording look-still service and preview, and a bundle that
// serves the committed looks.

import 'dart:io';
import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/services.dart';
import 'package:vwish_editor/src/editor/panels/filters_panel.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart' show EditSession;
import 'package:vwish_editor_core/store.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart';

import 'color_rig.dart';

/// A valid 2x2x2 identity `.cube`.
const String identityCube = '''
TITLE "Test look"
LUT_3D_SIZE 2
0 0 0
1 0 0
0 1 0
1 1 0
0 0 1
1 0 1
0 1 1
1 1 1
''';

/// A `.cube` whose fifth line has two numbers instead of three.
const String brokenCube = '''
TITLE "Broken"
LUT_3D_SIZE 2
0 0 0
1 0 0
0 1
1 1 0
0 0 1
1 0 1
0 1 1
1 1 1
''';

/// A `.cube` over the supported size.
const String oversizeCube = 'LUT_3D_SIZE 70\n0 0 0\n';

/// Writes [text] to `<dir>/<name>` and returns it as a pick.
PickedMedia writePick(Directory dir, String name, String text) {
  final file = File('${dir.path}/$name')..writeAsStringSync(text);
  return PickedMedia(uri: file.uri.toString(), displayName: name);
}

/// A pool service that "imports" every pick as the LUT asset [make] returns and applies it to the
/// session like `FileMediaPoolService` does (a sticky `AddAssets`).
class ApplyingPool implements MediaPoolService {
  /// Creates the pool; [reject] rejects every pick with that reason instead.
  ApplyingPool({this.reject, String name = 'Imported.cube'}) : _name = name;

  /// A rejection reason, or null to import.
  String? reject;

  final String _name;

  /// Picks received.
  final List<PickedMedia> imported = [];

  int _n = 0;

  @override
  Future<List<ImportOutcome>> import(EditSession session, List<PickedMedia> picked, {ImportTarget? target}) async {
    imported.addAll(picked);
    return [
      for (final p in picked)
        if (reject != null)
          ImportRejected(p, reject!)
        else
          () {
            final asset = lutAsset('md_imported${(++_n).toString().padLeft(4, '0')}', _name.isEmpty ? p.displayName : _name);
            session.applyPoolChange(AddAssets([asset]));
            return ImportedMedia(p, asset);
          }(),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

/// A look-still service that records requests and answers with [stills].
class RecordingStills implements LookStillService {
  /// Creates the service.
  RecordingStills({this.stills = const {}, this.fail = false});

  /// Answers by look id.
  Map<String, Uint8List> stills;

  /// Throws instead.
  bool fail;

  /// Every request: the clip, the look ids and the height.
  final List<(ItemId, List<String>, int)> requests = [];

  @override
  Future<Map<String, Uint8List>> render({
    required PreviewSession preview,
    required ItemId item,
    required List<LookStillRequest> looks,
    required int heightPx,
  }) async {
    requests.add((item, [for (final l in looks) l.id], heightPx));
    if (fail) throw StateError('no stills');
    return stills;
  }
}

/// A 1x1 PNG.
final Uint8List tinyPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, //
  0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, //
  0xCF, 0xC0, 0xF0, 0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, //
  0x42, 0x60, 0x82,
]);

/// Serves `packages/vwish_editor/assets/looks/<id>.vlut` from the committed files.
class LooksBundle extends CachingAssetBundle {
  /// Creates the bundle over the package's `assets/looks` directory.
  LooksBundle([Directory? dir]) : _dir = dir ?? Directory('assets/looks');

  final Directory _dir;

  @override
  Future<ByteData> load(String key) async {
    const prefix = 'packages/vwish_editor/assets/looks/';
    if (!key.startsWith(prefix)) throw FlutterError('Unable to load asset: $key');
    final file = File('${_dir.path}/${key.substring(prefix.length)}');
    if (!file.existsSync()) throw FlutterError('Unable to load asset: $key');
    final bytes = file.readAsBytesSync();
    return ByteData.sublistView(bytes);
  }
}
