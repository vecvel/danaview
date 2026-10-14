// OWNER: UX-37
//
// The Auto captions state machine (ai.md §11.2, ux.md §12.1, D-19/D-20, ARCH §16):
//
//   checking ─► unsupported
//      └─► configure ─► (model missing/corrupt) consent ─► downloading ─┐
//                 └──────────────────────────────────────────────────────┴► running ⇄ needsLanguage
//                                                                              │   ⇄ waitingForExport
//                                                                              ├► done (applied: one history entry)
//                                                                              └► failed (copy per TranscriptionFailure)
//
// * The language defaults to the last one used, else the device locale's language (D-19); "Detect
//   automatically" is a secondary choice, and a low-confidence detection asks for one of the top 3.
// * Tiers come from `TranscriptionService.offers` (RAM gating; Accurate is hidden when the device
//   does not qualify, D-20). Installed tiers show "Ready".
// * Downloads need a `UserConsent`, which only `ModelConsentView` creates (ARCH §4.2 rule 8); the
//   controller only passes it on. Consent is per download: a retry asks again.
// * The service never edits the project. The result is applied once, as ONE history entry, through
//   `EditorController.apply` (`AddGeneratedCaptionTrack` or `ReplaceGeneratedCaptions`, CORE-15).
//   Cancel at any step applies nothing, so no partial track is ever left behind.
// * While a download or job runs the controller keeps its provider alive (closing the sheet hides
//   it), holds the wakelock and reports a row in the Tasks sheet. Leaving the editor stops the job
//   and keeps the checkpoint (D-20).

import 'dart:async';
import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:danaview_editor_core/model.dart';
import 'package:danaview_editor_core/ops.dart' show AddGeneratedCaptionTrack, EditCommand, EditRejection, ReplaceGeneratedCaptions;
import 'package:danaview_platform/danaview_platform.dart' show PlatformBridge;
import 'package:danaview_transcription/danaview_transcription.dart';

import '../../../app/editor_prefs.dart';
import '../../../app/editor_providers.dart';
import '../../../app/strings/captions_strings.dart';
import '../../contracts/inspector_routes.dart';
import '../../state/editor_controller.dart';
import '../../state/editor_session.dart';
import '../../state/editor_state.dart';
import '../../state/tasks_controller.dart';

/// Stages of the flow (ai.md §11.2).
enum AutoCaptionsStage {
  /// Reading device support and model status.
  checking,

  /// The device cannot run Auto captions.
  unsupported,

  /// Language, quality, scope and layout.
  configure,

  /// The speech model must be downloaded first: the consent view.
  consent,

  /// The model is downloading.
  downloading,

  /// The job waits for a running export.
  waitingForExport,

  /// The job runs.
  running,

  /// The detection was not confident: the user picks one of the top 3 (D-19).
  needsLanguage,

  /// The captions were added (one history entry).
  done,

  /// Something failed ([AutoCaptionsState.failure] or [AutoCaptionsState.applyRejection]).
  failed,
}

/// What to caption.
enum CaptionsScopeKind {
  /// The selected clip(s).
  selection,

  /// The whole timeline.
  wholeVideo,
}

/// An audio source of the timeline the user can include or exclude (Advanced).
@immutable
final class CaptionAudioTrack {
  /// Creates the row.
  const CaptionAudioTrack({required this.id, required this.name, required this.music});

  /// Track.
  final TrackId id;

  /// Display name.
  final String name;

  /// A music track (off by default).
  final bool music;

  @override
  bool operator ==(Object other) => other is CaptionAudioTrack && other.id == id && other.name == name && other.music == music;

  @override
  int get hashCode => Object.hash(id, name, music);
}

const Object _keep = Object();

/// The user's choices.
@immutable
final class AutoCaptionsDraft {
  /// Creates a draft.
  const AutoCaptionsDraft({
    this.scope = CaptionsScopeKind.wholeVideo,
    this.language = const AutoLanguage(),
    this.tier = SpeechModelTier.balanced,
    this.segmentation = const SegmentationSettings(),
    this.includeSoundDescriptions = false,
    this.excludedTracks = const {},
    this.includedMusic = const {},
    this.replaceGenerated = true,
  });

  /// What to caption.
  final CaptionsScopeKind scope;

  /// Spoken language.
  final SpokenLanguage language;

  /// Quality tier.
  final SpeechModelTier tier;

  /// Layout preset and limits.
  final SegmentationSettings segmentation;

  /// Keep `[music]`-style annotations.
  final bool includeSoundDescriptions;

  /// Audio tracks switched off in Advanced.
  final Set<TrackId> excludedTracks;

  /// Music tracks switched on in Advanced (music is off by default).
  final Set<TrackId> includedMusic;

  /// Replace the previous generated captions (when a generated lane exists).
  final bool replaceGenerated;

