// OWNER: UX-07
//
// EditorLayoutSpec.resolve: the pure layout planner of the editor screen (ARCH §17.2, ux.md §6.2).
//
// * Kinds: compactLandscape (usable height < 520 and landscape), compactPortrait (usable width
//   < 600), medium (< 1000), expanded. The kind comes from the size minus the safe area; the
//   keyboard never changes it (it only takes height away).
// * Regions: top bar, preview, transport, splitter, timeline, tool strip (compactPortrait), rail
//   (expanded), side pane (compactLandscape, medium, expanded) and the inspector dock
//   (compactPortrait with the inspector open). Every visible region has a rect in [regions].
// * Sizes derive from the text scale (each row from its scaled font size, so non-linear scalers are
//   exact): top bar, transport, tool tile 60/64, ruler, lanes.
// * The deterministic degradation ladder (timeline min -> preview 112 -> icon-only tool tiles ->
//   transport merged into the top bar -> keyboard-up preview hidden) is applied one step at a time,
//   only while the minimums can't be met, and the last step applied is recorded in [degrade].
//   Level 0 needs room for the preview minimum (140) plus a comfortable timeline (its minimum plus
//   half a lane); step 1 drops the timeline to its minimum and gives the preview the rest.
//
// Pure: no widgets, no MediaQuery; the scaffold (editor_scaffold.dart) feeds it.

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Layout kinds of the editor (ARCH §17.2, ux.md §6.2).
enum EditorLayoutKind {
  /// Usable height < 520 in landscape (phones in landscape, short windows).
  compactLandscape,

  /// Usable width < 600 (phones in portrait, iPad Slide Over and narrow Split View).
  compactPortrait,

  /// Usable width < 1000 (tablet portrait, wide Split View).
  medium,

  /// Wider (tablet landscape, later desktop).
  expanded,
}

/// Where the inspector shows (ux.md §6.1).
enum InspectorPlacement {
  /// A non-modal `DanaviewDockedPanel` at the bottom (compactPortrait).
  dockBottom,

  /// The side pane (every other kind).
  sidePane,
}

/// Where the tool tiles live (ux.md §6.3).
enum ToolPlacement {
  /// The horizontal strip at the bottom (compactPortrait).
  bottomStrip,

  /// The side pane, when the inspector is closed (compactLandscape, medium).
  sidePane,

  /// The vertical rail at the leading edge (expanded).
  rail,
}

/// The degradation ladder of ux.md §6.2, in the order the steps are applied.
///
/// Steps are cumulative: a layout at [transportInTopBar] has also applied [timelineMin],
/// [previewReduced] and [iconOnlyTools]. Use [EditorLayoutSpec.applied] to test one step.
enum DegradeStep {
  /// No degradation.
  none,

  /// 1. The timeline dropped to its minimum (the splitter has no room left).
  timelineMin,

  /// 2. The preview dropped to 112 (from 140).
  previewReduced,

  /// 3. Tool tiles became icon-only (48 high); labels move to tooltips and semantics.
  iconOnlyTools,

  /// 4. The transport row merged into the top bar (play/pause and compact time replace the title).
  transportInTopBar,

  /// 5. Keyboard up: the preview hides and the inspector takes the space above the keyboard.
  previewHidden,
}

/// The regions of the editor screen (ux.md §6.1).
enum EditorRegion {
  /// Close, title button with save status, undo, redo, export.
  topBar,

  /// The preview surface.
  preview,

  /// Play/pause, timecode, frame step.
  transport,

  /// The preview/timeline splitter.
  splitter,

  /// Ruler, track headers, lanes, playhead.
  timeline,

  /// Bottom tool strip (compactPortrait, inspector closed).
  toolStrip,

  /// Leading tool rail (expanded).
  rail,

  /// Side pane: tools or inspector (compactLandscape, medium), inspector or media bin (expanded).
  pane,

  /// Inspector dock (compactPortrait, inspector open). Its rect reaches the bottom of the screen
  /// (or the top of the keyboard), so the dock draws the bottom safe area itself.
  dock,
}

