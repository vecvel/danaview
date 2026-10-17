// OWNER: CORE-22
//
// Round-trip properties on random projects (BUILD_PLAN CORE-22): for 500 projects from the CORE-08
// generator (each also decorated so every body field takes non-default values),
// - decode(encode(p)) == p, with no warnings;
// - the bytes are deterministic: encoding twice, encoding with a cold or a warm fragment cache,
//   `jsonEncode(toJson(p))` and re-encoding the decoded project all give identical bytes.

import 'dart:convert';

import 'package:test/test.dart';
import 'package:danaview_editor_core/codec.dart';
import 'package:danaview_editor_core/model.dart';

import '../support/random_project.dart';
import 'support/codec_projects.dart';

const int _projects = 500;

/// Varies the generator spec by seed: small to medium projects, every rate, some without
/// transitions/ramps/keyframes/links/markers.
RandomProjectSpec _spec(int seed) => RandomProjectSpec(
      items: 10 + (seed * 37) % 140,
      frameRate: FrameRate(FrameRate.supportedProjectRates[seed % FrameRate.supportedProjectRates.length], 1),
      transitions: seed % 5 != 0,
      ramps: seed % 7 != 0,
      keyframes: seed % 3 != 0,
      links: seed % 4 != 0,
      markers: seed % 6 != 0,
    );

void _expectRoundTrip(EditProject p, ProjectJsonCodec warm, String label) {
  final cold = ProjectJsonCodec();
  final text = cold.encode(p);
  final decoded = cold.decode(text);
  expect(decoded.warnings, isEmpty, reason: '$label: a body this build wrote decodes without warnings');
  expect(decoded.project, p, reason: '$label: decode(encode(p)) == p');
  expect(decoded.project.hashCode, p.hashCode, reason: '$label: equal projects hash alike');

  // Deterministic bytes.
  expect(cold.encode(p), text, reason: '$label: encoding twice');
  expect(warm.encode(p), text, reason: '$label: encoding through a shared warm cache');
  expect(jsonEncode(cold.toJson(p)), text, reason: '$label: spliced fragments equal the plain tree');
  expect(ProjectJsonCodec().encode(decoded.project), text, reason: '$label: re-encoding the decoded project');
  expect(utf8.decode(cold.encodeBytes(p)), text, reason: '$label: bytes are the UTF-8 of the text');
  expect(text.contains('\n'), isFalse, reason: '$label: the body is a single line');
}

void main() {
  test('decode(encode(p)) == p and deterministic bytes on $_projects random projects (CORE-08 generator)', () {
    final warm = ProjectJsonCodec();
    var items = 0;
    var assets = 0;
    for (var seed = 0; seed < _projects; seed++) {
      final plain = randomProject(seed, _spec(seed));
      _expectRoundTrip(plain, warm, 'seed $seed');
      final decorated = decorate(plain, seed);
      _expectRoundTrip(decorated, warm, 'seed $seed (decorated)');
      items += decorated.index.itemCount;
      assets += decorated.pool.length;
    }
    // The corpus is not trivially small.
    expect(items, greaterThan(_projects * 30));
    expect(assets, greaterThan(_projects * 8));
  });

  test('the kitchen-sink and minimal projects round-trip', () {
    final warm = ProjectJsonCodec();
    _expectRoundTrip(kitchenSinkProject(), warm, 'kitchen sink');
    _expectRoundTrip(minimalProject(), warm, 'minimal');
  });

  test('a large project (2,000 items) round-trips', () {
    final p = decoratedRandomProject(11, const RandomProjectSpec(items: 2000));
    expect(p.index.itemCount, greaterThan(1500));
    _expectRoundTrip(p, ProjectJsonCodec(), 'large');
  });

  test('equal projects built in different orders of map insertion encode identically', () {
    final p = kitchenSinkProject();
    final main = p.tracks.first;
    final clip = main.items.first as MediaClip;
    final reversedChannels = KeyframeSet({
      for (final ch in clip.keyframes.byChannel.keys.toList().reversed) ch: clip.keyframes.byChannel[ch]!,
    });
    expect(reversedChannels, clip.keyframes);
    final q = p.copyWith(
      timeline: p.timeline.copyWith(tracks: [
        main.copyWith(items: [clip.copyWith(keyframes: reversedChannels), ...main.items.skip(1)]),
        ...p.tracks.skip(1),
      ]),
    );
    expect(q, p);
    expect(ProjectJsonCodec().encode(q), ProjectJsonCodec().encode(p));
  });
}