  /// A copy with the given fields replaced.
  AutoCaptionsDraft copyWith({
    CaptionsScopeKind? scope,
    SpokenLanguage? language,
    SpeechModelTier? tier,
    SegmentationSettings? segmentation,
    bool? includeSoundDescriptions,
    Set<TrackId>? excludedTracks,
    Set<TrackId>? includedMusic,
    bool? replaceGenerated,
  }) =>
      AutoCaptionsDraft(
        scope: scope ?? this.scope,
        language: language ?? this.language,
        tier: tier ?? this.tier,
        segmentation: segmentation ?? this.segmentation,
        includeSoundDescriptions: includeSoundDescriptions ?? this.includeSoundDescriptions,
        excludedTracks: excludedTracks ?? this.excludedTracks,
        includedMusic: includedMusic ?? this.includedMusic,
        replaceGenerated: replaceGenerated ?? this.replaceGenerated,
      );

  @override
  bool operator ==(Object other) =>
      other is AutoCaptionsDraft &&
      other.scope == scope &&
      _sameLanguage(other.language, language) &&
      other.tier == tier &&
      other.segmentation == segmentation &&
      other.includeSoundDescriptions == includeSoundDescriptions &&
      setEquals(other.excludedTracks, excludedTracks) &&
      setEquals(other.includedMusic, includedMusic) &&
      other.replaceGenerated == replaceGenerated;

  @override
  int get hashCode => Object.hash(scope, _languageKey(language), tier, segmentation, includeSoundDescriptions,
      Object.hashAllUnordered(excludedTracks), Object.hashAllUnordered(includedMusic), replaceGenerated);
}

bool _sameLanguage(SpokenLanguage a, SpokenLanguage b) => _languageKey(a) == _languageKey(b);

String _languageKey(SpokenLanguage l) => switch (l) {
      AutoLanguage() => 'auto',
      FixedLanguage(:final code) => code,
    };

/// State of the flow (ai.md §11.2).
@immutable
final class AutoCaptionsState {
  /// Creates a state.
  const AutoCaptionsState({
    this.stage = AutoCaptionsStage.checking,
    this.support,
    this.offers = const [],
    this.readyModels = const {},
    this.draft = const AutoCaptionsDraft(),
    this.selection = const [],
    this.audioTracks = const [],
    this.generatedTrack,
    this.disclosure,
    this.modelCorrupt = false,
    this.missingSpaceBytes,
    this.download,
    this.downloadResumed = false,
    this.progress,
    this.failure,
    this.applyRejection,
    this.summary,
    this.starting = false,
  });

  /// Stage.
  final AutoCaptionsStage stage;

  /// Device support.
  final TranscriptionSupport? support;

  /// Tiers offered on this device (Accurate removed when the device does not qualify, D-20).
  final List<SpeechModelOffer> offers;

  /// Catalog ids of installed, verified models.
  final Set<String> readyModels;

  /// The user's choices.
  final AutoCaptionsDraft draft;

  /// The selected clips the "This clip" scope captions (empty: whole video only).
  final List<ItemId> selection;

  /// Audio sources of the timeline (Advanced).
  final List<CaptionAudioTrack> audioTracks;

  /// The generated subtitle lane a run can replace, or null.
  final TrackId? generatedTrack;

  /// What the consent view shows (stage [AutoCaptionsStage.consent]).
  final ConsentDisclosure? disclosure;

  /// The installed model is damaged ("Download again").
  final bool modelCorrupt;

  /// Free space the download needs when the device lacks it (consent shows it), else null.
  final int? missingSpaceBytes;

  /// Download progress.
  final ModelDownloadProgress? download;

  /// The download continues a partial file.
  final bool downloadResumed;

  /// Job progress.
  final TranscriptionProgress? progress;

  /// Why the flow failed.
  final TranscriptionFailure? failure;

  /// Why the finished result could not be applied (stage failed, [failure] null).
  final EditRejection? applyRejection;

  /// The finished job's summary.
  final TranscriptionSummary? summary;

  /// The checks before starting run (the primary button shows "Starting…").
  final bool starting;

  /// The offer of [draft]'s tier, if offered.
  SpeechModelOffer? get selectedOffer {
    for (final o in offers) {
      if (o.spec.tier == draft.tier) return o;
    }
    return null;
  }

  /// Whether a download or job is in flight.
  bool get busy => switch (stage) {
        AutoCaptionsStage.downloading ||
        AutoCaptionsStage.running ||
        AutoCaptionsStage.needsLanguage ||
        AutoCaptionsStage.waitingForExport =>
          true,
        _ => false,
      };