/// The resolved layout of the editor screen (ARCH §17.2, ux.md §6.2).
///
/// Build it with [resolve]. Every size is in logical pixels; [regions] holds the rect of every
/// visible region in screen coordinates.
@immutable
final class EditorLayoutSpec {
  const EditorLayoutSpec._({
    required this.kind,
    required this.size,
    required this.padding,
    required this.viewInsets,
    required this.touch,
    required this.inspectorOpen,
    required this.topBarHeight,
    required this.topBarTwoLineTitle,
    required this.transportRowHeight,
    required this.transportHeight,
    required this.toolTileHeight,
    required this.toolStripHeight,
    required this.railWidth,
    required this.paneWidth,
    required this.headerWidth,
    required this.rulerHeight,
    required this.previewHeight,
    required this.timelineHeight,
    required this.splitterHeight,
    required this.dockHeight,
    required this.dockMaxHeight,
    required this.inspectorPlacement,
    required this.toolPlacement,
    required this.degrade,
    required this.previewMinHeight,
    required this.timelineMinHeight,
    required this.dockMinHeight,
    required this.splitRatio,
    required this.minSplitRatio,
    required this.maxSplitRatio,
    required this.splitSpan,
    required this.fitsMinimums,
    required this.regions,
  });

  // ---- Constants (ux.md §6.2, §6.5, §9.3) ---------------------------------------------------------

  /// Layout height of the splitter (its touch hit area extends into the neighbours).
  static const double splitterExtent = 12;

  /// Smallest user splitter ratio (preview share of the split space).
  static const double minUserSplitRatio = 0.30;

  /// Largest user splitter ratio.
  static const double maxUserSplitRatio = 0.70;

  /// Preview minimum before degradation.
  static const double previewMin = 140;

  /// Preview minimum after degradation step 2.
  static const double previewReducedMin = 112;

  /// Tool tile height after degradation step 3 (icon only).
  static const double iconOnlyToolTileHeight = 48;

  /// Width of the expanded tool rail.
  static const double expandedRailWidth = 76;

  /// The preview keeps at least this width beside the side pane and rail.
  static const double previewMinWidth = 160;

  /// Default dock height floor (`max(240, timeline + tool strip − 76)`, ux.md §9.3).
  static const double dockDefaultMin = 240;

  /// The dock never goes below this without the keyboard (the preview reaches 112 first).
  static const double dockFloor = 160;

  /// Dock height wanted while the keyboard is up (the text panel pins above the keyboard).
  static const double dockKeyboardDefault = 160;

  /// The dock never goes below this while the keyboard is up: the handle, the panel header and
  /// one text field row (the text panel shows a one-line live preview chip in its header).
  static const double dockKeyboardFloor = 120;

  /// Height of a compact video lane, the main lane every timeline minimum keeps.
  static const double compactVideoLane = 52;

  /// Above its minimum, the timeline keeps this much more (the rest of the next lane) before the
  /// ladder starts: below `previewMin + timelineMin + timelineComfort`, step 1 drops it to its
  /// minimum.
  static const double timelineComfort = 24;

  /// Default splitter ratio (preview share) of [kind].
  static double defaultSplitRatioFor(EditorLayoutKind kind) => switch (kind) {
        EditorLayoutKind.compactPortrait => 0.5,
        EditorLayoutKind.compactLandscape => 0.6,
        EditorLayoutKind.medium => 0.55,
        EditorLayoutKind.expanded => 0.58,
      };

  /// The kind for a usable (safe-area) size.
  static EditorLayoutKind kindFor(Size usable) {
    if (usable.height < 520 && usable.width > usable.height) return EditorLayoutKind.compactLandscape;
    if (usable.width < 600) return EditorLayoutKind.compactPortrait;
    if (usable.width < 1000) return EditorLayoutKind.medium;
    return EditorLayoutKind.expanded;
  }

  /// The kind [resolve] picks for a screen of [size] with the safe area [padding] (the keyboard
  /// never changes it). The scaffold uses it to look up the user's splitter ratio for that kind
  /// before resolving.
  static EditorLayoutKind kindOf({required Size size, required EdgeInsets padding}) {
    final w = _nn(size.width);
    final h = _nn(size.height);
    final left = math.min(_nn(padding.left), w);
    final top = math.min(_nn(padding.top), h);
    final right = math.max(left, w - _nn(padding.right));
    final bottom = math.max(top, h - _nn(padding.bottom));
    return kindFor(Size(right - left, bottom - top));
  }

