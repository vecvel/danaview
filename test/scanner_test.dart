import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_data/danaview_data.dart';

void main() {
  group('op_data Natural Sort & Episode Parser Tests', () {
    test('Natural sort sorts numbers numerically rather than lexically', () {
      final list = ['Episode 10', 'Episode 2', 'Episode 1', 'Episode 20', 'Episode 3'];
      list.sort(NaturalSortComparator.compare);

      expect(list, ['Episode 1', 'Episode 2', 'Episode 3', 'Episode 10', 'Episode 20']);
    });

    test('Natural sort handles file extensions and complex chunks', () {
      final list = ['10.mkv', '1.mkv', '2.mkv', '100.mkv', '20.mkv'];
      list.sort(NaturalSortComparator.compare);

      expect(list, ['1.mkv', '2.mkv', '10.mkv', '20.mkv', '100.mkv']);
    });

    test('EpisodeParser correctly extracts season and episode numbers', () {
      final ep1 = EpisodeParser.parse('Show.Name.S02E08.1080p.mkv');
      expect(ep1.hasMatch, isTrue);
      expect(ep1.season, 2);
      expect(ep1.episode, 8);

      final ep2 = EpisodeParser.parse('Anime_Show_-_07_[1080p].mkv');
      expect(ep2.hasMatch, isTrue);
      expect(ep2.episode, 7);

      final ep3 = EpisodeParser.parse('Series 1x04 Episode Title.mp4');
      expect(ep3.hasMatch, isTrue);
      expect(ep3.season, 1);
      expect(ep3.episode, 4);
    });
  });
}
