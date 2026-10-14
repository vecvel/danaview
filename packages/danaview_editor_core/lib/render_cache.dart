// OWNER: CORE-37
//
// Public barrel: the render-preview cache model (ARCH D-45(A), §9.5, §17.10): range splitting and
// hashing, heavy ranges, invalidation, coverage and the auto-render policy (pure Dart), plus the
// on-disk cache index (the only dart:io part, under lib/src/store/). The seven CORE-01 barrels
// stay unchanged (BUILD_PLAN §2).

library;

export 'src/plan/render_ranges.dart';
export 'src/store/render_cache_index.dart';
