// OWNER: UX-01
//
// The complete list of editor actions (ARCH §17.6). One `EditorActionRegistry` (UX-15) feeds tool
// tiles, context menus, keyboard shortcuts, semantics custom actions and the shortcuts sheet from
// these ids; handlers come from the per-feature binding files merged by
// `wiring/action_bindings.dart`.

/// Where an action belongs (shortcuts sheet sections, registry grouping).
///
/// See ARCH §17.6.
enum EditorActionGroup {
  /// Transport and preview.
  playback,

  /// Editing the timeline contents.
  editing,

  /// Timeline view and modes.
  timeline,

  /// Markers.
  markers,

  /// Tools, panels and flows.
  tools,
}

/// Every editor action (ARCH §17.6, complete list).
///
/// See ARCH §17.6.
enum EditorActionId {
  // Playback.
  /// Space / K.
  playPause(EditorActionGroup.playback),

  /// ← one frame back.
  prevFrame(EditorActionGroup.playback),

  /// → one frame forward.
  nextFrame(EditorActionGroup.playback),

  /// Shift+← one second back.
  back1s(EditorActionGroup.playback),

  /// Shift+→ one second forward.
  forward1s(EditorActionGroup.playback),

  /// ↑ previous edit point or marker.
  prevEdit(EditorActionGroup.playback),

  /// ↓ next edit point or marker.
  nextEdit(EditorActionGroup.playback),

  /// Home.
  goStart(EditorActionGroup.playback),

  /// End.
  goEnd(EditorActionGroup.playback),

  /// F.
  fullscreenPreview(EditorActionGroup.playback),

  // Editing.
  /// S: split at the playhead.
  split(EditorActionGroup.editing),

  /// Delete / Backspace.
  delete(EditorActionGroup.editing),

  /// Shift+Delete.
  rippleDelete(EditorActionGroup.editing),

  /// Delete the selected gap.
  deleteGap(EditorActionGroup.editing),

  /// ⌘Z.
  undo(EditorActionGroup.editing),

  /// ⌘⇧Z (and Ctrl+Y off Apple).
  redo(EditorActionGroup.editing),

  /// ⌘S (works in text fields).
  save(EditorActionGroup.editing),

  /// ⌘C.
  copy(EditorActionGroup.editing),

  /// ⌘X (copy + delete, D-16).
  cut(EditorActionGroup.editing),

  /// ⌘V.
  paste(EditorActionGroup.editing),

  /// ⌘D.
  duplicate(EditorActionGroup.editing),

  /// ⌘A.
  selectAll(EditorActionGroup.editing),

  /// Esc: cancel → close panel → clear selection → exit fullscreen.
  escape(EditorActionGroup.editing),

  /// Touch multi-select mode.
  multiSelect(EditorActionGroup.editing),

  /// Move the selection to another track.
  moveToTrack(EditorActionGroup.editing),

  // Timeline.
  /// N.
  toggleSnapping(EditorActionGroup.timeline),

  /// R.
  toggleRipple(EditorActionGroup.timeline),

  /// ⌘=.
  zoomIn(EditorActionGroup.timeline),

  /// ⌘−.
  zoomOut(EditorActionGroup.timeline),

  /// Shift+Z.
  zoomFit(EditorActionGroup.timeline),

  /// Centre the view on the playhead.
  centerPlayhead(EditorActionGroup.timeline),

  /// Cycle lane height.
  laneHeight(EditorActionGroup.timeline),

  /// Safe-area guides in the preview.
  safeGuides(EditorActionGroup.timeline),

  /// Add a track.
  addTrack(EditorActionGroup.timeline),

  // Markers.
  /// M.
  addMarker(EditorActionGroup.markers),

  /// Edit the selected marker.
  editMarker(EditorActionGroup.markers),

  /// Delete the selected marker.
  deleteMarker(EditorActionGroup.markers),

  // Tools.
  /// Media panel.
  media(EditorActionGroup.tools),

  /// Add music.
  addMusic(EditorActionGroup.tools),

  /// Record a voiceover.
  recordVoiceover(EditorActionGroup.tools),

  /// Extract audio from a video clip.
  extractAudio(EditorActionGroup.tools),

  /// Add text at the playhead.
  addText(EditorActionGroup.tools),

  /// Captions panel.
  captions(EditorActionGroup.tools),

  /// Auto captions flow.
  autoCaptions(EditorActionGroup.tools),

  /// Add a caption at the playhead.
  addCaption(EditorActionGroup.tools),

  /// Import SRT/VTT.
  importSubtitles(EditorActionGroup.tools),

  /// Export SRT/VTT.
  exportSubtitles(EditorActionGroup.tools),

  /// Regenerate captions.
  regenerateCaptions(EditorActionGroup.tools),

  /// Add a picture-in-picture overlay.
  addOverlay(EditorActionGroup.tools),

  /// Adjust panel.
  adjust(EditorActionGroup.tools),

  /// Filters panel.
  filters(EditorActionGroup.tools),

  /// Transitions panel.
  transitions(EditorActionGroup.tools),

  /// Format (canvas) panel.
  format(EditorActionGroup.tools),

  /// Transform panel.
  transform(EditorActionGroup.tools),

  /// Crop mode.
  crop(EditorActionGroup.tools),

  /// Mask panel.
  mask(EditorActionGroup.tools),

  /// Chroma key panel.
  chromaKey(EditorActionGroup.tools),

  /// Speed panel.
  speed(EditorActionGroup.tools),

  /// Volume (audio panel).
  volume(EditorActionGroup.tools),

  /// Fades (audio panel).
  fades(EditorActionGroup.tools),

  /// Keyframes panel.
  keyframes(EditorActionGroup.tools),

  /// Add or remove a keyframe at the playhead.
  keyframeAtPlayhead(EditorActionGroup.tools),

  /// Reset the transform.
  resetTransform(EditorActionGroup.tools),

  /// Overlay one lane forward.
  bringForward(EditorActionGroup.tools),

  /// Overlay one lane backward.
  sendBackward(EditorActionGroup.tools),

  /// Reverse the clip.
  reverse(EditorActionGroup.tools),

  /// Freeze frame.
  freeze(EditorActionGroup.tools),

  /// Replace media.
  replace(EditorActionGroup.tools),

  /// Clip info panel.
  clipInfo(EditorActionGroup.tools),

  /// Export flow.
  export(EditorActionGroup.tools),

  /// ⌘/ or ?: shortcuts sheet.
  showShortcuts(EditorActionGroup.tools),

  /// Project sheet.
  projectSheet(EditorActionGroup.tools),

  /// History sheet.
  history(EditorActionGroup.tools),

  /// Tasks sheet.
  tasks(EditorActionGroup.tools),

  /// Relink missing media.
  relink(EditorActionGroup.tools);

  const EditorActionId(this.group);

  /// The action's group.
  final EditorActionGroup group;

  /// The actions of [group], in declaration order.
  static List<EditorActionId> inGroup(EditorActionGroup group) => values.where((a) => a.group == group).toList(growable: false);

  /// The action named [name], or null.
  static EditorActionId? byName(String name) {
    for (final a in values) {
      if (a.name == name) return a;
    }
    return null;
  }
}