  /// A copy with the given fields replaced (pass null to clear the nullable ones).
  AutoCaptionsState copyWith({
    AutoCaptionsStage? stage,
    Object? support = _keep,
    List<SpeechModelOffer>? offers,
    Set<String>? readyModels,
    AutoCaptionsDraft? draft,
    List<ItemId>? selection,
    List<CaptionAudioTrack>? audioTracks,
    Object? generatedTrack = _keep,
    Object? disclosure = _keep,
    bool? modelCorrupt,
    Object? missingSpaceBytes = _keep,
    Object? download = _keep,
    bool? downloadResumed,
    Object? progress = _keep,
    Object? failure = _keep,
    Object? applyRejection = _keep,
    Object? summary = _keep,
    bool? starting,
  }) =>
      AutoCaptionsState(
        stage: stage ?? this.stage,
        support: identical(support, _keep) ? this.support : support as TranscriptionSupport?,
        offers: offers ?? this.offers,
        readyModels: readyModels ?? this.readyModels,
        draft: draft ?? this.draft,
        selection: selection ?? this.selection,
        audioTracks: audioTracks ?? this.audioTracks,
        generatedTrack: identical(generatedTrack, _keep) ? this.generatedTrack : generatedTrack as TrackId?,
        disclosure: identical(disclosure, _keep) ? this.disclosure : disclosure as ConsentDisclosure?,
        modelCorrupt: modelCorrupt ?? this.modelCorrupt,
        missingSpaceBytes: identical(missingSpaceBytes, _keep) ? this.missingSpaceBytes : missingSpaceBytes as int?,
        download: identical(download, _keep) ? this.download : download as ModelDownloadProgress?,
        downloadResumed: downloadResumed ?? this.downloadResumed,
        progress: identical(progress, _keep) ? this.progress : progress as TranscriptionProgress?,
        failure: identical(failure, _keep) ? this.failure : failure as TranscriptionFailure?,
        applyRejection: identical(applyRejection, _keep) ? this.applyRejection : applyRejection as EditRejection?,
        summary: identical(summary, _keep) ? this.summary : summary as TranscriptionSummary?,
        starting: starting ?? this.starting,
      );

  @override
  String toString() => 'AutoCaptionsState(${stage.name}${failure == null ? '' : ', ${failure!.code}'})';
}

/// Preference keys of the flow (the `editor.` namespace, ARCH §17.10).
abstract final class AutoCaptionsPrefKeys {
  /// Last spoken language (whisper code, or `auto`).
  static const String lastLanguage = 'editor.captions.lastLanguage';

  /// Up to 3 recent whisper codes, comma-separated, newest first.
  static const String recentLanguages = 'editor.captions.recentLanguages';
}

/// Platform pieces the flow uses; tests replace them.
@immutable
final class AutoCaptionsHost {
  /// Creates the host.
  const AutoCaptionsHost({this.wakelock = _defaultWakelock, this.onOpenPrivacyPolicy, this.deviceLocale = _platformLocale});

  /// Holds or releases the screen wakelock (on during download and job).
  final void Function(bool on) wakelock;

  /// Opens the Privacy Policy (`/settings/privacy`); null hides the link.
  final VoidCallback? onOpenPrivacyPolicy;

  /// The device locale (preselects the spoken language, D-19).
  final Locale Function() deviceLocale;

  static void _defaultWakelock(bool on) => unawaited(PlatformBridge.setSleepInhibited(on));

  static Locale _platformLocale() => PlatformDispatcher.instance.locale;
}

/// The router's [AutoCaptionsHost] (INT-04 supplies the privacy link).
final autoCaptionsHostProvider = Provider<AutoCaptionsHost>((ref) => const AutoCaptionsHost(), name: 'autoCaptionsHostProvider');

/// The Auto captions state machine (ai.md §11.2).
class AutoCaptionsController extends StateNotifier<AutoCaptionsState> {
  /// Creates the controller over [service] for the editor [editor] of [projectId].
  AutoCaptionsController({
    required this.projectId,
    required TranscriptionService service,
    required EditorController editor,
    required EditorPrefs prefs,
    required TimelineView Function() timeline,
    AutoCaptionsHost host = const AutoCaptionsHost(),
    TasksController? Function()? tasks,
    void Function(bool busy)? onBusyChanged,
    DateTime Function()? clock,
  })  : _service = service,
        _editor = editor,
        _prefs = prefs,
        _timeline = timeline,
        _host = host,
        _tasks = tasks ?? (() => null),
        _onBusyChanged = onBusyChanged,
        _clock = clock ?? DateTime.now,
        super(const AutoCaptionsState());

  /// The project.
  final ProjectId projectId;

  final TranscriptionService _service;
  final EditorController _editor;
  final EditorPrefs _prefs;
  final TimelineView Function() _timeline;
  final AutoCaptionsHost _host;
  final TasksController? Function() _tasks;
  final void Function(bool busy)? _onBusyChanged;
  final DateTime Function() _clock;

  /// Shows a toast where the flow was opened (set by `AutoCaptionsSheet.show`).
  void Function(String message)? toaster;

  StreamSubscription<ModelDownloadProgress>? _downloadSub;
  TranscriptionJob? _job;
  StreamSubscription<TranscriptionProgress>? _progressSub;
  TranscriptionResult? _result;
  EditorTaskHandle? _task;
  DateTime? _jobStartedAt;
  bool _wasBusy = false;
  CaptionProvenance? _regenerateFrom;
  TrackId? _regenerateTrack;
  int _openToken = 0;

