// OWNER: UX-01
// EXTENDED: AIS-01 (the 1.2.0 actions of AI_STUDIO_PLAN §4.4, after each group's 1.1 ids)
// EXTENDED: INT-101 (the Still Photo Mode and Beauty actions of the VED plan, after AIS-01's tools)
//
// The complete list of editor actions (ARCH §17.6; 1.2.0 additions: AI_STUDIO_PLAN §4.4). One `EditorActionRegistry` (UX-15) feeds tool
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

/// Every editor action (ARCH §17.6, complete list, plus the 1.2.0 [v12Additions] and [vedAdditions]).
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

  // Editing, 1.2.0 rich subtitles (AI_STUDIO_PLAN §4.4).
  /// Bold over the selected text (⌘B inside the rich cue editor only; AIS-18).
  cueStyleBold(EditorActionGroup.editing),

  /// Italic over the selected text (⌘I inside the rich cue editor only; AIS-18).
  cueStyleItalic(EditorActionGroup.editing),

  /// Underline over the selected text (⌘U inside the rich cue editor only; AIS-18).
  cueStyleUnderline(EditorActionGroup.editing),

  /// Clear the styles of the selected text (AIS-18).
  cueStyleClear(EditorActionGroup.editing),

  /// Per-cue placement (AIS-18).
  cuePlacement(EditorActionGroup.editing),

  /// ⌘/Ctrl+Enter: split the cue at the text cursor (AIS-19).
  splitCueAtCursor(EditorActionGroup.editing),

  /// Merge the cue with the previous one (AIS-19).
  mergeCueWithPrevious(EditorActionGroup.editing),

  /// Snap cue edges to speech (AIS-19).
  snapCueToSpeech(EditorActionGroup.editing),

  /// Estimate word timings for karaoke (AIS-19).
  estimateWordTimings(EditorActionGroup.editing),

  /// Remove emojis from a track or selection (AIS-20).
  removeEmojis(EditorActionGroup.editing),

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

  /// ⌘R: render a preview of the selection, loop range or timeline (D-45, UX-44).
  renderPreview(EditorActionGroup.tools),

  /// ⌘/ or ?: shortcuts sheet.
  showShortcuts(EditorActionGroup.tools),

  /// Project sheet.
  projectSheet(EditorActionGroup.tools),

  /// History sheet.
  history(EditorActionGroup.tools),

  /// Tasks sheet.
  tasks(EditorActionGroup.tools),

  /// Relink missing media.
  relink(EditorActionGroup.tools),

  // Tools, 1.2.0 (AI_STUDIO_PLAN §4.4). The first four need AI Studio ([aiStudioActions]).
  /// The AI Studio sheet (AIS-32).
  aiStudio(EditorActionGroup.tools),

  /// ⌘⇧A: Ask AI on the selected text (AIS-34).
  askAi(EditorActionGroup.tools),

  /// Translate a subtitle track (AIS-35).
  translateTrack(EditorActionGroup.tools),

  /// Review AI suggestions (AIS-33).
  reviewAiChanges(EditorActionGroup.tools),

  /// T: the transcript view of the subtitles panel (AIS-17).
  transcriptView(EditorActionGroup.tools),

  /// Karaoke settings of a track (AIS-20).
  karaokeSettings(EditorActionGroup.tools),

  /// Speakers of a track (AIS-18).
  speakers(EditorActionGroup.tools),

  /// Review emojis before removing or keeping them (AIS-20).
  reviewEmojis(EditorActionGroup.tools),

  /// Subtitle style presets (AIS-26).
  subtitlePresets(EditorActionGroup.tools),

  /// Import a font file (AIS-25).
  importFont(EditorActionGroup.tools),

  // Tools, 1.2.0 Unified Photo & Video Editor (VED plan §6; INT-101). Hidden while their build
  // flag is off ([photoEditorActions], [beautyActions], [compareActions]); no shortcuts.
  /// Open the selected photo in Still Photo Mode (VED-01; `DANAVIEW_PHOTO_EDITOR`).
  editPhoto(EditorActionGroup.tools),

  /// The Beauty & Retouching inspector of the selected clip (VED-26; `DANAVIEW_BEAUTY`).
  beauty(EditorActionGroup.tools),

  /// The split before/after comparator (VED-27; either flag).
  compareBeforeAfter(EditorActionGroup.tools),

  /// "To video": add the photo to a new or recent project (VED-14; `DANAVIEW_PHOTO_EDITOR`).
  photoToVideo(EditorActionGroup.tools),

  /// Batch edit photos: apply a preset or pasted recipe to many photos (VED-12;
  /// `DANAVIEW_PHOTO_EDITOR`).
  batchEditPhotos(EditorActionGroup.tools);

  const EditorActionId(this.group);

  /// The action's group.
  final EditorActionGroup group;

  /// The actions that send to an AI provider (AI_STUDIO_PLAN §4.2, D-65). While the build flag
  /// `DANAVIEW_AI_STUDIO` is off they are hidden: `wiring/action_bindings.dart` binds them as
  /// invisible and they have no shortcut. Rich-subtitle actions are not flagged.
  static const Set<EditorActionId> aiStudioActions = {aiStudio, askAi, translateTrack, reviewAiChanges};

  /// The actions added in 1.2.0 (AI_STUDIO_PLAN §4.4), in declaration order.
  static const List<EditorActionId> v12Additions = [
    cueStyleBold,
    cueStyleItalic,
    cueStyleUnderline,
    cueStyleClear,
    cuePlacement,
    splitCueAtCursor,
    mergeCueWithPrevious,
    snapCueToSpeech,
    estimateWordTimings,
    removeEmojis,
    aiStudio,
    askAi,
    translateTrack,
    reviewAiChanges,
    transcriptView,
    karaokeSettings,
    speakers,
    reviewEmojis,
    subtitlePresets,
    importFont,
  ];

  /// The Still Photo Mode actions (VED plan §6.1): hidden while `DANAVIEW_PHOTO_EDITOR` is off.
  static const Set<EditorActionId> photoEditorActions = {editPhoto, photoToVideo, batchEditPhotos};

  /// The Beauty actions (VED plan §6.2): hidden while `DANAVIEW_BEAUTY` is off.
  static const Set<EditorActionId> beautyActions = {beauty};

  /// The comparator (VED-27, stills and beauty on video): hidden while both
  /// `DANAVIEW_PHOTO_EDITOR` and `DANAVIEW_BEAUTY` are off.
  static const Set<EditorActionId> compareActions = {compareBeforeAfter};

  /// The photo and beauty actions added in 1.2.0 (VED plan §6; INT-101), in declaration order.
  static const List<EditorActionId> vedAdditions = [editPhoto, beauty, compareBeforeAfter, photoToVideo, batchEditPhotos];

  /// Whether this action needs AI Studio ([aiStudioActions]).
  bool get needsAiStudio => aiStudioActions.contains(this);

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
