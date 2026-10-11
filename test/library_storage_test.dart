import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_data/danaview_data.dart';

String join(String a, String b, [String? c]) => [a, b, if (c != null) c].join(Platform.pathSeparator);

void main() {
  late Directory sandbox;
  late Directory container;
  late Directory docs;
  late Directory inbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('danaview_storage_');
    container = Directory(join(sandbox.path, 'container'))..createSync();
    docs = Directory(join(container.path, 'Documents'));
    inbox = Directory(join(container.path, 'tmp', 'com.danaview-Inbox'))..createSync(recursive: true);
  });

  tearDown(() => sandbox.delete(recursive: true));

  LibraryStorage mobile() => LibraryStorage(isMobile: true, documentsDirectory: () async => docs);

  File picked(String name, String content) => File(join(inbox.path, name))..writeAsStringSync(content);

  test('desktop returns picked paths untouched', () async {
    final file = picked('a.mkv', 'aaa');
    final result = await LibraryStorage(isMobile: false).importPickedFiles([file.path]);
    expect(result, [file.path]);
    expect(file.existsSync(), isTrue);
    expect(await LibraryStorage(isMobile: false).deviceDirectory(), isNull);
  });

  test('mobile moves temporary picks into Documents/Imported with unique names', () async {
    final first = picked('Movie.mkv', 'first');
    final [movedFirst] = await mobile().importPickedFiles([first.path]);
    expect(movedFirst, join(docs.path, LibraryStorage.importFolderName, 'Movie.mkv'));
    expect(first.existsSync(), isFalse);
    expect(File(movedFirst).readAsStringSync(), 'first');

    final second = picked('Movie.mkv', 'second!');
    final third = picked('Other.mp4', 'other');
    final result = await mobile().importPickedFiles([second.path, third.path]);
    expect(result, [
      join(docs.path, 'Imported', 'Movie (2).mkv'),
      join(docs.path, 'Imported', 'Other.mp4'),
    ]);
    expect(File(result.first).readAsStringSync(), 'second!');
  });

  test('re-picking an already imported file reuses it instead of duplicating', () async {
    final [imported] = await mobile().importPickedFiles([picked('Clip.mp4', 'same bytes').path]);
    final again = picked('Clip.mp4', 'same bytes');
    final [reused] = await mobile().importPickedFiles([again.path]);
    expect(reused, imported);
    expect(again.existsSync(), isFalse);
    expect(Directory(join(docs.path, 'Imported')).listSync(), hasLength(1));
  });

  test('never moves files outside the app container or already in Documents', () async {
    final outside = File(join(sandbox.path, 'user.mkv'))..writeAsStringSync('user');
    docs.createSync();
    final inDocs = File(join(docs.path, 'dropped.mkv'))..writeAsStringSync('dropped');
    final missing = join(inbox.path, 'gone.mkv');

    final result = await mobile().importPickedFiles([outside.path, inDocs.path, missing]);
    expect(result, [outside.path, inDocs.path, missing]);
    expect(outside.existsSync(), isTrue);
    expect(inDocs.existsSync(), isTrue);
  });

  test('device directory is Documents on mobile and is created when missing', () async {
    expect(docs.existsSync(), isFalse);
    final dir = await mobile().deviceDirectory();
    expect(dir!.path, docs.path);
    expect(docs.existsSync(), isTrue);
  });

  test('rebases stored paths from an old iOS container onto the current one', () {
    const oldId = '11111111-2222-3333-4444-555555555555';
    const newId = 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';
    final storage = LibraryStorage(
      isMobile: true,
      containerPath: '/private/var/mobile/Containers/Data/Application/$newId/tmp',
    );
    expect(
      storage.resolveStoredPath('/var/mobile/Containers/Data/Application/$oldId/Documents/Imported/a.mkv'),
      '/var/mobile/Containers/Data/Application/$newId/Documents/Imported/a.mkv',
    );
    expect(
      storage.resolveStoredPath('/private/var/mobile/Containers/Data/Application/$oldId/Documents/a.mkv'),
      '/private/var/mobile/Containers/Data/Application/$newId/Documents/a.mkv',
    );
    const current = '/private/var/mobile/Containers/Data/Application/$newId/Documents/b.mkv';
    expect(storage.resolveStoredPath(current), current);
    expect(storage.resolveStoredPath('/Volumes/Media/c.mkv'), '/Volumes/Media/c.mkv');

    final desktop = LibraryStorage(isMobile: false, containerPath: '/Users/me/Library/Caches');
    const iosPath = '/var/mobile/Containers/Data/Application/$oldId/Documents/a.mkv';
    expect(desktop.resolveStoredPath(iosPath), iosPath);
  });
}