  /// The running job, if any.
  TranscriptionJob? get job => _job;

  /// Whether cancelling should ask first (more than 30 s of work done).
  bool get cancelNeedsConfirm {
    final started = _jobStartedAt;
    return _job != null && started != null && _clock().difference(started) > const Duration(seconds: 30);
  }

  /// The languages of the picker (whisper's 99).
  List<TranscriptionLanguage> get languages => _service.languages;

  /// Recent whisper codes, newest first.
  List<String> get recentLanguages {
    final raw = _prefs.readString(AutoCaptionsPrefKeys.recentLanguages);
    if (raw == null || raw.isEmpty) return const [];
    return [for (final c in raw.split(',')) if (languageForWhisperCode(c) != null) c];
  }

  /// The device locale's language, if whisper knows it.
  TranscriptionLanguage? get deviceLanguage {
    try {
      return languageForLocale(_host.deviceLocale().toLanguageTag());
    } on Object {
      return null;
    }
  }

  @override
  set state(AutoCaptionsState value) {
    super.state = value;
    final busy = value.busy;
    if (busy != _wasBusy) {
      _wasBusy = busy;
      _host.wakelock(busy);
      _onBusyChanged?.call(busy);
    }
  }

  // -----------------------------------------------------------------------------------------------
  // Open and configure
  // -----------------------------------------------------------------------------------------------

  /// Opens the flow: checks support and models and fills the draft. [scope] preselects "This clip"
  /// (a clip context menu); [regenerateFrom] preselects the language, tier and layout of an earlier
  /// run and [replaceTrack] the lane it replaces. While a download or job runs nothing changes, so
  /// the sheet shows its progress.
  Future<void> open({TranscriptionScope? scope, CaptionProvenance? regenerateFrom, TrackId? replaceTrack}) async {
    if (state.busy) return;
    final token = ++_openToken;
    _regenerateFrom = regenerateFrom;
    _regenerateTrack = replaceTrack;
    _result = null;
    state = const AutoCaptionsState();
    final TranscriptionSupport support;
    try {
      support = await _service.support();
    } on Object {
      if (mounted && token == _openToken) state = state.copyWith(stage: AutoCaptionsStage.unsupported);
      return;
    }
    if (!mounted || token != _openToken) return;
    if (support is TranscriptionUnsupported) {
      state = state.copyWith(stage: AutoCaptionsStage.unsupported, support: support);
      return;
    }
    final offers = visibleOffers(_service.offers);
    if (!offers.any((o) => o.available)) {
      state = state.copyWith(stage: AutoCaptionsStage.unsupported, support: support, offers: offers);
      return;
    }
    final ready = await _readyModels(offers);
    if (!mounted || token != _openToken) return;
    final project = _editor.state.project;
    final selection = project == null ? const <ItemId>[] : _selectedClips(project);
    final scopeItems = switch (scope) {
      ClipScope(:final item) => [item],
      ItemsScope(:final items) => items.toList(),
      _ => null,
    };
    final clips = scopeItems ?? selection;
    final draft = _initialDraft(offers, ready, clips: clips, preferClip: scopeItems != null, regenerate: regenerateFrom);
    state = state.copyWith(
      stage: AutoCaptionsStage.configure,
      support: support,
      offers: offers,
      readyModels: ready,
      selection: clips,
      audioTracks: project == null ? const [] : _audioTracks(project),
      generatedTrack: replaceTrack ?? (project == null ? null : _generatedTrack(project)),
      draft: draft,
    );
  }

  /// Offers the UI shows: Accurate is hidden when the device does not qualify (D-20).
  static List<SpeechModelOffer> visibleOffers(List<SpeechModelOffer> offers) =>
      [for (final o in offers) if (o.available || o.spec.tier != SpeechModelTier.accurate) o];

  Future<Set<String>> _readyModels(List<SpeechModelOffer> offers) async {
    final ready = <String>{};
    for (final o in offers) {
      try {
        if (await _service.modelStatusOf(o.spec.id) is SpeechModelReady) ready.add(o.spec.id);
      } on Object {
        // Unknown status: treated as not installed.
      }
    }
    return ready;
  }

  AutoCaptionsDraft _initialDraft(
    List<SpeechModelOffer> offers,
    Set<String> ready, {
    required List<ItemId> clips,
    required bool preferClip,
    CaptionProvenance? regenerate,
  }) {
    final available = [for (final o in offers) if (o.available) o];
    SpeechModelTier tier = (available.where((o) => o.recommended).firstOrNull ?? available.first).spec.tier;
    final previous = regenerate == null ? null : SpeechModelCatalog.byId(regenerate.modelId);
    if (previous != null && available.any((o) => o.spec.tier == previous.tier)) tier = previous.tier;
    final presetName = _prefs.captionsDefaultPreset;
    final preset = SegmentationPreset.values.where((p) => p.name == presetName).firstOrNull ?? SegmentationPreset.standard;
    return AutoCaptionsDraft(
      scope: preferClip && clips.isNotEmpty ? CaptionsScopeKind.selection : CaptionsScopeKind.wholeVideo,
      language: regenerate == null ? _defaultLanguage() : _languageOfProvenance(regenerate),
      tier: tier,
      segmentation: regenerate?.segmentation ?? SegmentationSettings(preset: preset),
    );
  }

