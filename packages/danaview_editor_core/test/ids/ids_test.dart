// OWNER: CORE-02
//
// Typed ids (ARCH §6.1): prefixes, shape, determinism of the seeded generator, uniqueness of the
// secure generator.

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';

void main() {
  final shape = RegExp(r'^[a-z]{2}_[0-9A-Za-z]{12}$');

  group('prefixes', () {
    test('every kind has its ARCH §6.1 prefix', () {
      expect({for (final k in IdKind.values) k: k.prefix}, {
        IdKind.project: 'pr_',
        IdKind.track: 'tr_',
        IdKind.item: 'it_',
        IdKind.media: 'md_',
        IdKind.marker: 'mk_',
        IdKind.transition: 'tx_',
        IdKind.link: 'ln_',
        IdKind.save: 'sv_',
      });
    });

    test('typed helpers mint ids of the right kind', () {
      final g = SeededIdGenerator(7);
      expect(g.projectId(), startsWith('pr_'));
      expect(g.trackId(), startsWith('tr_'));
      expect(g.itemId(), startsWith('it_'));
      expect(g.mediaId(), startsWith('md_'));
      expect(g.markerId(), startsWith('mk_'));
      expect(g.transitionId(), startsWith('tx_'));
      expect(g.linkId(), startsWith('ln_'));
    });

    test('every id is the prefix plus 12 base62 characters', () {
      for (final g in <IdGenerator>[SeededIdGenerator(3), SecureIdGenerator()]) {
        for (final kind in IdKind.values) {
          for (var i = 0; i < 50; i++) {
            final id = g.next(kind);
            expect(id, matches(shape));
            expect(id, startsWith(kind.prefix));
            expect(id.length, 3 + 12);
          }
        }
      }
    });

    test('ids are strings: they compare and hash like the underlying value', () {
      const a = ItemId('it_aaaaaaaaaaaa');
      expect(a == 'it_aaaaaaaaaaaa', isTrue);
      expect({a: 1}['it_aaaaaaaaaaaa'], 1);
      expect({a, ItemId('it_${'a' * 12}')}, hasLength(1));
      expect(a.length, 15);
    });
  });

  group('SeededIdGenerator', () {
    test('the same seed yields the same sequence', () {
      final a = SeededIdGenerator(42);
      final b = SeededIdGenerator(42);
      final kinds = [IdKind.item, IdKind.track, IdKind.media, IdKind.item, IdKind.link, IdKind.marker];
      expect([for (final k in kinds) a.next(k)], [for (final k in kinds) b.next(k)]);
    });

    test('different seeds yield different sequences', () {
      expect(SeededIdGenerator(1).next(IdKind.item), isNot(SeededIdGenerator(2).next(IdKind.item)));
    });

    test('the default seed is stable (golden values keep tests deterministic)', () {
      final g = SeededIdGenerator();
      final first = g.next(IdKind.item);
      expect(SeededIdGenerator().next(IdKind.item), first);
      expect(first, matches(shape));
    });

    test('1,000 consecutive ids are unique', () {
      final g = SeededIdGenerator(9);
      expect({for (var i = 0; i < 1000; i++) g.next(IdKind.item)}, hasLength(1000));
    });
  });

  group('SecureIdGenerator', () {
    test('1,000,000 draws are unique', () {
      final g = SecureIdGenerator();
      final seen = <String>{};
      for (var i = 0; i < 1000000; i++) {
        seen.add(g.next(IdKind.item));
      }
      expect(seen, hasLength(1000000));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('uses the full base62 alphabet', () {
      final g = SecureIdGenerator();
      final chars = <String>{};
      for (var i = 0; i < 2000; i++) {
        chars.addAll(g.next(IdKind.item).substring(3).split(''));
      }
      expect(chars.length, 62);
    });
  });
}