  // ---- Inputs -----------------------------------------------------------------------------------

  /// The layout kind.
  final EditorLayoutKind kind;

  /// Screen size.
  final Size size;

  /// Safe area.
  final EdgeInsets padding;

  /// Keyboard (only the bottom inset is used).
  final EdgeInsets viewInsets;

  /// Touch-first platform.
  final bool touch;

  /// Whether the inspector is open.
  final bool inspectorOpen;

  // ---- Sizes ------------------------------------------------------------------------------------

  /// Height of the top bar.
  final double topBarHeight;

  /// Whether the top bar title shows name and save status on two lines (else one line).
  final bool topBarTwoLineTitle;

  /// Height of the transport row for this kind and text scale (also when merged).
  final double transportRowHeight;

  /// Height of the transport region (0 when merged into the top bar).
  final double transportHeight;

  /// Tool tile height (60/64, or 48 icon-only).
  final double toolTileHeight;

  /// Height of the bottom tool strip region (0 when there is none).
  final double toolStripHeight;

  /// Width of the tool rail (expanded; 0 otherwise).
  final double railWidth;

  /// Width of the side pane (0 in compactPortrait).
  final double paneWidth;

  /// Width of the timeline's track header column.
  final double headerWidth;

  /// Height of the timeline ruler at this text scale.
  final double rulerHeight;

  /// Height of the preview (0 when hidden).
  final double previewHeight;

  /// Height of the timeline region.
  final double timelineHeight;

  /// Height of the splitter region (0 when absent).
  final double splitterHeight;

  /// Height of the dock at its standard detent, bottom safe area included (0 when not docked).
  /// Pass it to `DanaviewDockedPanel.standardHeight`.
  final double dockHeight;

  /// Room above the keyboard and below the top safe area: the most the dock may grow to.
  final double dockMaxHeight;

  /// Where the inspector shows.
  final InspectorPlacement inspectorPlacement;

  /// Where the tool tiles live.
  final ToolPlacement toolPlacement;

  /// The last degradation step applied ([DegradeStep.none] when none).
  final DegradeStep degrade;

  /// The preview minimum in force (140, or 112 after step 2; 0 once hidden).
  final double previewMinHeight;

  /// The timeline minimum in force (smaller with the dock open: ruler + one lane).
  final double timelineMinHeight;

  /// The dock minimum in force (0 when not docked).
  final double dockMinHeight;

  /// The effective splitter ratio (preview share of [splitSpan]).
  final double splitRatio;

  /// Smallest ratio the splitter may set now (equal to [maxSplitRatio] when it can't move).
  final double minSplitRatio;

  /// Largest ratio the splitter may set now.
  final double maxSplitRatio;

  /// Height shared by the preview and the timeline (what the splitter divides).
  final double splitSpan;

  /// Whether every visible region meets its minimum. Always true on the ARCH §17.9 matrix; false
  /// only for sizes below it (the regions then shrink proportionally, never below zero).
  final bool fitsMinimums;

  /// The rect of every visible region, in screen coordinates.
  final Map<EditorRegion, Rect> regions;

  // ---- Derived ------------------------------------------------------------------------------------

  /// Whether ladder step [step] has been applied.
  bool applied(DegradeStep step) => step != DegradeStep.none && degrade.index >= step.index;

  /// Tool tiles are icon-only (step 3).
  bool get iconOnlyTools => applied(DegradeStep.iconOnlyTools);

  /// The transport is merged into the top bar (step 4).
  bool get transportInTopBar => applied(DegradeStep.transportInTopBar);

  /// The preview is hidden (step 5).
  bool get previewHidden => applied(DegradeStep.previewHidden);

  /// The keyboard is up.
  bool get keyboardVisible => viewInsets.bottom > 0;

  /// Whether the splitter can move.
  bool get splitterMovable => regions.containsKey(EditorRegion.splitter) && maxSplitRatio - minSplitRatio > 1e-6;

  /// The rect of [region], or null when it is not shown.
  Rect? rectOf(EditorRegion region) => regions[region];

  /// Whether [region] is shown.
  bool shows(EditorRegion region) => regions.containsKey(region);