  SpokenLanguage _defaultLanguage() {
    final last = _prefs.readString(AutoCaptionsPrefKeys.lastLanguage);
    if (last == 'auto') return const AutoLanguage();
    if (last != null && languageForWhisperCode(last) != null) return FixedLanguage(last);
    final device = deviceLanguage;
    return device == null ? const AutoLanguage() : FixedLanguage(device.whisperCode);
  }

  SpokenLanguage _languageOfProvenance(CaptionProvenance p) {
    final l = languageForLocale(p.language);
    return l == null ? _defaultLanguage() : FixedLanguage(l.whisperCode);
  }

  List<ItemId> _selectedClips(EditProject project) {
    final out = <ItemId>[];
    for (final id in _editor.state.selection.items) {
      final loc = project.index.locate(id);
      if (loc == null || loc.item is! MediaClip) continue;
      final kind = project.tracks.firstWhere((t) => t.id == loc.track, orElse: () => project.tracks.first).kind;
      if (kind == TrackKind.video || kind == TrackKind.audio) out.add(id);
    }
    return out;
  }

  List<CaptionAudioTrack> _audioTracks(EditProject project) => [
        for (final t in project.tracks)
          if ((t.kind == TrackKind.video || t.kind == TrackKind.audio) && t.items.any((i) => i is MediaClip))
            CaptionAudioTrack(id: t.id, name: t.name, music: t.audioRole == AudioRole.music),
      ];

  TrackId? _generatedTrack(EditProject project) {
    for (final t in project.tracks.reversed) {
      if (t.kind == TrackKind.subtitle && t.subtitle?.provenance != null) return t.id;
    }
    return null;
  }

  /// Changes the draft (configure step).
  void update(AutoCaptionsDraft Function(AutoCaptionsDraft draft) edit) {
    if (state.stage != AutoCaptionsStage.configure) return;
    state = state.copyWith(draft: edit(state.draft));
  }

  // -----------------------------------------------------------------------------------------------
  // Start, consent, download
  // -----------------------------------------------------------------------------------------------

  /// The request the draft describes.
  TranscriptionRequest request() {
    final draft = state.draft;
    final spec = SpeechModelCatalog.specOf(draft.tier);
    final TranscriptionScope scope;
    if (draft.scope == CaptionsScopeKind.selection && state.selection.isNotEmpty) {
      scope = state.selection.length == 1 ? ClipScope(state.selection.first) : ItemsScope(state.selection.toSet());
    } else {
      final defaults = {for (final t in state.audioTracks) if (!t.music) t.id};
      final chosen = {for (final t in state.audioTracks) if (trackIncluded(t)) t.id};
      scope = TimelineScope(tracks: setEquals(chosen, defaults) ? null : chosen);
    }
    return TranscriptionRequest(
      project: projectId,
      scope: scope,
      language: draft.language,
      modelId: spec.id,
      segmentation: draft.segmentation,
      target: _target(scope),
      timeline: _timeline,
      includeSoundDescriptions: draft.includeSoundDescriptions,
    );
  }

  /// Whether audio track [track] is listened to (Advanced switches; music is off by default).
  bool trackIncluded(CaptionAudioTrack track) =>
      track.music ? state.draft.includedMusic.contains(track.id) : !state.draft.excludedTracks.contains(track.id);

  /// Switches audio track [track] on or off (Advanced).
  void setTrackIncluded(CaptionAudioTrack track, bool on) {
    if (state.stage != AutoCaptionsStage.configure) return;
    final draft = state.draft;
    if (track.music) {
      final music = {...draft.includedMusic};
      on ? music.add(track.id) : music.remove(track.id);
      state = state.copyWith(draft: draft.copyWith(includedMusic: music));
    } else {
      final excluded = {...draft.excludedTracks};
      on ? excluded.remove(track.id) : excluded.add(track.id);
      state = state.copyWith(draft: draft.copyWith(excludedTracks: excluded));
    }
  }

  CaptionTarget _target(TranscriptionScope scope) {
    final track = state.generatedTrack;
    if (track == null || !state.draft.replaceGenerated) return const NewTrackTarget();
    final project = _editor.state.project;
    if (scope is TimelineScope || project == null) return ReplaceTrackTarget(track);
    final ids = switch (scope) {
      ClipScope(:final item) => {item},
      ItemsScope(:final items) => items,
      TimelineScope() => const <ItemId>{},
    };
    TimeRange? range;
    for (final id in ids) {
      final item = project.index.locate(id)?.item;
      if (item == null) continue;
      final r = TimeRange(item.start, item.start + item.duration);
      range = range == null ? r : TimeRange(range.start < r.start ? range.start : r.start, range.end > r.end ? range.end : r.end);
    }
    return range == null ? ReplaceTrackTarget(track) : ReplaceInRangeTarget(track, range);
  }

