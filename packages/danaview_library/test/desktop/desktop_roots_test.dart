// OWNER: HOM-03
//
// Desktop root discovery (V2-109): Pictures folders and external volumes on macOS, Windows and
// Linux, run on any host over an in-memory tree in each platform's path style.

// Direct imports keep this suite independent of the other directories behind the package barrel.
import 'package:danaview_library/src/desktop/desktop.dart';
import 'package:danaview_library/src/model/ids.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'desktop_test_fs.dart';

void main() {
  group('macOS', () {
    late MemoryDesktopFs fs;
    setUp(() {
      fs = MemoryDesktopFs(p.posix)
        ..dir('/Users/ana/Pictures/Photos Library.photoslibrary')
        ..dir('/Volumes/Card')
        ..dir('/Volumes/Backup Drive')
        ..dir('/Volumes/.timemachine')
        ..link('/Volumes/Macintosh HD', '/');
    });

    test('Pictures and external volumes; the boot volume and hidden mounts are not drives', () async {
      final roots = await DesktopRootResolver(platform: DesktopPlatform.macos, environment: {'HOME': '/Users/ana'}, fs: fs).discover();
      expect(roots.map((r) => (r.kind, r.path, r.label)), [
        (DesktopRootKind.pictures, '/Users/ana/Pictures', 'Pictures'),
        (DesktopRootKind.volume, '/Volumes/Backup Drive', 'Backup Drive'),
        (DesktopRootKind.volume, '/Volumes/Card', 'Card'),
      ]);
    });

    test('no HOME and no /Volumes: nothing, no error', () async {
      final roots = await DesktopRootResolver(platform: DesktopPlatform.macos, environment: const {}, fs: MemoryDesktopFs(p.posix)).discover();
      expect(roots, isEmpty);
    });

    test('a missing Pictures folder is not a root', () async {
      final roots = await DesktopRootResolver(platform: DesktopPlatform.macos, environment: {'HOME': '/Users/bo'}, fs: fs).pictures();
      expect(roots, isEmpty);
    });
  });

  group('Windows', () {
    late MemoryDesktopFs fs;
    setUp(() {
      fs = MemoryDesktopFs(p.windows)
        ..dir(r'C:\Users\Ana\Pictures')
        ..dir(r'C:\Users\Ana\OneDrive\Pictures')
        ..dir(r'D:\')
        ..dir(r'E:\DCIM');
    });

    const env = {
      'USERPROFILE': r'C:\Users\Ana',
      'OneDrive': r'C:\Users\Ana\OneDrive',
      'SystemDrive': 'C:',
    };

    test('Known Folder Pictures from the environment, OneDrive Pictures, drives except the system drive', () async {
      final roots = await DesktopRootResolver(platform: DesktopPlatform.windows, environment: env, fs: fs).discover();
      expect(roots.map((r) => (r.kind, r.path, r.label)), [
        (DesktopRootKind.pictures, r'C:\Users\Ana\Pictures', 'Pictures'),
        (DesktopRootKind.pictures, r'C:\Users\Ana\OneDrive\Pictures', 'Pictures'),
        (DesktopRootKind.volume, r'D:\', 'D:'),
        (DesktopRootKind.volume, r'E:\', 'E:'),
      ]);
    });

    test('HOMEDRIVE + HOMEPATH when USERPROFILE is unset', () async {
      final roots = await DesktopRootResolver(
        platform: DesktopPlatform.windows,
        environment: const {'HOMEDRIVE': 'C:', 'HOMEPATH': r'\Users\Ana'},
        fs: fs,
      ).pictures();
      expect(roots.single.path, r'C:\Users\Ana\Pictures');
    });

    test('a removed drive disappears on the next discovery', () async {
      final resolver = DesktopRootResolver(platform: DesktopPlatform.windows, environment: env, fs: fs);
      expect((await resolver.volumes()).map((r) => r.label), ['D:', 'E:']);
      fs.remove(r'E:\');
      expect((await resolver.volumes()).map((r) => r.label), ['D:']);
    });
  });

  group('Linux', () {
    late MemoryDesktopFs fs;
    setUp(() {
      fs = MemoryDesktopFs(p.posix)
        ..dir('/home/ana/Bilder')
        ..dir('/home/ana/Pictures')
        ..file('/home/ana/.config/user-dirs.dirs', '# written by xdg-user-dirs-update\nXDG_DESKTOP_DIR="\$HOME/Desktop"\nXDG_PICTURES_DIR="\$HOME/Bilder"\n')
        ..dir('/media/ana/SDCARD')
        ..dir('/media/usbstick')
        ..dir('/run/media/ana/Phone');
    });

    const env = {'HOME': '/home/ana', 'USER': 'ana'};

    test('XDG PICTURES from user-dirs.dirs and removable media under /media and /run/media', () async {
      final roots = await DesktopRootResolver(platform: DesktopPlatform.linux, environment: env, fs: fs).discover();
      expect(roots.map((r) => (r.kind, r.path, r.label)), [
        (DesktopRootKind.pictures, '/home/ana/Bilder', 'Bilder'),
        (DesktopRootKind.volume, '/media/usbstick', 'usbstick'),
        (DesktopRootKind.volume, '/media/ana/SDCARD', 'SDCARD'),
        (DesktopRootKind.volume, '/run/media/ana/Phone', 'Phone'),
      ]);
    });

    test('XDG_PICTURES_DIR in the environment wins; XDG_CONFIG_HOME is honoured', () async {
      fs.file('/cfg/user-dirs.dirs', 'XDG_PICTURES_DIR="/srv/photos"');
      fs.dir('/srv/photos');
      var r = DesktopRootResolver(platform: DesktopPlatform.linux, environment: {...env, 'XDG_PICTURES_DIR': '/home/ana/Pictures'}, fs: fs);
      expect(await r.xdgPicturesDir(), '/home/ana/Pictures');
      r = DesktopRootResolver(platform: DesktopPlatform.linux, environment: {...env, 'XDG_CONFIG_HOME': '/cfg'}, fs: fs);
      expect(await r.xdgPicturesDir(), '/srv/photos');
    });

    test('no user-dirs.dirs: ~/Pictures; PICTURES set to \$HOME means disabled', () async {
      fs.remove('/home/ana/.config');
      final r = DesktopRootResolver(platform: DesktopPlatform.linux, environment: env, fs: fs);
      expect(await r.xdgPicturesDir(), '/home/ana/Pictures');
      fs.file('/home/ana/.config/user-dirs.dirs', 'XDG_PICTURES_DIR="\$HOME/"');
      expect(await r.xdgPicturesDir(), isNull);
      expect(await r.pictures(), isEmpty);
    });

    test('parseUserDirs skips comments and malformed lines and undoes shell escapes', () {
      final map = DesktopRootResolver.parseUserDirs('# c\nXDG_A="a \\"q\\" \\\$x"\nbroken line\nXDG_B=unquoted\n  XDG_C = "c"  \n');
      expect(map, {'XDG_A': 'a "q" \$x', 'XDG_C': 'c'});
    });

    test('a relative or unexpandable value is ignored', () async {
      fs.file('/home/ana/.config/user-dirs.dirs', 'XDG_PICTURES_DIR="Bilder"');
      expect(await DesktopRootResolver(platform: DesktopPlatform.linux, environment: env, fs: fs).xdgPicturesDir(), isNull);
      expect(await DesktopRootResolver(platform: DesktopPlatform.linux, environment: const {'XDG_PICTURES_DIR': r'$HOME/x'}, fs: fs).xdgPicturesDir(), isNull);
    });
  });

  group('root ids', () {
    test('are stable, kind-prefixed and valid linked root ids', () {
      final a = rootIdFor(DesktopRootKind.pictures, '/Users/ana/Pictures');
      expect(a, rootIdFor(DesktopRootKind.pictures, '/Users/ana/Pictures'));
      expect(a, startsWith('pic-'));
      expect(rootIdFor(DesktopRootKind.volume, '/Volumes/Card'), startsWith('vol-'));
      expect(rootIdFor(DesktopRootKind.custom, '/x'), startsWith('usr-'));
      expect(a, isNot(rootIdFor(DesktopRootKind.pictures, '/Users/bo/Pictures')));
      expect(LinkedItemId.tryParse('lk:$a/IMG_0001.JPG'), isNotNull);
      expect(DesktopRoot.at(DesktopRootKind.volume, r'D:\', label: 'D:').id, rootIdFor(DesktopRootKind.volume, r'D:\'));
    });
  });
}
