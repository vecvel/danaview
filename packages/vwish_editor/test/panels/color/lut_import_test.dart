// OWNER: UX-24
//
// The .cube import path and the look stills without widgets: `LutImporter` over the real
// `FileMediaPoolService` on a temporary directory (CORE-21 parse in an isolate, CORE-27 project-owned
// `.cube` and `.vlut`), its error copy, and `EngineLookStillService` over a recording preview.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vwish_editor/src/app/strings/color_strings.dart';
import 'package:vwish_editor/src/editor/panels/filters_panel.dart';
import 'package:vwish_editor/src/editor/state/default_plan_compiler.dart' show BundledLookFiles;
import 'package:vwish_editor_core/formats.dart';
import 'package:vwish_editor_core/model.dart';
import 'package:vwish_editor_core/ops.dart';
import 'package:vwish_editor_core/store.dart';
import 'package:vwish_editor_engine_api/testing.dart';
import 'package:vwish_editor_engine_api/vwish_editor_engine_api.dart' show LookSpec, MediaPickKind, MediaPickSource, PreviewSession;

import 'color_rig.dart';
import 'filters_support.dart';

EditSession newSession() {
  final now = DateTime.utc(2026, 10, 1);
  final project = EditProject(
    id: const ProjectId('pr_color0000001'),
    meta: ProjectMeta(name: 'Colour', createdAt: now, updatedAt: now),
    timeline: Timeline(),
  );
  return EditSession(project, ids: SeededIdGenerator(24));
}