  /// "Create captions": preflight, then the consent view when the model is missing or damaged,
  /// else the job.
  Future<void> start() async {
    if (state.stage != AutoCaptionsStage.configure || state.starting) return;
    state = state.copyWith(starting: true);
    final request = this.request();
    final spec = SpeechModelCatalog.specOf(state.draft.tier);
    TranscriptionPreflight preflight;
    SpeechModelStatus status;
    try {
      preflight = await _service.preflight(request);
      status = await _service.modelStatusOf(spec.id);
    } on TranscriptionFailure catch (f) {
      if (mounted) _fail(f);
      return;
    } on Object catch (e) {
      if (mounted) _fail(InferenceFailure(e.runtimeType.toString()));
      return;
    }
    if (!mounted || state.stage != AutoCaptionsStage.configure) return;
    final needsDownload = status is! SpeechModelReady || preflight.downloadBytes > 0;
    if (needsDownload) {
      final failure = preflight.failure;
      final diskShort = !preflight.ok && failure is DiskFullFailure;
      if (!preflight.ok && !diskShort && failure != null) {
        _fail(failure);
        return;
      }
      _toConsent(spec, preflight: preflight, corrupt: status is SpeechModelCorrupt, diskShort: diskShort);
      return;
    }
    if (!preflight.ok) {
      _fail(preflight.failure ?? const InferenceFailure('preflight'));
      return;
    }
    _run(request);
  }

  void _toConsent(SpeechModelSpec spec, {required TranscriptionPreflight preflight, required bool corrupt, required bool diskShort}) {
    final includesVad = preflight.downloadBytes == 0 || preflight.downloadBytes > spec.bytes;
    final disclosure = ConsentDisclosure.of(spec, includesVad: includesVad);
    state = state.copyWith(
      stage: AutoCaptionsStage.consent,
      starting: false,
      disclosure: disclosure,
      modelCorrupt: corrupt,
      missingSpaceBytes: diskShort ? disclosure.totalBytes + _downloadMarginBytes : null,
      failure: null,
    );
  }

  static const int _downloadMarginBytes = 64 * 1024 * 1024;

  /// The consent view's "Download": downloads with [consent], then runs the job. The consent is
  /// created only by `ModelConsentView` (ARCH §4.2 rule 8) and is used for this one download.
  Future<void> acceptConsent(UserConsent consent) async {
    if (state.stage != AutoCaptionsStage.consent) return;
    final request = this.request();
    state = state.copyWith(stage: AutoCaptionsStage.downloading, download: null, downloadResumed: false);
    final handle = _task = _tasks()?.begin(EditorTaskKind.download, label: CaptionsStrings.downloadTask, onCancel: cancelDownload);
    final done = Completer<TranscriptionFailure?>();
    var first = true;
    _downloadSub = _service.downloadModel(consent: consent).listen(
      (p) {
        if (!mounted || state.stage != AutoCaptionsStage.downloading) return;
        final resumed = first && p.received > 0 && p.received < p.total;
        first = false;
        state = state.copyWith(download: p, downloadResumed: state.downloadResumed || resumed);
        handle?.progress(p.total > 0 ? p.received / p.total : null);
      },
      onError: (Object e) {
        if (!done.isCompleted) {
          done.complete(e is TranscriptionFailure ? e : const ModelDownloadFailure(ModelDownloadFailureKind.server));
        }
      },
      onDone: () {
        if (!done.isCompleted) done.complete(null);
      },
      cancelOnError: true,
    );
    final failure = await done.future;
    _downloadSub = null;
    if (!mounted || state.stage != AutoCaptionsStage.downloading) return;
    _endTask(handle, failed: failure != null);
    if (failure != null) {
      if (failure is ModelDownloadFailure && failure.kind == ModelDownloadFailureKind.cancelled) {
        state = state.copyWith(stage: AutoCaptionsStage.configure, download: null);
      } else {
        _fail(failure);
      }
      return;
    }
    state = state.copyWith(readyModels: {...state.readyModels, consent.disclosure.modelId}, download: null);
    _run(request);
  }

  /// "Not now" on the consent view: back to the configure step.
  void declineConsent() {
    if (state.stage != AutoCaptionsStage.consent) return;
    state = state.copyWith(stage: AutoCaptionsStage.configure, disclosure: null, missingSpaceBytes: null);
  }

  /// Cancels the download (the partial file is kept, so the next download resumes).
  void cancelDownload() {
    if (state.stage != AutoCaptionsStage.downloading) return;
    unawaited(_service.cancelDownload().catchError((Object _) {}));
    unawaited(_downloadSub?.cancel());
    _downloadSub = null;
    _endTask(_task);
    state = state.copyWith(stage: AutoCaptionsStage.configure, download: null);
  }

