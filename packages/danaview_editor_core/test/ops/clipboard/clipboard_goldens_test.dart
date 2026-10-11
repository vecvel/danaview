// OWNER: CORE-11
//
// Before/after golden tests for the clipboard and media commands (BUILD_PLAN CORE-11): duplicate,
// paste (same project, cross project, other frame rate), replace, extract audio, link/unlink and
// cut. Every applied result validates fully and the dry run agrees with the apply (`runCase`).
// Regenerate with `UPDATE_GOLDENS=1 dart test test/ops/clipboard` and review the diff.

import 'package:test/test.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart';

import '../framework/ops_support.dart';
import 'clipboard_fixtures.dart';

typedef Case = (String, EditProject Function(), EditCommand Function(), EditPolicy?);

final List<Case> duplicateCases = [
  ('duplicate a clip into free space', standard, () => DuplicateItems(ids(['it_c'])), null),
  ('duplicate a linked clip with ripple opens space on both lanes', standard, () => DuplicateItems(ids(['it_a'])), null),
  ('duplicate without ripple goes to a free lane', standard, () => DuplicateItems(ids(['it_b']), ripple: false), null),
  ('duplicate two clips keeps their transition', standard, () => DuplicateItems(ids(['it_a', 'it_b']), ripple: false), null),
  ('duplicate text and a cue', standard, () => DuplicateItems(ids(['it_t1', 'it_s1'])), null),
  ('duplicate on a locked lane', () => standard(lockMain: true), () => DuplicateItems(ids(['it_c'])), null),
  ('duplicate into occupied space with policy reject', standard, () => DuplicateItems(ids(['it_b']), ripple: false),
      const EditPolicy(overlap: OverlapPolicy.reject)),
];

final List<Case> pasteCases = [
  ('paste in the same project into free space', standard, () => PasteItems(copyItems(standard(), ids(['it_c'])), f(300), ripple: false), null),
  ('paste with ripple on the main lane snaps to a cut and opens space', standard,
      () => PasteItems(copyItems(standard(), ids(['it_c'])), f(100), ripple: true), null),
  ('paste without ripple into occupied space goes to a free lane', standard,
      () => PasteItems(copyItems(standard(), ids(['it_c'])), f(100), ripple: false), null),
  ('paste a linked pair keeps them linked under a new link', standard,
      () => PasteItems(copyItems(standard(), ids(['it_a'])), f(300), ripple: false), null),
  ('paste prefers the selected compatible lane', standard,
      () => PasteItems(copyItems(standard(), ids(['it_c'])), f(90), preferTrack: const TrackId('tr_ov1'), ripple: false), null),
  ('paste ignores an incompatible selected lane', standard,
      () => PasteItems(copyItems(standard(), ids(['it_c'])), f(300), preferTrack: const TrackId('tr_music'), ripple: false), null),
  ('paste text goes to the text lane', standard, () => PasteItems(copyItems(standard(), ids(['it_t1'])), f(60), ripple: false), null),
  ('cross-project paste imports, reuses and re-mints media', standard, () => PasteItems(otherPayload(), f(300), ripple: false), null),
  ('cross-project paste from 24 fps re-quantizes onto 30 fps', standard,
      () => PasteItems(otherPayload(frameRate: FrameRate.fps24), f(300), ripple: false), null),
  ('paste an empty payload', standard, () => PasteItems(copyItems(standard(), ids(['it_nope'])), 0), null),
];

final List<Case> replaceCases = [
  ('replace keeps range, effects and keys', withKeys, () => const ReplaceMedia(ItemId('it_v'), MediaId('md_video2')), null),
  ('replace with shorter media shortens with a notice', standard, () => const ReplaceMedia(ItemId('it_b'), MediaId('md_short')), null),
  ('replace resets sourceIn when the new media does not cover it', standard,
      () => const ReplaceMedia(ItemId('it_b'), MediaId('md_video2')), null),
  ('replace a clip with an image', standard, () => const ReplaceMedia(ItemId('it_b'), MediaId('md_image')), null),
  ('replace music with the audio of a video', standard, () => const ReplaceMedia(ItemId('it_m'), MediaId('md_video')), null),
  ('replace with a LUT', standard, () => const ReplaceMedia(ItemId('it_b'), MediaId('md_lut')), null),
  ('replace a video clip with music', standard, () => const ReplaceMedia(ItemId('it_b'), MediaId('md_music')), null),
  ('replace a text item', standard, () => const ReplaceMedia(ItemId('it_t1'), MediaId('md_image')), null),
  ('replace on a locked lane', () => standard(lockMain: true), () => const ReplaceMedia(ItemId('it_b'), MediaId('md_video2')), null),
  ('replace with missing media', standard, () => const ReplaceMedia(ItemId('it_b'), MediaId('md_missing')), null),
];

final List<Case> extractCases = [
  ('extract audio onto the free original lane', standard, () => const ExtractAudio(ItemId('it_b')), null),
  ('extract moves the volume keys and creates a lane when busy', withKeys, () => const ExtractAudio(ItemId('it_v')), null),
  ('extract twice', standard, () => const ExtractAudio(ItemId('it_a')), null),
  ('extract from a video without audio', () => project([
        lane('tr_main', TrackKind.video, [vclip('it_v', 0, 60, media: 'md_noaudio')], main: true),
      ]), () => const ExtractAudio(ItemId('it_v')), null),
  ('extract from an image', standard, () => const ExtractAudio(ItemId('it_p1')), null),
  ('extract from an audio clip', standard, () => const ExtractAudio(ItemId('it_m')), null),
  ('extract on a locked lane', () => standard(lockMain: true), () => const ExtractAudio(ItemId('it_b')), null),
];

final List<Case> linkCases = [
  ('link a clip and music', standard, () => LinkItems(ids(['it_c', 'it_m'])), null),
  ('link merges existing groups', standard, () => LinkItems(ids(['it_a', 'it_t1'])), null),
  ('link two items on one lane', standard, () => LinkItems(ids(['it_b', 'it_c'])), null),
  ('link a single item', standard, () => LinkItems(ids(['it_b'])), null),
  ('link an already linked group', standard, () => LinkItems(ids(['it_a', 'it_a_au'])), null),
  ('unlink a pair dissolves it', standard, () => UnlinkItems(ids(['it_a'])), null),
  ('unlink one of three keeps the others linked', threeLinked, () => UnlinkItems(ids(['it_t'])), null),
  ('unlink an unlinked item', standard, () => UnlinkItems(ids(['it_b'])), null),
  ('cut is copy plus delete in one command', standard, () => cutItems(standard(), ids(['it_b'])).command, null),
  ('cut with ripple', standard, () => cutItems(standard(), ids(['it_a']), ripple: true).command, null),
];

void runGroup(String file, List<Case> cases) {
  final golden = GoldenFile('test/ops/clipboard/goldens/$file');
  tearDownAll(golden.save);
  for (final c in cases) {
    test(c.$1, () {
      golden.check(c.$1, runCase(c.$1, c.$2(), c.$3(), policy: c.$4 ?? const EditPolicy()));
    });
  }
}

void main() {
  group('DuplicateItems', () => runGroup('duplicate.golden', duplicateCases));
  group('PasteItems', () => runGroup('paste.golden', pasteCases));
  group('ReplaceMedia', () => runGroup('replace.golden', replaceCases));
  group('ExtractAudio', () => runGroup('extract.golden', extractCases));
  group('Link, unlink, cut', () => runGroup('link_cut.golden', linkCases));
}