  /// The splitter ratio that gives the preview [previewHeight] (clamped to the allowed range).
  double ratioForPreviewHeight(double previewHeight) {
    if (splitSpan <= 0) return splitRatio;
    return (previewHeight / splitSpan).clamp(minSplitRatio, maxSplitRatio).toDouble();
  }

  // ---- Planner ------------------------------------------------------------------------------------

  /// Plans the editor layout for a screen of [size] with the safe area [padding], the keyboard
  /// [viewInsets] (bottom), text scaled by [textScaler] (already clamped to 0.85–1.35 by the app),
  /// a touch-first platform ([touch]), the user's splitter preference for the resulting kind
  /// ([splitRatio]; null = the kind's default) and whether the inspector is open.
  ///
  /// Pure and deterministic.
  static EditorLayoutSpec resolve({
    required Size size,
    required EdgeInsets padding,
    required EdgeInsets viewInsets,
    required TextScaler textScaler,
    required bool touch,
    double? splitRatio,
    bool inspectorOpen = false,
  }) {
    final w = _nn(size.width);
    final h = _nn(size.height);
    final pad = EdgeInsets.fromLTRB(_nn(padding.left), _nn(padding.top), _nn(padding.right), _nn(padding.bottom));
    final keyboard = _nn(viewInsets.bottom);
    final left = math.min(pad.left, w);
    final top = math.min(pad.top, h);
    final right = math.max(left, w - pad.right);
    final usableBottom = math.max(top, h - pad.bottom);
    final usableWidth = right - left;
    final kind = kindOf(size: Size(w, h), padding: pad);
    assert(kind == kindFor(Size(usableWidth, usableBottom - top)));
    final m = _Metrics(textScaler, kind, touch);

    // The keyboard takes height away from the content; the dock reaches the keyboard (or the
    // screen bottom, drawing the safe area itself).
    final contentBottom = math.max(top, h - math.max(pad.bottom, keyboard));
    final avail = contentBottom - top;
    final dockBottom = math.max(top, keyboard > 0 ? h - keyboard : h);
    final keyboardVisible = keyboard > 0;

    final railWidth = kind == EditorLayoutKind.expanded ? expandedRailWidth : 0.0;
    final paneWidth = kind == EditorLayoutKind.compactPortrait
        ? 0.0
        : math.max(0.0, math.min((usableWidth * 0.34).clamp(280.0, 380.0), usableWidth - railWidth - previewMinWidth)).floorToDouble();

    final userRatio = splitRatio != null && splitRatio.isFinite ? splitRatio : defaultSplitRatioFor(kind);
    final closed = _solveColumn(
      avail: avail,
      topBar: m.topBar,
      transport: m.transport,
      strip: kind == EditorLayoutKind.compactPortrait ? m.toolTile : 0,
      timelineMin: m.timelineMin,
      ratio: userRatio,
      keyboardVisible: keyboardVisible,
    );

    final docked = kind == EditorLayoutKind.compactPortrait && inspectorOpen;
    final regions = <EditorRegion, Rect>{};
    late final _Solution s;
    var dockHeight = 0.0;
    var dockMin = 0.0;
    if (docked) {
      final d = _solveDocked(
        availDock: dockBottom - top,
        topBar: m.topBar,
        transport: m.transport,
        timeline: m.timelineDockMin,
        closedPreview: closed.preview,
        keyboardVisible: keyboardVisible,
      );
      s = d.solution;
      dockHeight = d.dock;
      dockMin = keyboardVisible ? dockKeyboardFloor : dockFloor;
    } else {
      s = closed;
    }

    // ---- Rects ----
    var y = top;
    Rect row(double height, {double x0 = double.nan, double x1 = double.nan}) =>
        Rect.fromLTWH(x0.isNaN ? left : x0, y, (x1.isNaN ? right : x1) - (x0.isNaN ? left : x0), height);
    // Below the matrix the fixed rows alone can be taller than the screen: rows are clipped to the
    // content area (the dock to the keyboard or the screen bottom) and dropped when nothing is left.
    final contentBounds = Rect.fromLTRB(0, top, w, contentBottom);
    final dockBounds = Rect.fromLTRB(0, top, w, dockBottom);
    void put(EditorRegion region, Rect rect) {
      final clipped = rect.intersect(region == EditorRegion.dock ? dockBounds : contentBounds);
      if (clipped.height > 0 && clipped.width > 0) regions[region] = clipped;
    }

    put(EditorRegion.topBar, row(s.topBar));
    y += s.topBar;
    switch (kind) {
      case EditorLayoutKind.compactPortrait:
        put(EditorRegion.preview, row(s.preview));
        y += s.preview;
        put(EditorRegion.transport, row(s.transport));
        y += s.transport;
        put(EditorRegion.splitter, row(s.splitter));
        y += s.splitter;
        put(EditorRegion.timeline, row(s.timeline));
        y += s.timeline;
        if (docked) {
          put(EditorRegion.dock, Rect.fromLTRB(0, y, w, math.max(y, dockBottom)));
        } else {
          put(EditorRegion.toolStrip, row(s.strip));
          y += s.strip;
        }
      case EditorLayoutKind.compactLandscape || EditorLayoutKind.medium || EditorLayoutKind.expanded:
        final expanded = kind == EditorLayoutKind.expanded;
        final paneLeft = expanded ? left + railWidth : right - paneWidth;
        final mainLeft = expanded ? left + railWidth + paneWidth : left;
        final mainRight = expanded ? right : right - paneWidth;
        if (s.preview <= 0) {
          // Step 5: keyboard up. The pane (tools or inspector) takes the full height beside the
          // timeline, so the panel being typed into stays visible above the keyboard.
          final height = s.timeline;
          if (expanded) put(EditorRegion.rail, Rect.fromLTWH(left, y, railWidth, height));
          put(EditorRegion.pane, Rect.fromLTWH(paneLeft, y, paneWidth, height));
          put(EditorRegion.timeline, Rect.fromLTRB(mainLeft, y, mainRight, y + height));
          y += height;
        } else {
          final band = s.preview + (expanded ? s.transport : 0);
          if (expanded) put(EditorRegion.rail, Rect.fromLTWH(left, y, railWidth, band));
          put(EditorRegion.pane, Rect.fromLTWH(paneLeft, y, paneWidth, band));
          put(EditorRegion.preview, Rect.fromLTRB(mainLeft, y, mainRight, y + s.preview));
          y += s.preview;
          if (expanded) {
            put(EditorRegion.transport, Rect.fromLTRB(mainLeft, y, mainRight, y + s.transport));
          } else {
            put(EditorRegion.transport, row(s.transport));
          }
          y += s.transport;
          put(EditorRegion.splitter, row(s.splitter));
          y += s.splitter;
          put(EditorRegion.timeline, row(s.timeline));
          y += s.timeline;
        }
    }

    final toolPlacement = switch (kind) {
      EditorLayoutKind.compactPortrait => ToolPlacement.bottomStrip,
      EditorLayoutKind.compactLandscape || EditorLayoutKind.medium => ToolPlacement.sidePane,
      EditorLayoutKind.expanded => ToolPlacement.rail,
    };
    final previewMinNow = s.step.index >= DegradeStep.previewHidden.index
        ? 0.0
        : s.step.index >= DegradeStep.previewReduced.index
            ? previewReducedMin
            : previewMin;
    final timelineMinNow = !regions.containsKey(EditorRegion.timeline)
        ? 0.0
        : docked
            ? m.timelineDockMin
            : m.timelineMin;
    final hasSplitter = regions.containsKey(EditorRegion.splitter);

    return EditorLayoutSpec._(
      kind: kind,
      size: Size(w, h),
      padding: pad,
      viewInsets: EdgeInsets.only(bottom: keyboard),
      touch: touch,
      inspectorOpen: inspectorOpen,
      topBarHeight: s.topBar,
      topBarTwoLineTitle: kind != EditorLayoutKind.compactLandscape,
      transportRowHeight: m.transport,
      transportHeight: regions.containsKey(EditorRegion.transport) ? s.transport : 0,
      toolTileHeight: s.step.index >= DegradeStep.iconOnlyTools.index ? iconOnlyToolTileHeight : m.toolTile,
      toolStripHeight: regions[EditorRegion.toolStrip]?.height ?? 0,
      railWidth: regions.containsKey(EditorRegion.rail) ? railWidth : 0,
      paneWidth: regions.containsKey(EditorRegion.pane) ? paneWidth : 0,
      headerWidth: m.headerWidth,
      rulerHeight: m.ruler,
      previewHeight: regions[EditorRegion.preview]?.height ?? 0,
      timelineHeight: regions[EditorRegion.timeline]?.height ?? 0,
      splitterHeight: hasSplitter ? s.splitter : 0,
      dockHeight: regions[EditorRegion.dock]?.height ?? dockHeight,
      dockMaxHeight: math.max(0, dockBottom - top),
      inspectorPlacement: kind == EditorLayoutKind.compactPortrait ? InspectorPlacement.dockBottom : InspectorPlacement.sidePane,
      toolPlacement: toolPlacement,
      degrade: s.step,
      previewMinHeight: previewMinNow,
      timelineMinHeight: timelineMinNow,
      dockMinHeight: docked ? dockMin : 0,
      splitRatio: hasSplitter ? closed.ratio : userRatio.clamp(minUserSplitRatio, maxUserSplitRatio).toDouble(),
      minSplitRatio: hasSplitter ? closed.ratioMin : closed.ratio,
      maxSplitRatio: hasSplitter ? closed.ratioMax : closed.ratio,
      splitSpan: hasSplitter ? closed.span : 0,
      fitsMinimums: s.fits,
      regions: Map.unmodifiable(regions),
    );
  }