  // -----------------------------------------------------------------------------------------------
  // Job
  // -----------------------------------------------------------------------------------------------

  void _run(TranscriptionRequest request) {
    final TranscriptionJob job;
    try {
      job = _service.start(request);
    } on Object catch (e) {
      _fail(e is TranscriptionFailure ? e : InferenceFailure(e.runtimeType.toString()));
      return;
    }
    _rememberLanguage(request.language);
    _job = job;
    _result = null;
    _jobStartedAt = _clock();
    state = state.copyWith(stage: AutoCaptionsStage.running, starting: false, progress: null, failure: null, summary: null);
    _task = _tasks()?.begin(EditorTaskKind.captions, label: CaptionsStrings.jobTask, onCancel: cancel);
    _progressSub = job.progress.listen(_onProgress, onError: (Object _) {});
    unawaited(_await(job));
  }

  void _onProgress(TranscriptionProgress p) {
    if (!mounted || _job == null) return;
    _task?.progress(p.fraction);
    final AutoCaptionsStage stage;
    if (p.phase == TranscriptionPhase.needsLanguage) {
      stage = AutoCaptionsStage.needsLanguage;
    } else if (p.paused == PauseReason.waitingForExport) {
      stage = AutoCaptionsStage.waitingForExport;
    } else {
      stage = AutoCaptionsStage.running;
    }
    // A late sample must not overwrite the language question with an older phase.
    final keepQuestion = state.stage == AutoCaptionsStage.needsLanguage && stage != AutoCaptionsStage.needsLanguage && p.fraction <= (state.progress?.fraction ?? 0);
    if (keepQuestion) return;
    state = state.copyWith(stage: stage, progress: p);
  }

  Future<void> _await(TranscriptionJob job) async {
    try {
      final result = await job.result;
      if (!mounted || !identical(_job, job)) return;
      _endJob();
      _result = result;
      applyResult();
    } on TranscriptionCancelled {
      if (!mounted || !identical(_job, job)) return;
      _endJob();
      state = state.copyWith(stage: AutoCaptionsStage.configure, progress: null);
    } on TranscriptionFailure catch (f) {
      if (!mounted || !identical(_job, job)) return;
      _endJob(failed: true);
      _fail(f);
    } on Object catch (e) {
      if (!mounted || !identical(_job, job)) return;
      _endJob(failed: true);
      _fail(InferenceFailure(e.runtimeType.toString()));
    }
  }

  void _endJob({bool failed = false}) {
    _job = null;
    _jobStartedAt = null;
    unawaited(_progressSub?.cancel());
    _progressSub = null;
    _endTask(_task, failed: failed);
  }

  void _endTask(EditorTaskHandle? handle, {bool failed = false}) {
    if (handle == null) return;
    if (identical(_task, handle)) _task = null;
    try {
      // The Tasks sheet keeps failed rows; the flow shows its own failure, so the row just ends.
      handle.complete();
    } on Object {
      // The tasks controller is gone with the editor.
    }
  }

  /// Answers the low-confidence question with [code] (D-19).
  void provideLanguage(String code) {
    final job = _job;
    if (job == null || state.stage != AutoCaptionsStage.needsLanguage) return;
    job.provideLanguage(code);
    _rememberLanguage(FixedLanguage(code));
    state = state.copyWith(stage: AutoCaptionsStage.running);
  }

  /// Cancels whatever runs: the download, or the job (nothing is added; the checkpoint is kept).
  void cancel() {
    switch (state.stage) {
      case AutoCaptionsStage.downloading:
        cancelDownload();
      case AutoCaptionsStage.running || AutoCaptionsStage.needsLanguage || AutoCaptionsStage.waitingForExport:
        final job = _job;
        _endJob();
        _result = null;
        state = state.copyWith(stage: AutoCaptionsStage.configure, progress: null);
        job?.cancel();
      case AutoCaptionsStage.consent:
        declineConsent();
      default:
        break;
    }
  }

  /// The editor closed (D-20): a job stops and keeps its checkpoint, a download stops and keeps
  /// its partial file.
  void editorClosed() {
    if (!state.busy) return;
    cancel();
  }

  /// Applies the finished result as ONE history entry (`EditorController.apply`).
  void applyResult() {
    final result = _result;
    if (result == null || !mounted) return;
    final p = result.provenance;
    final EditCommand command = switch (result.target) {
      NewTrackTarget() => AddGeneratedCaptionTrack(
          trackName: CaptionsStrings.trackName(p.language),
          language: p.language,
          provenance: p,
          cues: result.drafts,
        ),
      ReplaceTrackTarget(:final track) => ReplaceGeneratedCaptions(track: track, provenance: p, cues: result.drafts),
      ReplaceInRangeTarget(:final track, :final range) => ReplaceGeneratedCaptions(track: track, range: range, provenance: p, cues: result.drafts),
    };
    final applied = _editor.apply(command);
    switch (applied) {
      case EditApplied():
        _result = null;
        state = state.copyWith(stage: AutoCaptionsStage.done, summary: result.summary, progress: null, applyRejection: null);
        toaster?.call(CaptionsStrings.added(result.summary));
        final lane = _editor.state.selection.lane;
        if (lane != null) _editor.openInspector(SubtitlesInspector(track: lane));
      case EditRejected(:final reason):
        state = state.copyWith(stage: AutoCaptionsStage.failed, failure: null, applyRejection: reason, summary: result.summary);
      case EditUnchanged():
        state = state.copyWith(stage: AutoCaptionsStage.failed, failure: null, applyRejection: null, summary: result.summary);
    }
  }

