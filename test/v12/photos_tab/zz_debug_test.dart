// ignore_for_file: depend_on_referenced_packages
import 'package:danaview_features/src/library/photos/photos_tab_providers.dart';
import 'package:danaview_features/src/library/photos/photos_tab_widgets.dart';
import 'package:danaview_features/src/library/photos/sliver_photo_masonry.dart';
import 'package:danaview_features/src/library/sources/desktop_photos_source.dart';
import 'package:danaview_features/src/library/sources/system_photos_source.dart';
import 'package:danaview_features/src/library/tabs/photos_tab.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../library_test_utils.dart';
import 'photo_masonry_layout_test.dart' show synthetic;

void main() {
  testWidgets('dbg', (tester) async {
    useSurface(tester, librarySurfaces[2]);
    final env = await LibraryTestEnv.create();
    await tester.pumpWidget(libraryTestApp(env, const PhotosTab(), overrides: [
      danaviewPhotoItemsProvider.overrideWithValue(synthetic(500)),
      systemPhotoLibraryProvider.overrideWithValue(null),
      systemPhotosControllerProvider.overrideWith((ref) => SystemPhotosController(library: null, platform: null)),
      desktopRootResolverProvider.overrideWithValue(null),
    ]));
    await pumpFrames(tester, count: 2);
    final r = tester.renderObject<RenderSliverPhotoMasonry>(find.byType(SliverPhotoMasonry));
    print('children ${r.masonry.childCount} total ${r.masonry.totalExtent} cols ${r.masonry.columns} geom ${r.geometry} constraints ${r.constraints}');
    print('cells ${find.byType(PhotoGridCell).evaluate().length} headers ${find.byType(PhotoDateHeader).evaluate().length}');
    print('first ${r.indexOf(r.firstChild!)} last ${r.indexOf(r.lastChild!)} range ${r.masonry.visibleRange(0, 1072)}');
    for (var i = 0; i < 12; i++) print('$i ${r.masonry.topOf(i)} ${r.masonry.heightOf(i)} ${r.masonry.isHeader(i)}');
    await env.dispose();
  });
}