  /// Solves one column: top bar, preview, transport, splitter, timeline and (compactPortrait) the
  /// tool strip, walking the ladder until the minimums are met.
  static _Solution _solveColumn({
    required double avail,
    required double topBar,
    required double transport,
    required double strip,
    required double timelineMin,
    required double ratio,
    required bool keyboardVisible,
  }) {
    var tr = transport;
    var st = strip;
    var spl = splitterExtent;
    double span() => avail - topBar - tr - st - spl;

    // Level 0: room for the preview minimum and a comfortable timeline (half a lane above its
    // minimum). The user's ratio, clamped to the user range and to both minimums, splits the space.
    final r0 = span();
    if (r0 >= previewMin + timelineMin + timelineComfort) {
      final r = ratio.clamp(minUserSplitRatio, maxUserSplitRatio).toDouble();
      final hi = r0 - timelineMin;
      final preview = (r0 * r).floorToDouble().clamp(previewMin, hi).toDouble();
      final lo = math.min(math.max(minUserSplitRatio, previewMin / r0), 1.0);
      final up = math.max(math.min(maxUserSplitRatio, hi / r0), 0.0);
      final eff = preview / r0;
      return _Solution(
        step: DegradeStep.none,
        topBar: topBar,
        preview: preview,
        transport: tr,
        splitter: spl,
        timeline: r0 - preview,
        strip: st,
        fits: true,
        ratio: eff,
        ratioMin: lo <= up ? math.min(lo, eff) : eff,
        ratioMax: lo <= up ? math.max(up, eff) : eff,
        span: r0,
      );
    }

    _Solution fixed(DegradeStep step, double preview, double timeline, {bool fits = true}) {
      final s = span();
      final ratio = s > 0 ? preview / s : 0.0;
      return _Solution(
        step: step,
        topBar: topBar,
        preview: preview,
        transport: tr,
        splitter: spl,
        timeline: timeline,
        strip: st,
        fits: fits,
        ratio: ratio,
        ratioMin: ratio,
        ratioMax: ratio,
        span: s,
      );
    }

    // 1. The timeline drops to its minimum.
    if (span() - timelineMin >= previewMin) return fixed(DegradeStep.timelineMin, span() - timelineMin, timelineMin);
    // 2. The preview drops to 112.
    if (span() - timelineMin >= previewReducedMin) return fixed(DegradeStep.previewReduced, span() - timelineMin, timelineMin);
    // 3. Icon-only tool tiles.
    if (st > 0) st = math.min(st, iconOnlyToolTileHeight);
    if (span() - timelineMin >= previewReducedMin) return fixed(DegradeStep.iconOnlyTools, span() - timelineMin, timelineMin);
    // 4. The transport merges into the top bar.
    tr = 0;
    if (span() - timelineMin >= previewReducedMin) return fixed(DegradeStep.transportInTopBar, span() - timelineMin, timelineMin);
    // 5. Keyboard up: the preview hides.
    if (keyboardVisible) {
      spl = 0;
      final rest = math.max(0.0, span());
      return fixed(DegradeStep.previewHidden, 0, rest, fits: rest >= timelineMin);
    }
    // Below the matrix: keep everything, squeeze the preview first.
    final rest = math.max(0.0, span());
    final timeline = math.min(timelineMin, rest);
    return fixed(DegradeStep.transportInTopBar, rest - timeline, timeline, fits: false);
  }

