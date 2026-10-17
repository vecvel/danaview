// OWNER: CORE-02
//
// Typed ids (ARCH §6.1). Each id is a prefix plus 12 base62 characters from `Random.secure()`.

import 'dart:math';

/// Id of an [EditProject] (`pr_…`).
extension type const ProjectId(String value) implements String {}

/// Id of a track (`tr_…`).
extension type const TrackId(String value) implements String {}

/// Id of a timeline item: media clip, text item or subtitle cue (`it_…`).
extension type const ItemId(String value) implements String {}

/// Id of a media pool asset (`md_…`).
extension type const MediaId(String value) implements String {}

/// Id of a marker (`mk_…`).
extension type const MarkerId(String value) implements String {}

/// Id of a transition (`tx_…`).
extension type const TransitionId(String value) implements String {}

/// Id of a link group (`ln_…`): items that move, split, delete and duplicate together.
extension type const LinkId(String value) implements String {}

/// The kinds of id an [IdGenerator] mints, with their prefixes.
enum IdKind {
  /// `pr_`
  project('pr_'),

  /// `tr_`
  track('tr_'),

  /// `it_`
  item('it_'),

  /// `md_`
  media('md_'),

  /// `mk_`
  marker('mk_'),

  /// `tx_`
  transition('tx_'),

  /// `ln_`
  link('ln_'),

  /// `sv_` (save ids written into the `.dnproj` header, ARCH §8.2).
  save('sv_');

  const IdKind(this.prefix);

  /// The id prefix including the underscore.
  final String prefix;
}

/// Mints new ids. Commands receive one through `EditContext` so tests can be deterministic.
abstract interface class IdGenerator {
  /// A new raw id string of [kind] (prefix + 12 base62 characters).
  String next(IdKind kind);
}

/// Typed helpers over [IdGenerator.next].
extension IdGeneratorTyped on IdGenerator {
  /// A new [ProjectId].
  ProjectId projectId() => ProjectId(next(IdKind.project));

  /// A new [TrackId].
  TrackId trackId() => TrackId(next(IdKind.track));

  /// A new [ItemId].
  ItemId itemId() => ItemId(next(IdKind.item));

  /// A new [MediaId].
  MediaId mediaId() => MediaId(next(IdKind.media));

  /// A new [MarkerId].
  MarkerId markerId() => MarkerId(next(IdKind.marker));

  /// A new [TransitionId].
  TransitionId transitionId() => TransitionId(next(IdKind.transition));

  /// A new [LinkId].
  LinkId linkId() => LinkId(next(IdKind.link));
}

const String _base62 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

/// Production generator: 12 base62 characters from `Random.secure()` (~71 bits).
final class SecureIdGenerator implements IdGenerator {
  /// Creates a generator backed by `Random.secure()`.
  SecureIdGenerator() : _random = Random.secure();

  final Random _random;

  @override
  String next(IdKind kind) {
    final b = StringBuffer(kind.prefix);
    for (var i = 0; i < 12; i++) {
      b.writeCharCode(_base62.codeUnitAt(_random.nextInt(62)));
    }
    return b.toString();
  }
}

/// Deterministic generator for tests and fuzzing: the same seed yields the same id sequence.
final class SeededIdGenerator implements IdGenerator {
  /// Creates a generator seeded with [seed].
  SeededIdGenerator([int seed = 1]) : _random = Random(seed);

  final Random _random;

  @override
  String next(IdKind kind) {
    final b = StringBuffer(kind.prefix);
    for (var i = 0; i < 12; i++) {
      b.writeCharCode(_base62.codeUnitAt(_random.nextInt(62)));
    }
    return b.toString();
  }
}
