// OWNER: UX-01
//
// Self-tests of the shared test support: the harness boots the placeholder screens with no
// overflow on the surface matrix, expectOwnerUiRules fires on a round text button and on non-Figtree
// chrome (and passes kit components and content text), the matrix matches ARCH §17.9, and the fake
// repository behaves like the store contract.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:danaview_editor/src/editor/contracts/content_text.dart';
import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_editor_core/model.dart' show FromPlayerOrigin;
import 'package:danaview_editor_core/store.dart';
import 'package:danaview_ui_kit/danaview_ui_kit.dart';

import 'support.dart';

Widget _plainHost(Widget child) => surfaceApp(SurfaceMatrix.phone, Scaffold(body: Center(child: child)));

void main() {
  group('EditorTestHarness', () {
    testSurfaces('boots the placeholder EditorScreen', (tester, surface) async {
      final h = EditorTestHarness();
      final id = await h.pumpEditor(tester, surface: surface);
      expect(find.byType(EditorScreen), findsOneWidget);
      expect(h.repository.projects, contains(id));
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      expectInside(tester, find.byType(EditorScreen));
    });

    testWidgets('EditorScreen close goes through the router callback', (tester) async {
      final h = EditorTestHarness();
      await h.pumpEditor(tester);
      await tester.tap(find.bySemanticsLabel('Close editor'));
      await tester.pump();
      expect(h.closeRequests, 1);
    });

    testSurfaces('boots the placeholder Projects and Editor settings screens', (tester, surface) async {
      final h = EditorTestHarness();
      var back = 0;
      await h.pumpApp(tester, ProjectsScreen(onBack: () => back++, onOpenProject: (id, {initialPlayhead}) {}), surface: surface);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
      await h.pumpApp(tester, EditorSettingsScreen(onBack: () => back++), surface: surface);
      expectNoOverflow(tester);
      expectOwnerUiRules(tester);
    }, surfaces: const [SurfaceMatrix.narrowest, EditorSurface(Size(568, 320), textScale: 1.35)]);

    testWidgets('the root providers are the harness fakes', (tester) async {
      final h = EditorTestHarness();
      await h.pumpEditor(tester);
      final c = h.containerOf(tester);
      expect(c.read(editorEngineProvider), same(h.engine));
      expect(c.read(projectRepositoryProvider), same(h.repository));
      expect(c.read(mediaPoolServiceProvider), same(h.mediaPool));
      expect(c.read(transcriptionServiceProvider), same(h.transcription));
      expect(c.read(editorPrefsProvider), same(h.prefs));
    });
  });

  group('expectOwnerUiRules', () {
    testWidgets('fails on a round text button (circle: true)', (tester) async {
      await tester.pumpWidget(_plainHost(DanaviewPressable(circle: true, onTap: () {}, child: const Text('OK'))));
      expect(ownerUiViolations(tester), [contains('circle: true')]);
      expect(() => expectOwnerUiRules(tester), throwsA(isA<TestFailure>()));
    });

    testWidgets('fails on a pill-shaped text button', (tester) async {
      await tester.pumpWidget(_plainHost(DanaviewPressable(
        onTap: () {},
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          decoration: const BoxDecoration(color: DanaviewColors.primary, borderRadius: BorderRadius.all(Radius.circular(16))),
          child: const Text('Save'),
        ),
      )));
      expect(ownerUiViolations(tester), [contains('pill')]);
    });

    testWidgets('fails on a stadium or oval around the label', (tester) async {
      await tester.pumpWidget(_plainHost(Column(mainAxisSize: MainAxisSize.min, children: [
        DanaviewPressable(
          onTap: () {},
          child: const DecoratedBox(decoration: ShapeDecoration(shape: StadiumBorder()), child: Text('Stadium')),
        ),
        DanaviewPressable(onTap: () {}, child: const ClipOval(child: Text('Oval'))),
      ])));
      expect(ownerUiViolations(tester), hasLength(2));
    });

    testWidgets('fails on chrome text in another font family', (tester) async {
      await tester.pumpWidget(_plainHost(const Text('Hello', style: TextStyle(fontFamily: 'Roboto'))));
      expect(ownerUiViolations(tester), [contains('Roboto')]);
      expect(() => expectOwnerUiRules(tester), throwsA(isA<TestFailure>()));
    });

    testWidgets('fails on chrome text with no family (platform default)', (tester) async {
      await tester.pumpWidget(const Directionality(textDirection: TextDirection.ltr, child: Text('Bare')));
      expect(ownerUiViolations(tester), [contains('platform default')]);
    });

    testWidgets('fails on a span that switches family mid-text', (tester) async {
      await tester.pumpWidget(_plainHost(const Text.rich(TextSpan(text: 'Figtree ', children: [
        TextSpan(text: 'Mono', style: TextStyle(fontFamily: 'Courier')),
      ]))));
      expect(ownerUiViolations(tester), [contains('Courier')]);
    });

    testWidgets('passes kit buttons, icon buttons, text fields and Figtree text', (tester) async {
      await tester.pumpWidget(_plainHost(Column(mainAxisSize: MainAxisSize.min, children: [
        DanaviewButton.primary(label: 'Export', onPressed: () {}),
        DanaviewButton.secondary(label: 'Cancel', onPressed: () {}, size: DanaviewButtonSize.sm),
        DanaviewIconButton(icon: Icons.close_rounded, onPressed: () {}, semanticLabel: 'Close'),
        SizedBox(width: 240, child: DanaviewTextField(controller: TextEditingController(text: 'Typed'))),
        const Text('Chrome'),
        const Icon(Icons.movie_edit),
      ])));
      expectOwnerUiRules(tester);
    });

    testWidgets('content text (EditorContentTextRegion, TextOverlayLayer) is exempt', (tester) async {
      await tester.pumpWidget(_plainHost(const EditorContentTextRegion(
        child: Text('Pacifico preview', style: TextStyle(fontFamily: 'Pacifico')),
      )));
      expectOwnerUiRules(tester);
    });
  });

  group('SurfaceMatrix', () {
    test('full covers every ARCH §17.9 size × text scale × keyboard state', () {
      expect(SurfaceMatrix.sizes, hasLength(14));
      expect(SurfaceMatrix.full, hasLength(14 * 3 * 2));
      expect(SurfaceMatrix.full.map((s) => s.name).toSet(), hasLength(84));
      for (final size in SurfaceMatrix.sizes) {
        for (final scale in [0.85, 1.0, 1.35]) {
          expect(SurfaceMatrix.full.where((s) => s.size == size && s.textScale == scale), hasLength(2));
        }
      }
      expect(SurfaceMatrix.full.every((s) => s.touch), isTrue);
    });

    test('the PR subset has 6 surfaces including 280x500 @1.35 and 568x320 @1.35', () {
      expect(SurfaceMatrix.pr, hasLength(6));
      expect(SurfaceMatrix.pr, contains(const EditorSurface(Size(280, 500), textScale: 1.35)));
      expect(SurfaceMatrix.pr, contains(const EditorSurface(Size(568, 320), textScale: 1.35)));
      expect(SurfaceMatrix.pr.any((s) => s.keyboardFraction > 0), isTrue);
      expect(SurfaceMatrix.current, SurfaceMatrix.pr);
    });

    testWidgets('applySurface sets size and keyboard inset', (tester) async {
      const s = EditorSurface(Size(390, 844), keyboardFraction: 0.4);
      applySurface(tester, s);
      await tester.pumpWidget(surfaceApp(s, Builder(builder: (context) {
        final mq = MediaQuery.of(context);
        return Text('${mq.size.width}x${mq.size.height} ${mq.viewInsets.bottom}');
      })));
      expect(find.text('390.0x844.0 338.0'), findsOneWidget);
    });

    testWidgets('fitsFully detects truncated text; expectInside detects off-screen widgets', (tester) async {
      applySurface(tester, SurfaceMatrix.phone);
      await tester.pumpWidget(surfaceApp(
          SurfaceMatrix.phone,
          const Scaffold(
            body: Stack(children: [
              Positioned(
                left: 0,
                top: 0,
                child: SizedBox(
                    width: 60,
                    child: Text('A label much too long for sixty pixels', key: Key('cut'), maxLines: 1, overflow: TextOverflow.ellipsis)),
              ),
              Positioned(left: 0, top: 100, child: Text('Short', key: Key('ok'))),
              Positioned(left: 380, top: 200, child: SizedBox(width: 40, height: 10, key: Key('off'))),
            ]),
          )));
      expect(fitsFully(tester, find.byKey(const Key('ok'))), isTrue);
      expect(fitsFully(tester, find.byKey(const Key('cut'))), isFalse);
      expect(fitsFully(tester, find.byKey(const Key('off'))), isFalse);
      expect(() => expectInside(tester, find.byKey(const Key('off'))), throwsA(isA<TestFailure>()));
      expectInside(tester, find.byKey(const Key('ok')));
    });
  });

  group('FakeProjectRepository', () {
    test('seed, open (busy, notFound), close, rename, duplicate, delete', () async {
      final repo = FakeProjectRepository();
      final p = repo.seedEmpty('Trip');
      final loaded = await repo.open(p.id);
      expect(loaded.project.name, 'Trip');
      await expectLater(repo.open(p.id), throwsA(const StoreFailure(StoreFailureKind.busy)));
      await repo.close(p.id);
      await expectLater(repo.open(ProjectId('pr_missing0000')), throwsA(const StoreFailure(StoreFailureKind.notFound)));
      await repo.rename(p.id, '  Goa trip ');
      expect(repo.projects[p.id]!.name, 'Goa trip');
      final c1 = await repo.duplicate(p.id);
      final c2 = await repo.duplicate(p.id);
      expect(repo.projects[c1]!.name, 'Goa trip copy');
      expect(repo.projects[c2]!.name, 'Goa trip copy 2');
      await repo.delete(c1);
      expect(repo.projects.keys, isNot(contains(c1)));
      expect(repo.calls, containsAllInOrder(['open:${p.id}', 'close:${p.id}', 'rename:${p.id}', 'delete:$c1']));
    });

    test('create, summaries stream, failNext and untouched lookup', () async {
      final repo = FakeProjectRepository();
      final seen = <List<ProjectSummary>>[];
      final sub = repo.watchSummaries().listen(seen.add);
      final id = await repo.create(const EmptyProjectSpec(name: 'New'));
      await Future<void>.delayed(Duration.zero);
      expect(seen.last.single.id, id);
      repo.failNext['rename'] = const StoreFailure(StoreFailureKind.diskFull);
      await expectLater(repo.rename(id, 'X'), throwsA(const StoreFailure(StoreFailureKind.diskFull)));
      await repo.rename(id, 'X');
      final fromPlayer = await repo.create(FromMediaProjectSpec(
        picks: const [],
        name: 'Clip',
        initialPlayhead: 1000001,
        origin: const FromPlayerOrigin(quickHash: 'qh', sizeBytes: 1),
      ));
      expect(repo.projects[fromPlayer]!.view.playhead, 1000000, reason: 'quantized to the 30 fps grid');
      expect(repo.projects[fromPlayer]!.meta.origin, isA<FromPlayerOrigin>());
      expect(repo.createdSpecs, hasLength(2));
      repo.untouchedByPath['/movies/a.mp4'] = id;
      expect(await repo.findUntouchedProjectFor('/movies/a.mp4'), id);
      expect(await repo.findUntouchedProjectFor('/movies/b.mp4'), isNull);
      await sub.cancel();
      await repo.dispose();
    });
  });
}
