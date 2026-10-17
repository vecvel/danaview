// OWNER: UX-32
//
// The pure parts of SRT/VTT import and export (ux.md §10.9, ARCH §10.1, §9.6): file names, format
// hints and languages; the importer over the corpus fixtures (valid SRT/VTT, malformed with line
// numbers, UTF-16 with and without BOM, Windows-1252 fallback, VTT without header), oversize and
// unreadable picks, app-owned temporary picks removed through OwnedFileDeleter, the isolate
// parser; and the exporter: SRT/VTT bytes, the `<project>.<bcp47>.srt|vtt` name, the temporary file
// under `work/` handed over then deleted (also when the handoff fails), stale folders swept.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/app/strings/subtitle_io_strings.dart';
import 'package:danaview_editor/src/editor/panels/subtitle_io.dart';
import 'package:danaview_editor_core/formats.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show SubtitleImportMode;
import 'package:danaview_editor_core/testing.dart' show MemoryStoreFs;
import 'package:danaview_editor_engine_api/danaview_editor_engine_api.dart';
import 'package:danaview_editor_engine_api/testing.dart' show FakeMediaPicker;

import 'subtitle_io_rig.dart';

PickedMedia _put(MemoryStoreFs fs, String name, Uint8List bytes, {String dir = '/mem/user', bool temporary = false}) {
  final path = '$dir/$name';
  fs.putFile(path, bytes);
  return PickedMedia(uri: Uri.file(path).toString(), displayName: name, isTemporaryCopy: temporary, sizeBytes: bytes.length);
}

Future<SubtitleImportPreview> _load(SubtitleIoEnvironment env, PickedMedia picked) async {
  final r = await SubtitleImporter(env).load(picked);
  expect(r, isA<SubtitleLoaded>(), reason: '$r');
  return (r as SubtitleLoaded).preview;
}