  /// Whether a finished result waits to be applied again ("Try again" after a refused apply).
  bool get hasPendingResult => _result != null;

  void _fail(TranscriptionFailure failure) {
    state = state.copyWith(stage: AutoCaptionsStage.failed, starting: false, failure: failure, applyRejection: null, download: null);
  }

  void _rememberLanguage(SpokenLanguage language) {
    final key = _languageKey(language);
    unawaited(_prefs.writeString(AutoCaptionsPrefKeys.lastLanguage, key));
    if (language is FixedLanguage) {
      final recent = [language.code, ...recentLanguages.where((c) => c != language.code)].take(3).join(',');
      unawaited(_prefs.writeString(AutoCaptionsPrefKeys.recentLanguages, recent));
    }
  }

  // -----------------------------------------------------------------------------------------------
  // Failure actions
  // -----------------------------------------------------------------------------------------------

  /// "Try again" from the failed stage: re-applies a refused result, asks for consent again after a
  /// download failure (consent is per download), or starts again.
  Future<void> retry() async {
    if (state.stage != AutoCaptionsStage.failed) return;
    if (_result != null) {
      applyResult();
      return;
    }
    final failure = state.failure;
    if (failure is ModelDownloadFailure || failure is ModelCorruptFailure || failure is ModelMissingFailure) {
      state = state.copyWith(stage: AutoCaptionsStage.configure, failure: null);
      await start();
      return;
    }
    state = state.copyWith(stage: AutoCaptionsStage.configure, failure: null);
    await start();
  }

  /// "Use Fast" after a memory failure: switches the tier and goes back to configure.
  void useSuggestedTier() {
    final failure = state.failure;
    if (state.stage != AutoCaptionsStage.failed || failure is! InsufficientMemoryFailure) return;
    final tier = failure.suggestedTier;
    if (tier == null) return;
    state = state.copyWith(stage: AutoCaptionsStage.configure, failure: null, draft: state.draft.copyWith(tier: tier));
  }

  /// "Back" from a failure: the configure step with the same choices.
  void back() {
    if (state.stage != AutoCaptionsStage.failed) return;
    _result = null;
    state = state.copyWith(stage: AutoCaptionsStage.configure, failure: null, applyRejection: null);
  }

  /// The run to regenerate from (UX-38), if any.
  CaptionProvenance? get regenerateFrom => _regenerateFrom;

  /// The lane a regenerate run replaces (UX-38), if any.
  TrackId? get regenerateTrack => _regenerateTrack;

  @override
  void dispose() {
    final job = _job;
    _endJob();
    job?.cancel();
    unawaited(_downloadSub?.cancel());
    _downloadSub = null;
    if (_wasBusy) _host.wakelock(false);
    super.dispose();
  }
}

/// Builds the value of `autoCaptionsControllerProvider` for [id]. The provider stays alive while a
/// download or job runs (closing the sheet only hides it); leaving the editor stops the job (D-20).
AutoCaptionsController createAutoCaptionsController(Ref<Object?> ref, ProjectId id) {
  final session = ref.watch(editorSessionProvider(id));
  final editor = ref.watch(editorControllerProvider(id).notifier);
  final service = ref.watch(transcriptionServiceProvider);
  final engine = ref.watch(editorEngineProvider);
  KeepAliveLink? link;
  late final AutoCaptionsController controller;
  controller = AutoCaptionsController(
    projectId: id,
    service: service,
    editor: editor,
    prefs: ref.watch(editorPrefsProvider),
    host: ref.watch(autoCaptionsHostProvider),
    timeline: () => DomainTimelineView(editor.state.project ?? session.committedProject!, access: engine.access),
    tasks: () {
      if (!session.isOpen) return null;
      try {
        return ref.read(tasksControllerProvider(id));
      } on Object {
        return null;
      }
    },
    onBusyChanged: (busy) {
      if (busy) {
        link ??= ref.keepAlive();
      } else {
        link?.close();
        link = null;
      }
    },
  );
  void onAttached() {
    if (!session.attached.value) controller.editorClosed();
  }

  session.attached.addListener(onAttached);
  ref.onDispose(() {
    try {
      session.attached.removeListener(onAttached);
    } on Object {
      // The session's notifier was disposed first.
    }
  });
  return controller;
}