  /// Solves compactPortrait with the inspector dock open: top bar, preview (kept at its closed
  /// height when it can), transport, the timeline reduced to ruler + one lane, then the dock down
  /// to the keyboard or the screen bottom. The dock gives up height (down to its floor) before the
  /// ladder goes past step 2.
  static ({_Solution solution, double dock}) _solveDocked({
    required double availDock,
    required double topBar,
    required double transport,
    required double timeline,
    required double closedPreview,
    required bool keyboardVisible,
  }) {
    final dockPref = keyboardVisible ? dockKeyboardDefault : dockDefaultMin;
    final floor = keyboardVisible ? dockKeyboardFloor : dockFloor;
    double room(double tr, double dock) => availDock - topBar - tr - timeline - dock;

    ({_Solution solution, double dock}) done(DegradeStep step, double tr, double preview, {bool fits = true, double? lanes}) {
      final tl = lanes ?? timeline;
      final dock = availDock - topBar - tr - preview - tl;
      return (
        solution: _Solution(
          step: step,
          topBar: topBar,
          preview: preview,
          transport: tr,
          splitter: 0,
          timeline: tl,
          strip: 0,
          fits: fits && dock >= floor - 1e-9,
          ratio: 0,
          ratioMin: 0,
          ratioMax: 0,
          span: 0,
        ),
        dock: dock,
      );
    }

    double keep(double lo, double hi) => closedPreview.floorToDouble().clamp(lo, hi).toDouble();

    // Level 0 (and 1, which the docked layout already applies to the timeline).
    if (room(transport, dockPref) >= previewMin) {
      return done(DegradeStep.none, transport, keep(previewMin, room(transport, dockPref)));
    }
    // 2. Preview 112; the dock may shrink from its default to its floor first.
    if (room(transport, dockPref) >= previewReducedMin) {
      return done(DegradeStep.previewReduced, transport, keep(previewReducedMin, room(transport, dockPref)));
    }
    if (room(transport, floor) >= previewReducedMin) return done(DegradeStep.previewReduced, transport, previewReducedMin);
    // 3. (Icon-only tiles: no strip while docked.) 4. Transport merged into the top bar.
    if (room(0, dockPref) >= previewReducedMin) {
      return done(DegradeStep.transportInTopBar, 0, keep(previewReducedMin, room(0, dockPref)));
    }
    if (room(0, floor) >= previewReducedMin) return done(DegradeStep.transportInTopBar, 0, previewReducedMin);
    // 5. Keyboard up: the preview hides and the dock takes the space above the keyboard; when even
    // that is short of the dock's floor, the reduced timeline hides too (the panel being typed into
    // wins; ux.md §10.8).
    if (keyboardVisible) {
      if (availDock - topBar - timeline >= floor) return done(DegradeStep.previewHidden, 0, 0);
      return done(DegradeStep.previewHidden, 0, 0, lanes: 0);
    }
    return done(DegradeStep.transportInTopBar, 0, math.max(0.0, room(0, floor)), fits: false);
  }