void main() {
  group('names', () {
    test('format hints come from the extension', () {
      expect(SubtitleIo.formatOf('movie.srt'), SubtitleFormat.srt);
      expect(SubtitleIo.formatOf('Movie.VTT'), SubtitleFormat.vtt);
      expect(SubtitleIo.formatOf('file:///a/b/c.vtt'), SubtitleFormat.vtt);
      expect(SubtitleIo.formatOf('notes.txt'), isNull);
      expect(SubtitleIo.formatOf('noext'), isNull);
    });

    test('track name and language from the file name', () {
      expect(SubtitleIo.trackNameOf('movie.en.srt'), ('movie', 'en'));
      expect(SubtitleIo.trackNameOf('Film.pt-BR.vtt'), ('Film', 'pt-BR'));
      expect(SubtitleIo.trackNameOf('Talk.srt'), ('Talk', null));
      expect(SubtitleIo.trackNameOf('The.Movie.2019.srt'), ('The.Movie.2019', null));
      expect(SubtitleIo.trackNameOf('my.final.srt'), ('my.final', null), reason: '"final" is not a language tag');
      expect(SubtitleIo.trackNameOf('.srt').$1, '');
      final long = SubtitleIo.trackNameOf('${'x' * 80}.srt').$1;
      expect(long.length, SubtitleIo.maxTrackName);
    });

    test('export names: <project>.<bcp47>.srt|vtt, und without a language, generator language as fallback', () {
      final project = ioProject(const ProjectId('pr_n'));
      Track t(TrackId id) => project.tracks.firstWhere((x) => x.id == id);
      expect(SubtitleIo.exportFileName(project, t(Io.english), SubtitleFormat.srt), 'My Film.en.srt');
      expect(SubtitleIo.exportFileName(project, t(Io.auto), SubtitleFormat.vtt), 'My Film.fr.vtt');
      expect(SubtitleIo.exportFileName(project, t(Io.locked), SubtitleFormat.srt), 'My Film.und.srt');
      expect(SubtitleIo.languageOf(Track(id: const TrackId('x'), kind: TrackKind.subtitle, subtitle: const SubtitleTrackData(language: ' '))), 'und');
    });

    test('exportable tracks are the subtitle tracks with captions, topmost first; generated ones are marked', () {
      final project = ioProject(const ProjectId('pr_e'));
      expect([for (final t in SubtitleIo.exportableTracks(project)) t.id], [Io.auto, Io.english, Io.locked]);
      expect(SubtitleIo.isGenerated(project.tracks.firstWhere((x) => x.id == Io.auto)), isTrue);
      expect(SubtitleIo.isGenerated(project.tracks.firstWhere((x) => x.id == Io.english)), isFalse);
      expect(SubtitleIo.exportableTracks(ioProject(const ProjectId('pr_f'), subtitles: false)), isEmpty);
    });

    test('the replace target: the preferred unlocked track, else the topmost unlocked one', () {
      final project = ioProject(const ProjectId('pr_r'));
      expect(SubtitleIo.replaceTargetIn(project, Io.english), Io.english);
      expect(SubtitleIo.replaceTargetIn(project, Io.locked), Io.auto, reason: 'locked tracks are never replaced');
      expect(SubtitleIo.replaceTargetIn(project, null), Io.auto);
      expect(SubtitleIo.replaceTargetIn(ioProject(const ProjectId('pr_s'), subtitles: false), null), isNull);
    });

    test('commands: a new named track with the language, or a replace of the chosen track', () {
      final preview = SubtitleImportPreview(fileName: 'movie.en.srt', result: SubtitleCodec.parse(fixture('basic.srt')));
      final add = SubtitleIo.commandFor(preview, const SubtitleImportChoice(SubtitleImportMode.newTrack));
      expect(add.mode, SubtitleImportMode.newTrack);
      expect(add.name, 'movie');
      expect(add.language, 'en');
      expect(add.cues, [
        SubtitleCueDraft(TimeRange(1 * s, 2500000), 'Hello, world'),
        SubtitleCueDraft(TimeRange(3 * s, 4250000), 'Second line\nwraps here'),
      ]);
      final replace = SubtitleIo.commandFor(preview, const SubtitleImportChoice(SubtitleImportMode.replace, track: Io.english));
      expect(replace.mode, SubtitleImportMode.replace);
      expect(replace.track, Io.english);
    });
  });

  group('importer', () {
    late MemoryStoreFs fs;
    late SubtitleIoEnvironment env;
    setUp(() {
      fs = MemoryStoreFs();
      env = memEnvironment(fs);
    });

    test('valid SRT and VTT', () async {
      final srt = await _load(env, _put(fs, 'basic.srt', fixture('basic.srt')));
      expect(srt.drafts, hasLength(2));
      expect(srt.result.format, SubtitleFormat.srt);
      expect(srt.result.issues, isEmpty);
      expect(srt.result.detectedEncoding, TextEncoding.utf8);
      expect(srt.canImport, isTrue);
      final vtt = await _load(env, _put(fs, 'basic.vtt', fixture('basic.vtt')));
      expect(vtt.result.format, SubtitleFormat.vtt);
      expect(vtt.drafts, isNotEmpty);
    });

    test('malformed: the good cues import, the rest are issues with line numbers', () async {
      final preview = await _load(env, _put(fs, 'malformed.srt', fixture('malformed.srt')));
      expect([for (final d in preview.drafts) d.text], ['Good one', 'Good two']);
      final lines = [for (final i in preview.result.issues) SubtitleIoStrings.issue(i.line, i.kind)];
      expect(lines, contains("Line 6: the timing isn't valid"));
      expect(lines, contains('Line 10: the caption ends before it starts'));
    });

    test('UTF-16 with a BOM and without one; Windows-1252 is a reported fallback', () async {
      final le = await _load(env, _put(fs, 'le.srt', fixture('utf16le_bom.srt')));
      expect(le.result.detectedEncoding, TextEncoding.utf16le);
      expect(le.drafts.first.text, 'Héllo, world');
      final be = await _load(env, _put(fs, 'be.srt', fixture('utf16be_nobom.srt')));
      expect(be.result.detectedEncoding, TextEncoding.utf16be);
      expect(be.drafts.first.text, 'Héllo, world');
      expect(SubtitleIoStrings.isFallback(be.result.detectedEncoding), isFalse);
      final cp = await _load(env, _put(fs, 'cp.srt', fixture('cp1252.srt')));
      expect(cp.result.detectedEncoding, TextEncoding.windows1252);
      expect(SubtitleIoStrings.isFallback(cp.result.detectedEncoding), isTrue);
      expect(SubtitleIoStrings.encodingNote(cp.result.detectedEncoding), contains('Windows-1252'));
    });

    test('a .vtt without WEBVTT has nothing to import and says why', () async {
      final preview = await _load(env, _put(fs, 'no_header.vtt', fixture('vtt_no_header.vtt')));
      expect(preview.canImport, isFalse);
      expect(preview.result.issues.first.kind, SubtitleIssueKind.missingHeader);
    });

    test('unreadable, missing, oversize and failing picks give a message', () async {
      final importer = SubtitleImporter(env);
      final content = await importer.load(const PickedMedia(uri: 'content://docs/1', displayName: 'a.srt'));
      expect((content as SubtitleLoadFailed).message, SubtitleIoStrings.cannotOpen);
      final missing = await importer.load(PickedMedia(uri: Uri.file('/mem/user/none.srt').toString(), displayName: 'none.srt'));
      expect((missing as SubtitleLoadFailed).message, SubtitleIoStrings.cannotOpen);
      final declared = await importer.load(const PickedMedia(uri: 'file:///mem/user/x.srt', displayName: 'x.srt', sizeBytes: SubtitleIo.maxBytes + 1));
      expect((declared as SubtitleLoadFailed).message, SubtitleIoStrings.tooLarge(20));
      final big = _put(fs, 'big.srt', Uint8List(SubtitleIo.maxBytes + 1));
      final measured = await importer.load(PickedMedia(uri: big.uri, displayName: big.displayName));
      expect((measured as SubtitleLoadFailed).message, SubtitleIoStrings.tooLarge(20));
      final throwing = memEnvironment(fs, parse: (_, __) async => throw StateError('boom'));
      final failed = await SubtitleImporter(throwing).load(_put(fs, 'ok.srt', fixture('basic.srt')));
      expect((failed as SubtitleLoadFailed).message, SubtitleIoStrings.readFailed);
    });

    test('pickAndLoad asks for one subtitle file; an empty pick is a cancel; picker errors are reported', () async {
      final picker = FakeMediaPicker();
      final e = memEnvironment(fs, picker: picker);
      expect(await SubtitleImporter(e).pickAndLoad(), isA<SubtitleLoadCancelled>());
      final request = picker.requests.single;
      expect(request.source, MediaPickSource.files);
      expect(request.kinds, {MediaPickKind.subtitle});
      expect(request.multiple, isFalse);
      final broken = memEnvironment(fs, picker: _ThrowingPicker());
      expect(await SubtitleImporter(broken).pickAndLoad(), isA<SubtitleLoadFailed>());
    });

    test('an app-owned temporary pick is deleted through the guard after reading; a user file never is', () async {
      final temp = _put(fs, 'movie.srt', fixture('basic.srt'), dir: '${memRoots.workDir}/picks/u1', temporary: true);
      await _load(env, temp);
      expect(fs.filePaths, isNot(contains('${memRoots.workDir}/picks/u1/movie.srt')));
      final user = _put(fs, 'mine.srt', fixture('basic.srt'));
      await _load(env, user);
      expect(fs.filePaths, contains('/mem/user/mine.srt'));
    });

    test('the default parser runs SubtitleCodec.parse in an isolate', () async {
      final r = await isolateSubtitleParse(fixture('utf16le_bom.srt'), SubtitleFormat.srt);
      expect(r.detectedEncoding, TextEncoding.utf16le);
      expect(r.cues, hasLength(2));
      final vtt = await isolateSubtitleParse(fixture('vtt_full.vtt'), null);
      expect(vtt.format, SubtitleFormat.vtt);
      expect(vtt.strippedTags, greaterThan(0));
      expect(vtt.ignoredSettings, greaterThan(0));
    });
  });

  group('exporter', () {
    late MemoryStoreFs fs;
    late RecordingHandoff handoff;
    late SubtitleIoEnvironment env;
    final project = ioProject(const ProjectId('pr_x'));
    Track t(TrackId id) => project.tracks.firstWhere((x) => x.id == id);

    setUp(() {
      fs = MemoryStoreFs();
      handoff = RecordingHandoff(fs);
      env = memEnvironment(fs, files: handoff);
    });

    test('Save to Files: SRT bytes, the suggested name, a file under work/, deleted afterwards', () async {
      final out = await SubtitleExporter(env).export(project, t(Io.english), SubtitleFormat.srt, SubtitleHandoff.files);
      expect(out.status, SubtitleExportStatus.done);
      expect(out.fileName, 'My Film.en.srt');
      final call = handoff.calls.single;
      expect(call.kind, 'files');
      expect(call.name, 'My Film.en.srt');
      expect(call.path, '${memRoots.workDir}/subtitles-t0/My Film.en.srt');
      expect(String.fromCharCodes(call.bytes), '1\r\n00:00:00,000 --> 00:00:02,000\r\nBee one\r\n\r\n2\r\n00:00:03,000 --> 00:00:05,000\r\nBee two\r\n\r\n');
      final back = SubtitleCodec.parse(call.bytes);
      expect(back.cues, [SubtitleCueData(0, 2 * s, 'Bee one'), SubtitleCueData(3 * s, 5 * s, 'Bee two')]);
      expect(fs.filePaths.where((f) => f.startsWith(memRoots.workDir)), isEmpty);
      expect(fs.directoryPaths.where((d) => d.contains('subtitles-')), isEmpty);
    });

    test('Share: VTT of generated captions', () async {
      final out = await SubtitleExporter(env).export(project, t(Io.auto), SubtitleFormat.vtt, SubtitleHandoff.share);
      expect(out.status, SubtitleExportStatus.done);
      final call = handoff.calls.single;
      expect(call.kind, 'share');
      expect(call.path, endsWith('/My Film.fr.vtt'));
      final text = String.fromCharCodes(call.bytes);
      expect(text, startsWith('WEBVTT'));
      expect(SubtitleCodec.parse(call.bytes).cues, [SubtitleCueData(1 * s, 3 * s, 'Bonjour'), SubtitleCueData(4 * s, 6 * s, 'Salut')]);
      expect(fs.filePaths.where((f) => f.startsWith(memRoots.workDir)), isEmpty);
    });

    test('cancelled, denied and failed handoffs still delete the file', () async {
      for (final (outcome, status) in [
        (FileHandoffOutcome.cancelled, SubtitleExportStatus.cancelled),
        (FileHandoffOutcome.denied, SubtitleExportStatus.denied),
        (FileHandoffOutcome.failed, SubtitleExportStatus.failed),
      ]) {
        handoff.next = outcome;
        final out = await SubtitleExporter(env).export(project, t(Io.english), SubtitleFormat.srt, SubtitleHandoff.files);
        expect(out.status, status);
        expect(fs.filePaths.where((f) => f.startsWith(memRoots.workDir)), isEmpty);
      }
      final throwing = memEnvironment(fs, files: _ThrowingHandoff());
      final out = await SubtitleExporter(throwing).export(project, t(Io.english), SubtitleFormat.srt, SubtitleHandoff.share);
      expect(out.status, SubtitleExportStatus.failed);
      expect(fs.filePaths.where((f) => f.startsWith(memRoots.workDir)), isEmpty);
    });

    test('folders an earlier export left behind are swept; other work files are kept', () async {
      fs.putFile('${memRoots.workDir}/subtitles-old/x.srt', [1, 2, 3]);
      fs.putFile('${memRoots.workDir}/export-1.mp4', [1]);
      await SubtitleExporter(env).export(project, t(Io.english), SubtitleFormat.srt, SubtitleHandoff.files);
      expect(fs.filePaths, isNot(contains('${memRoots.workDir}/subtitles-old/x.srt')));
      expect(fs.filePaths, contains('${memRoots.workDir}/export-1.mp4'));
    });
  });
}

final class _ThrowingPicker implements MediaPicker {
  @override
  Future<List<PickedMedia>> pick(MediaPickRequest request) async => throw StateError('no picker');
}

final class _ThrowingHandoff implements FileHandoff {
  @override
  Future<FileHandoffResult> saveToFiles(String path, String suggestedName) async => throw StateError('x');

  @override
  Future<FileHandoffResult> saveToPhotos(String path) async => throw StateError('x');

  @override
  Future<FileHandoffResult> share(String path) async => throw StateError('x');
}