void main() {
  late Directory tmp;
  late StoreRoots roots;
  late FileMediaPoolService pool;
  late FakeMediaPicker picker;
  late LutImporter importer;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('vwish_lut_');
    roots = StoreRoots(support: '${tmp.path}/support', cache: '${tmp.path}/cache', documents: '${tmp.path}/docs');
    pool = FileMediaPoolService(
      access: DartIoMediaAccess(roots),
      probe: (_) async => throw StateError('a LUT is never probed'),
      roots: roots,
    );
    picker = FakeMediaPicker();
    importer = LutImporter(picker: picker, pool: pool);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('LutImporter over the real pool service', () {
    test('a valid .cube becomes a project-owned LUT asset with its .cube and .vlut beside it', () async {
      final session = newSession();
      final pick = writePick(tmp, 'Warm look.cube', identityCube);
      picker.nextPicks = [pick];
      final result = await importer.pickAndImport(session);
      expect(result, isA<LutImported>());
      final asset = (result as LutImported).asset;
      expect(asset.kind, MediaKind.lut);
      expect(asset.ownership, MediaOwnership.projectOwned);
      expect(asset.displayName, 'Warm look.cube');
      expect(session.committedProject.pool[asset.id], asset, reason: 'applied as a sticky pool change');
      final cube = roots.resolve(asset.locator as AppRelativeLocator);
      expect(cube, contains('projects/pr_color0000001/assets/luts/'));
      expect(File(cube).readAsStringSync(), identityCube);
      final vlut = readVlut(File(roots.resolve(ManagedStore.vlutOf(asset.locator as AppRelativeLocator))).readAsBytesSync());
      expect(vlut.size, 2);
      expect(lutName(asset), 'Warm look');
      expect(session.entries, isEmpty, reason: 'the import is not in undo history');
    });

    test('the picker asks the Files picker for one .cube', () async {
      picker.nextPicks = const [];
      await importer.pickAndImport(newSession());
      final request = picker.requests.single;
      expect(request.source, MediaPickSource.files);
      expect(request.kinds, {MediaPickKind.lut});
      expect(request.multiple, isFalse);
    });

    test('picking the same file again reuses the asset', () async {
      final session = newSession();
      final pick = writePick(tmp, 'Look.cube', identityCube);
      final first = await importer.importPick(session, pick) as LutImported;
      final second = await importer.importPick(session, pick) as LutImported;
      expect(second.asset.id, first.asset.id);
      expect(session.committedProject.pool.assets.values.where((a) => a.kind == MediaKind.lut), hasLength(1));
    });

    test('a dismissed picker is cancelled', () async {
      picker.nextPicks = const [];
      expect(await importer.pickAndImport(newSession()), isA<LutImportCancelled>());
    });

    test('a malformed file never reaches the pool and says which line', () async {
      final session = newSession();
      final result = await importer.importPick(session, writePick(tmp, 'Bad.cube', brokenCube));
      expect(result, isA<LutImportFailed>());
      expect((result as LutImportFailed).message, 'This LUT couldn\'t be read (line 5: expected 3 numbers).');
      expect(session.committedProject.pool.assets, isEmpty);
      expect(Directory('${roots.support}/vwish').existsSync(), isFalse, reason: 'nothing was written');
    });

    test('errors without a line and the size limit', () async {
      final noSize = await importer.importPick(newSession(), writePick(tmp, 'NoSize.cube', '0 0 0\n1 1 1\n')) as LutImportFailed;
      expect(noSize.message, startsWith('This LUT couldn\'t be read ('));
      final big = await importer.importPick(newSession(), writePick(tmp, 'Big.cube', oversizeCube)) as LutImportFailed;
      expect(big.message, 'LUTs up to 65×65×65 are supported.');
    });

    test('a file over 16 MB is refused before it is read into the parser', () async {
      final file = File('${tmp.path}/Huge.cube')..writeAsBytesSync(Uint8List(maxCubeBytes + 1));
      final result = await importer.importPick(newSession(), PickedMedia(uri: file.uri.toString(), displayName: 'Huge.cube'));
      expect((result as LutImportFailed).message, ColorStrings.lutTooLarge);
    });

    test('a missing file says it could not be opened', () async {
      final result = await importer.importPick(newSession(), PickedMedia(uri: Uri.file('${tmp.path}/gone.cube').toString(), displayName: 'gone.cube'));
      expect((result as LutImportFailed).message, ColorStrings.lutCannotOpen);
    });

    test('a 1D LUT is converted and the notice comes back', () async {
      final text = StringBuffer('LUT_1D_SIZE 4\n');
      for (var i = 0; i < 4; i++) {
        text.writeln('${i / 3} ${i / 3} ${i / 3}');
      }
      final result = await importer.importPick(newSession(), writePick(tmp, 'Curve.cube', text.toString()));
      expect((result as LutImported).notice, contains('33×33×33'));
    });

    test('a content:// pick the isolate cannot read is left to the pool service', () async {
      final fake = ApplyingPool();
      final result = await LutImporter(picker: picker, pool: fake).importPick(newSession(), const PickedMedia(uri: 'content://x/1', displayName: 'Remote.cube'));
      expect(result, isA<LutImported>());
      expect(fake.imported.single.uri, 'content://x/1');
    });

    test('rejection reasons of the service have copy', () {
      expect(LutImporter.reasonCopy('lutInvalid'), ColorStrings.lutUnreadable());
      expect(LutImporter.reasonCopy('notFound'), ColorStrings.lutCannotOpen);
      expect(LutImporter.reasonCopy('accessDenied'), ColorStrings.lutCannotOpen);
      expect(LutImporter.reasonCopy('notPersistable'), ColorStrings.lutCannotOpen);
      expect(LutImporter.reasonCopy('diskFull'), ColorStrings.lutDiskFull);
      expect(LutImporter.reasonCopy('cancelled'), ColorStrings.lutFailed);
      expect(LutImporter.reasonCopy(''), ColorStrings.lutFailed);
    });

    test('a pool that throws or returns nothing is a failure, not a crash', () async {
      final throwing = LutImporter(picker: picker, pool: _ThrowingPool());
      expect(await throwing.importPick(newSession(), writePick(tmp, 'A.cube', identityCube)), isA<LutImportFailed>());
      final empty = LutImporter(picker: picker, pool: _EmptyPool());
      expect(await empty.importPick(newSession(), writePick(tmp, 'B.cube', identityCube)), isA<LutImportFailed>());
    });

    test('messageOf: line, detail and the size limit', () {
      expect(LutImporter.messageOf(const LutFormatException('Line 14: expected 3 numbers', line: 14)), 'This LUT couldn\'t be read (line 14: expected 3 numbers).');
      expect(LutImporter.messageOf(const LutFormatException('Line 3: LUTs up to 65×65×65 are supported.', line: 3)), 'LUTs up to 65×65×65 are supported.');
      expect(LutImporter.messageOf(const LutFormatException('LUT_3D_SIZE is missing.')), 'This LUT couldn\'t be read (LUT_3D_SIZE is missing).');
    });
  });

  group('EngineLookStillService', () {
    late BundledLookFiles bundled;
    late EngineLookStillService service;
    late _RecordingPreview preview;

    setUp(() {
      bundled = BundledLookFiles(roots: roots, bundle: LooksBundle());
      service = EngineLookStillService(roots: roots, bundled: bundled);
      preview = _RecordingPreview();
    });

    test('resolves bundled looks to their extracted .vlut and files the answers by look id', () async {
      final stills = await service.render(
        preview: preview,
        item: ColorIds.a,
        looks: const [LookStillRequest.builtin('warm'), LookStillRequest.builtin('noir')],
        heightPx: 120,
      );
      expect(preview.item, ColorIds.a);
      expect(preview.heightPx, 120);
      expect(preview.looks.map((l) => l.id), ['warm', 'noir']);
      expect(preview.looks.first.lutSize, 33);
      expect(preview.looks.first.lutUri, startsWith('file://'));
      expect(preview.looks.first.lutUri, endsWith('/cache/vwish/editor/looks/warm.vlut'));
      expect(File.fromUri(Uri.parse(preview.looks.first.lutUri)).existsSync(), isTrue, reason: 'extracted on first use');
      expect(preview.looks.first.intensity, 1);
      expect(stills.keys, ['warm', 'noir']);
      expect(stills['warm'], Uint8List.fromList([1]));
    });

    test('an imported LUT uses the .vlut beside its .cube; unknown or unreadable looks are skipped; empty stills are absent', () async {
      final session = newSession();
      final result = await importer.importPick(session, writePick(tmp, 'Mine.cube', identityCube)) as LutImported;
      preview.empties = {'noir'};
      final stills = await service.render(
        preview: preview,
        item: ColorIds.a,
        looks: [
          LookStillRequest.imported(result.asset),
          const LookStillRequest.builtin('does_not_exist'),
          LookStillRequest.imported(lutAsset('md_gone', 'Gone.cube')),
          const LookStillRequest.builtin('noir'),
        ],
        heightPx: 90,
      );
      expect(preview.looks.map((l) => l.id), [result.asset.id, 'noir']);
      expect(preview.looks.first.lutSize, 2);
      expect(preview.looks.first.lutUri, endsWith('${result.asset.id}.vlut'));
      expect(stills.keys, [result.asset.id], reason: 'the engine returned nothing for noir');
    });

    test('nothing to render means no engine call', () async {
      final stills = await service.render(preview: preview, item: ColorIds.a, looks: const [LookStillRequest.builtin('does_not_exist')], heightPx: 90);
      expect(stills, isEmpty);
      expect(preview.calls, 0);
    });
  });
}

class _ThrowingPool implements MediaPoolService {
  @override
  Future<List<ImportOutcome>> import(EditSession session, List<PickedMedia> picked, {ImportTarget? target}) => throw StateError('disk on fire');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _EmptyPool implements MediaPoolService {
  @override
  Future<List<ImportOutcome>> import(EditSession session, List<PickedMedia> picked, {ImportTarget? target}) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _RecordingPreview implements PreviewSession {
  int calls = 0;
  ItemId? item;
  List<LookSpec> looks = const [];
  int? heightPx;
  Set<String> empties = {};

  @override
  Future<List<Uint8List>> renderLookStills(ItemId item, List<LookSpec> looks, {required int heightPx}) async {
    calls++;
    this.item = item;
    this.looks = looks;
    this.heightPx = heightPx;
    return [for (final l in looks) empties.contains(l.id) ? Uint8List(0) : Uint8List.fromList([1])];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