  @override
  bool operator ==(Object other) =>
      other is EditorLayoutSpec &&
      other.kind == kind &&
      other.size == size &&
      other.padding == padding &&
      other.viewInsets == viewInsets &&
      other.touch == touch &&
      other.inspectorOpen == inspectorOpen &&
      other.topBarHeight == topBarHeight &&
      other.transportRowHeight == transportRowHeight &&
      other.toolTileHeight == toolTileHeight &&
      other.headerWidth == headerWidth &&
      other.rulerHeight == rulerHeight &&
      other.dockHeight == dockHeight &&
      other.dockMaxHeight == dockMaxHeight &&
      other.degrade == degrade &&
      other.splitRatio == splitRatio &&
      other.minSplitRatio == minSplitRatio &&
      other.maxSplitRatio == maxSplitRatio &&
      other.fitsMinimums == fitsMinimums &&
      mapEquals(other.regions, regions);

  @override
  int get hashCode => Object.hash(
        kind,
        size,
        padding,
        viewInsets,
        touch,
        inspectorOpen,
        topBarHeight,
        toolTileHeight,
        dockHeight,
        degrade,
        splitRatio,
        Object.hashAllUnordered(regions.entries.map((e) => Object.hash(e.key, e.value))),
      );

  @override
  String toString() {
    final r = regions.entries.map((e) => '${e.key.name}=${_fmt(e.value)}').join(', ');
    return 'EditorLayoutSpec(${kind.name}, ${size.width.round()}x${size.height.round()}, degrade: ${degrade.name}, '
        'fits: $fitsMinimums, $r)';
  }

