// OWNER: HOM-17
//
// Reference holders (ARCH v1.2 §5.3 `refs`, V2-08): `project:<id>` and `photo:<id>` parse strictly.

import 'package:danaview_library/danaview_library.dart';
import 'package:test/test.dart';

void main() {
  test('holders parse and reject malformed strings', () {
    final p = RefHolder.project('abc-1');
    expect((p.value, p.kind, p.holderId), ('project:abc-1', RefHolderKind.project, 'abc-1'));
    expect(RefHolder.photo('x').kind, RefHolderKind.photo);
    for (final bad in ['', 'project', 'project:', 'clip:1', 'photo:a b', 'photo:${'x' * 129}']) {
      expect(RefHolder.tryParse(bad), isNull, reason: bad);
    }
    expect(() => RefHolder.parse('nope'), throwsFormatException);
    expect(RefUsage.none.isEmpty, isTrue);
  });
}