  static String _fmt(Rect r) =>
      '[${r.left.toStringAsFixed(0)},${r.top.toStringAsFixed(0)} ${r.width.toStringAsFixed(0)}x${r.height.toStringAsFixed(0)}]';

  static double _nn(double v) => v.isFinite && v > 0 ? v : 0;
}

/// Text-scale-derived sizes of ux.md §6.2 for one kind. Each row height uses the scaled size of its
/// own font, so a non-linear scaler never clips.
final class _Metrics {
  _Metrics(TextScaler scaler, EditorLayoutKind kind, bool touch)
      : topBar = switch (kind) {
          EditorLayoutKind.compactPortrait => _twoLine(scaler),
          EditorLayoutKind.compactLandscape => math.max(44, (12 + scaler.scale(15) * 1.25).ceilToDouble()),
          EditorLayoutKind.medium || EditorLayoutKind.expanded => math.max(56, _twoLine(scaler)),
        },
        transport = kind == EditorLayoutKind.compactLandscape
            ? math.max(40, (14 + scaler.scale(13) * 1.3).ceilToDouble())
            : math.max(44, (16 + scaler.scale(13) * 1.3).ceilToDouble()),
        toolTile = math.max(60, ((8 + 24 + 4 + scaler.scale(11) * 1.25 + 8) / 4).ceilToDouble() * 4),
        ruler = math.max(24, (8 + scaler.scale(11) * 1.2).ceilToDouble()),
        textLane = math.max(32, (12 + scaler.scale(11) * 1.3).ceilToDouble()),
        headerWidth = switch (kind) {
          EditorLayoutKind.compactPortrait || EditorLayoutKind.compactLandscape => 44,
          EditorLayoutKind.medium => 132,
          EditorLayoutKind.expanded => touch ? 220 : 168,
        },
        _kind = kind;

  static double _twoLine(TextScaler scaler) => math.max(52, (10 + scaler.scale(15) * 1.25 + scaler.scale(12) * 1.2).ceilToDouble());

  final EditorLayoutKind _kind;

  /// Top bar height.
  final double topBar;

  /// Transport row height.
  final double transport;

  /// Tool tile (icon + label) height.
  final double toolTile;

  /// Ruler height.
  final double ruler;

  /// Text/subtitle lane height.
  final double textLane;

  /// Track header column width.
  final double headerWidth;

  /// Timeline minimum: ruler + main lane + half a lane (compactLandscape: + a text lane).
  double get timelineMin => _kind == EditorLayoutKind.compactLandscape
      ? ruler + EditorLayoutSpec.compactVideoLane + textLane
      : ruler + EditorLayoutSpec.compactVideoLane + 24;

  /// Timeline with the dock open: ruler + the selected item's lane (≥ 76).
  double get timelineDockMin => math.max(76, ruler + EditorLayoutSpec.compactVideoLane);
}

/// One column solution.
final class _Solution {
  const _Solution({
    required this.step,
    required this.topBar,
    required this.preview,
    required this.transport,
    required this.splitter,
    required this.timeline,
    required this.strip,
    required this.fits,
    required this.ratio,
    required this.ratioMin,
    required this.ratioMax,
    required this.span,
  });

  final DegradeStep step;
  final double topBar;
  final double preview;
  final double transport;
  final double splitter;
  final double timeline;
  final double strip;
  final bool fits;
  final double ratio;
  final double ratioMin;
  final double ratioMax;
  final double span;
}
