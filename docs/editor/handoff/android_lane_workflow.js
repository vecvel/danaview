export const meta = {
  name: 'editor-android-lane',
  description: 'Build the Vwish editor Android lane on the Windows laptop (ENG-08, AI-04, AND-02..AND-17) in dependency order, gated on Mac tickets merged from editor-wip, then one review and one fix pass',
  whenToUse: 'On the Windows laptop, on branch editor-android after merging origin/editor-wip. Args: {root, landed, preloaded}; see the comment block below the meta.',
  phases: [
    { title: 'Build', detail: 'Android lane ticket groups in dependency order; groups waiting on Mac tickets are skipped', model: 'opus' },
    { title: 'Review', detail: 'one opus reviewer over the lane files changed since editor-wip', model: 'opus' },
    { title: 'Fix', detail: 'verify and fix confirmed findings, rebuild and retest', model: 'opus' },
  ],
}

/*
 * ANDROID LANE WORKFLOW (Windows laptop)
 * ======================================
 * Builds the Android lane of the Vwish editor (docs/editor/BUILD_PLAN.md): ENG-08, AI-04 and
 * AND-02..AND-17. One builder agent per ticket group, then one reviewer and one fixer. The Mac
 * keeps every other ticket. Lane plan: ANDROID_LANE.md. Windows setup and pitfalls:
 * WINDOWS_SETUP.md. Ticket status at hand-off time: BUILD_STATE.md (all in docs/editor/handoff/).
 * The meta block stays first because the Workflow tool requires the script to start with it.
 *
 * BEFORE A RUN (the "lead" is the Windows Claude Code session that calls Workflow)
 *   1. Get the Mac's latest work onto the lane branch:
 *        git fetch origin
 *        git switch editor-android      (first time: git switch -c editor-android origin/editor-wip)
 *        git merge origin/editor-wip
 *      Start from a clean tree, or from leftovers of an interrupted run that you want resumed.
 *   2. Decide which Mac tickets are in the tree now and pass them as args.landed. Ask the owner,
 *      or read BUILD_STATE.md and the hand-off notes the Mac pushes. If you're unsure about a
 *      ticket, leave it out. The groups that need it just wait.
 *   3. Close anything heavy (Android Studio builds, a second emulator).
 *
 * RUN
 *   Workflow({
 *     scriptPath: 'C:/Users/<you>/Desktop/vwish_player/docs/editor/handoff/android_lane_workflow.js',
 *     args: {
 *       root: 'C:/Users/<you>/Desktop/vwish_player',   // required: repo root, forward slashes
 *       landed: ['ENG-09'],                              // Mac tickets merged into this tree
 *       preloaded: {},                                   // finished groups, see RESUME
 *       // optional: only: ['ai-android'], maxParallel: 2, review: true
 *     },
 *   })
 *
 * ARGS
 *   root         Required. Absolute repo root on this machine, e.g. 'C:/Users/<you>/Desktop/vwish_player'.
 *   landed       Ticket ids merged into this working tree from editor-wip. These are the Mac gates:
 *                ENG-09 (eng08), ENG-06 (every AND group), API-04 (and-m3-text),
 *                ENG-02 (and-m3-preview), ENG-03 (and-m4-services) and ENG-04 (and-m4-export).
 *                A group runs only when all of its gates are listed. Otherwise the group, and every
 *                group that depends on it, is logged as 'waiting for Mac: ...' and skipped.
 *                A lane group whose own tickets are all listed (e.g. ENG-08 finished on the Mac)
 *                counts as finished.
 *   preloaded    {groupId: result} for groups that are already finished and committed. They are
 *                not re-run, and their hand-off goes to the groups that depend on them. A result
 *                can be a builder's returned object (from this script's preloadForNextRun, or from
 *                journal.jsonl), a plain hand-off string, or true.
 *   only         Optional list of group ids to run this time. Others are skipped unless preloaded.
 *   maxParallel  Optional number of builders at once (default 2, max 4). They share one Gradle
 *                module and one emulator.
 *   review       Optional. false skips the review and fix agents.
 *
 * GROUPS            tickets                          Windows deps                          Mac gates
 *   eng08           ENG-08                           -                                     ENG-09
 *   ai-android      AI-04                            -                                     - (AI-03 done)
 *   and-m2a         AND-02, AND-03, AND-04, AND-05   -                                     ENG-06
 *   and-m2b         AND-06, AND-07                   and-m2a                               (ENG-06)
 *   and-m3-render   AND-08                           -                                     ENG-06
 *   and-m3-text     AND-09                           -                                     ENG-06, API-04
 *   and-m3-preview  AND-17, AND-10, AND-16           and-m3-render, and-m3-text, and-m2b   ENG-02
 *   and-m4-services AND-13, AND-14, AND-15           -                                     ENG-03
 *   and-m4-export   AND-11                           and-m3-render, and-m3-text,           ENG-04
 *                                                    and-m3-preview
 *   and-m5          AND-12                           and-m4-export                         (ENG-04)
 *   A gate in parentheses comes from a Windows dependency. Cross-machine order: ENG-08 (here) must
 *   land on editor-wip before the Mac's ENG-06, and ENG-06 must land here before any AND ticket.
 *   Builders share one emulator through a lock directory at <root>/build/vwish_locks/emulator
 *   (gitignored). Delete it if a killed run leaves it behind.
 *
 * AFTER A RUN (the lead does this; builder agents never change git state)
 *   - The result has commitPlan: one entry per ticket with a commit message and its files.
 *     Commit each ticket on its own, e.g.
 *       git add <files> && git commit -m "feat(editor): AND-02 Android probe, compatibility, ..."
 *     Commit the fixer's changes the same way, using the message in their commitPlan entry. Never
 *     add a co-author trailer (owner rule). Never commit android/key.properties, *.jks or
 *     local.properties.
 *   - Push editor-android and tell the owner which tickets landed. The Mac session merges
 *     editor-android into editor-wip. ENG-08 is urgent because it gates the Mac's ENG-06.
 *   - Pass forMac (defects against Mac tickets, ENG-06 inputs, needed [INTEGRATION] changes) to
 *     the owner.
 *   - For the next run, copy preloadForNextRun into args.preloaded and add newly landed Mac
 *     tickets to args.landed. Groups with a partial or blocked ticket are left out of
 *     preloadForNextRun, so the next run resumes them.
 *
 * RESUME
 *   - After a pause, a kill or a script edit, run Workflow({scriptPath, resumeFromRunId: '<runId>',
 *     args: <same args>}). Cached results come back for the unchanged prefix of agent() calls and
 *     the rest runs live. The same script with the same args is a 100% cache hit.
 *   - Groups run concurrently, so a resume reuses results only up to the first agent() call that
 *     didn't finish. Groups that finished after it would run again. To avoid that, start a new run
 *     with the finished groups in args.preloaded: take each finished builder's result from
 *     journal.jsonl in the old run's transcript directory, or from preloadForNextRun.
 *   - Builders follow a resume rule: they check what already exists for their tickets and
 *     continue from there. Re-running a half-finished group is safe; it only costs tokens.
 */

// ---------- args ----------

function parseMaybeJson(value, name) {
  if (typeof value !== 'string') return value
  try {
    return JSON.parse(value)
  } catch (e) {
    throw new Error(`android_lane_workflow: args${name ? '.' + name : ''} must be JSON or an object, got an unparseable string`)
  }
}

const A = parseMaybeJson(args, '') || {}
if (!A.root || typeof A.root !== 'string') {
  throw new Error("android_lane_workflow: args.root is required (absolute repo root with forward slashes), e.g. Workflow({scriptPath: '<repo>/docs/editor/handoff/android_lane_workflow.js', args: {root: 'C:/Users/<you>/Desktop/vwish_player', landed: ['ENG-09'], preloaded: {}}})")
}
const ROOT = A.root.replace(/\\/g, '/').replace(/\/+$/, '')

function toIdList(value, name) {
  if (value === undefined || value === null) return []
  if (typeof value === 'string') return value.split(/[\s,]+/).filter(Boolean)
  if (!Array.isArray(value)) throw new Error(`android_lane_workflow: args.${name} must be an array of ids`)
  return value.map((s) => String(s).trim()).filter(Boolean)
}

const LANDED = new Set(toIdList(A.landed, 'landed').map((s) => s.toUpperCase()))
const ONLY = A.only ? new Set(toIdList(A.only, 'only')) : null
const MAX_PARALLEL = Math.max(1, Math.min(4, Number.isFinite(Number(A.maxParallel)) && A.maxParallel ? Math.floor(Number(A.maxParallel)) : 2))
const RUN_REVIEW = A.review !== false
const RAW_PRELOADED = parseMaybeJson((A && A.preloaded) || {}, 'preloaded') || {}
const LOCK = `${ROOT}/build/vwish_locks/emulator`

// ---------- tickets, ownership ----------

const TITLES = {
  'ENG-08': 'Android plugin glue, engine core, Gradle, manifest and native service placeholders',
  'AI-04': 'whisper Android native build',
  'AND-02': 'Android probe, compatibility, device profile, capabilities',
  'AND-03': 'Android thumbnails and disk cache',
  'AND-04': 'Android PCM decoder, waveforms, speech audio extraction',
  'AND-05': 'Android job registry, proxy job and registry',
  'AND-06': 'Android freeze frame and source-frame cache',
  'AND-07': 'Android reverse rendition job',
  'AND-08': 'Android plan reader, ParamSnapshot, composition mapper, gating, speed and gain providers',
  'AND-09': 'Android GL effects, shaders, LUT and sprite textures',
  'AND-17': 'Android paused-frame renderer, layer GL compositor and structural debounce',
  'AND-10': 'Android preview session: SurfaceProducer, clock, seek/scrub, transients, redraw, quality, lifecycle',
  'AND-16': 'Android contingency preview engine (conditional: only on an AND-01 no-go)',
  'AND-11': 'Android export: coordinator, Transformer, encoder settings, hardware selector, active store',
  'AND-13': 'Android voice recorder',
  'AND-14': 'Android pickers, URI grants (media access), permissions',
  'AND-15': 'Android external drop target',
  'AND-12': 'Android export foreground service, notification, background guard, MediaStore, file handoff',
}

const OWNS_LEGEND = `Path prefixes:
K/ = packages/vwish_editor_engine/android/src/main/kotlin/com/vecvel/vwish/editor/engine/
T/ = packages/vwish_editor_engine/android/src/test/kotlin/com/vecvel/vwish/editor/engine/
A/ = packages/vwish_editor_engine/android/src/androidTest/kotlin/com/vecvel/vwish/editor/engine/
E/ = packages/vwish_editor_engine/
(a path ending in / is the whole directory)`

// Summary of the BUILD_PLAN §6 owns lists (BUILD_PLAN wins if they differ).
const OWNS = {
  'ENG-08': ['E/android/build.gradle.kts', 'E/android/lint.xml', 'E/android/src/main/AndroidManifest.xml', 'E/android/src/main/res/xml/vwish_editor_file_paths.xml', 'K/VwishEditorEnginePlugin.kt', 'K/glue/', 'K/core/EngineContext.kt', 'K/core/ErrorCodes.kt', 'K/core/EventHub.kt', 'K/core/EngineThreads.kt', 'K/core/Paths.kt', 'T/glue/', '+ D-33 placeholders (header // OWNER: <ticket>) for every Android service file of ARCH §4.4'],
  'AI-04': ['packages/vwish_whisper/android/build.gradle.kts', 'packages/vwish_whisper/android/src/main/AndroidManifest.xml', 'packages/vwish_whisper/src/cmake/android.cmake', 'packages/vwish_whisper/src/vw_exports.map', 'scripts/ci/editor/check_native_libs.sh'],
  'AND-02': ['K/media/Probe.kt', 'K/media/Compatibility.kt', 'K/core/DeviceProfile.kt', 'K/core/Capabilities.kt', 'T/probe/', 'A/probe/'],
  'AND-03': ['K/media/ThumbnailService.kt', 'K/media/DiskCache.kt', 'T/thumbs/', 'A/thumbs/'],
  'AND-04': ['K/media/PcmDecoder.kt', 'K/media/WaveformService.kt', 'K/media/SpeechAudioExtractor.kt', 'T/audio/', 'A/audio/'],
  'AND-05': ['K/core/JobRegistry.kt', 'K/media/ProxyJob.kt', 'K/media/ProxyRegistry.kt', 'T/proxy/', 'A/proxy/'],
  'AND-06': ['K/media/FreezeFrameJob.kt', 'K/preview/SourceFrameCache.kt', 'T/freeze/', 'A/freeze/'],
  'AND-07': ['K/media/ReverseJob.kt', 'T/reverse/', 'A/reverse/'],
  'AND-08': ['K/plan/', 'K/composition/', 'T/composition/', 'A/composition/'],
  'AND-09': ['K/effects/', 'E/android/src/main/assets/vwish_shaders/', 'T/effects/', 'A/effects/'],
  'AND-17': ['K/preview/PausedFrameRenderer.kt', 'K/preview/LayerCompositorGl.kt', 'K/preview/StructuralDebouncer.kt', 'A/paused/'],
  'AND-10': ['K/preview/PreviewSession.kt', 'K/preview/PreviewSessionManager.kt', 'K/preview/SurfaceBridge.kt', 'K/preview/SeekController.kt', 'K/preview/QualityGovernor.kt', 'A/preview/', 'E/example/integration_test/android_preview_test.dart'],
  'AND-16': ['K/preview/fallback/', 'A/fallback/'],
  'AND-11': ['K/export/ExportCoordinator.kt', 'K/export/TransformerExport.kt', 'K/export/EncoderSettings.kt', 'K/export/HardwareEncoderSelector.kt', 'K/export/ActiveExportStore.kt', 'T/export/', 'A/export/'],
  'AND-13': ['K/recording/VoiceRecorder.kt', 'A/recording/'],
  'AND-14': ['K/platform/MediaPicker.kt', 'K/platform/MediaAccess.kt', 'K/platform/Permissions.kt', 'A/platform/'],
  'AND-15': ['K/platform/DropTarget.kt', 'A/drop/'],
  'AND-12': ['K/export/ExportService.kt', 'K/export/ExportNotification.kt', 'K/platform/BackgroundGuard.kt', 'K/platform/MediaStoreSaver.kt', 'K/platform/FileHandoff.kt', 'E/android/src/main/res/drawable/vwish_export_notification.xml', 'A/service/'],
}

function ownsText(tickets) {
  return tickets.map((t) => `${t}: ${(OWNS[t] || []).join(', ')}`).join('\n')
}

// ---------- context for every agent ----------

const CONTEXT = `
You are an engineer on Vwish Player (Flutter 3.44.2 / Dart 3.12 monorepo at ${ROOT}) working the ANDROID LANE on the owner's WINDOWS laptop (32 GB RAM, no Xcode). We are building a production video editor for iOS + Android per the FINAL docs:
- ${ROOT}/docs/editor/ARCHITECTURE.md (source of truth; decisions D-1..D-44; read only the sections your tickets cite)
- ${ROOT}/docs/editor/BUILD_PLAN.md (§1 how to work a ticket, §2 ownership rules, §5 dependency index, §6 ticket bodies with acceptance criteria, §7 shared/integration file register)
- ${ROOT}/docs/editor/spikes/AND-01.md (Android spike: verdict, measurements, what ENG-06 applies, rules carried into the AND tickets; read it before any AND ticket)
- ${ROOT}/docs/editor/handoff/ (ANDROID_LANE.md lane plan, WINDOWS_SETUP.md Windows pitfalls, BUILD_STATE.md status and hand-off facts of finished tickets; read the parts relevant to you)

SPLIT (decided by the owner; do not re-litigate): the build runs on two machines. The Mac keeps everything except the Android lane: all core/UI/UX/integration/QA tickets, all iOS tickets, ENG-01..07, ENG-09, ENG-02/03/04, ENG-06 (integration freeze), AI-05, IOS-01 and AND-01. This Windows laptop owns ONLY the Android lane: ENG-08, AI-04, AND-02..AND-17. Windows can never build or test iOS: never edit iOS/Swift/podspec files and never claim an iOS criterion. Cross-machine gates: ENG-08 (Windows) lands before ENG-06 (Mac); ENG-06 lands before AND-02..AND-17. Your group was started only after its Mac-side gates were merged into this working tree. If something you need from a Mac ticket is missing or wrong, report it in forMac and deferred as a defect against that ticket; never edit its files.

GIT: the lane works on branch editor-android (from editor-wip, github.com/vecvel/vwish). Do NOT run state-changing git commands (no add, commit, stash, checkout/switch, reset, restore, merge, rebase, pull, push, clean, branch, tag, config). Read-only git (status, diff, log, show, ls-files) is fine. The lead commits each ticket after this run as 'feat(editor): <TICKET> <title>' with no co-author trailer, so report exact per-ticket file lists. Never create or commit secrets (android/key.properties, *.jks) or machine files (local.properties).

OWNERSHIP: only create/edit files your tickets own (BUILD_PLAN §2 and the §6 owns lists) plus placeholders whose header says '// OWNER: <your ticket>' (replace the placeholder). Shared files in §7 get minimal targeted insertions only (re-read right before editing; never rewrite the whole file). The Pigeon surface (packages/vwish_editor_engine/pigeons/, lib/src/pigeon/, android/.../pigeon/), the Kotlin glue (android/.../glue/), build.gradle.kts and lint.xml are frozen after ENG-06. Service tickets implement the service classes the glue already calls. Never run Pigeon generation and never change dependency versions (Media3 is pinned to 1.11.1; upgrading means rerunning AND-01). If a Pigeon/glue/Gradle/manifest change is truly needed, stop and report it in forMac as needing a lead-approved [INTEGRATION] ticket. Other builders may be working IN PARALLEL in this same working tree on disjoint files and compiling the same Gradle module. If a build fails because of another ticket's half-written file, or Gradle reports a lock held by another build, wait a minute and retry; never edit their files.

RESUME RULE: always inspect what already exists for your tickets first (git status/diff, your owned paths, placeholders); an earlier attempt may have been cut off. Continue from there; never redo finished work.

DOWNLOAD RULE: no internet downloads except normal package-manager resolution (pub, Gradle/Maven). Never download speech models, media or tools, and never install SDK components or software. Use fake HTTP servers and test fixtures. Reuse ENG-05's committed fixtures (packages/vwish_editor_engine/test_fixtures/, packed into the test APK by example/android/vwish_test_harness.gradle). Generate any new media locally with ffmpeg from PATH (not /opt/homebrew/bin/ffmpeg) or MediaCodec, inside your owned test directories, and record its provenance. whisper.cpp v1.9.4 is vendored at packages/vwish_whisper/third_party/whisper.cpp; never modify vendored sources.

DEVICE RULE: there is no physical Android device. Verification runs as JVM unit tests and on the Pixel_9_Pro_XL_API_35 emulator (API 35, x86_64). Mark acceptance criteria that need a real device, an emulator that is not installed (e.g. API 29/34, tablet), a named device class (Pixel 7a, 4 GB, low/mid tier) or real-hardware performance 'deferred: no device available' (or 'deferred: <emulator> not installed'), with the reason. Never fake them. Report emulator measurements as emulator measurements, never as device numbers. A test that is skipped, @Ignore'd or asserts nothing is not a pass.

OWNER DEFAULTS (D-43, owner defaults 2026-10-08, revisable): Android editor gate API 29 + GLES3 + 2 GB RAM (devices below 3 GB run the minimal tier, D-40); no auto captions on armeabi-v7a; Android editor data excluded from backup.

TIME RULE (BUILD_PLAN §1.7, ARCH §5, D-35): any code that turns a platform clock or presentation time into a frame uses frameIndexNearest and evaluates at timeOfFrame(k); boundaries are anchored at P(k) = round(k*1e6/gridFps); never compare a raw platform microsecond value with a plan edge. Every Media3 file starts with @file:OptIn(UnstableApi::class, ExperimentalApi::class). Nothing logs media paths, transcript text or user content.

WINDOWS: your Bash tool runs Git Bash. Run the repo's .sh scripts with Git Bash (e.g. bash scripts/ci/editor/android_unit.sh). Use PowerShell (powershell -NoProfile -Command "...") for other Windows-native work: gradlew.bat, starting/stopping the emulator, process checks. Use forward slashes in paths (C:/Users/...; Git Bash also accepts /c/Users/...). Files keep LF line endings (.gitattributes: * text=auto eol=lf; only .bat/.cmd/.ps1 are CRLF). Never convert line endings and never write absolute local paths into committed files. Android SDK: $ANDROID_HOME (default C:/Users/<you>/AppData/Local/Android/Sdk). The CI scripts only probe macOS/Linux default SDK paths, so pass ANDROID_HOME on the command line if it is unset. NDKs 27.0.12077973 and 28.2.13676358 are under <sdk>/ndk/. CMake 3.22.1 and Ninja are under <sdk>/cmake/3.22.1/bin/ (cmake.exe, ninja.exe). llvm-readelf is under <ndk>/toolchains/llvm/prebuilt/windows-x86_64/bin/. JDK 21 is installed; keep the JVM 17 source/target pins. If a Windows-specific problem blocks you (path length, a file locked by a Gradle daemon, a missing tool), report the ticket as blocked with the exact error. Do not change system settings, the registry, PATH or the global git config.

EMULATOR: one shared emulator, Pixel_9_Pro_XL_API_35. Up to ${MAX_PARALLEL} builders run at once, so serialize instrumented runs with the lock directory ${LOCK}:
- Take the lock with mkdir -p ${ROOT}/build/vwish_locks && mkdir ${LOCK}. mkdir is atomic. If it fails, another builder is testing: wait and retry.
- Write your group id into ${LOCK}/owner and touch that file before each long run. A lock whose owner file is untouched for 60 minutes is stale; remove it.
- Remove the lock right after your connected test run.
- If adb devices shows no emulator, start it headless in the background: <sdk>/emulator/emulator.exe -avd Pixel_9_Pro_XL_API_35 -no-window -no-audio -no-boot-anim -no-snapshot-save. Wait for adb wait-for-device and getprop sys.boot_completed = 1.
- When your group is finished and no lock exists, stop the emulator (adb emu kill).
- Never start a second emulator.

VERIFICATION (every group; report the commands and their final result lines):
- The engine builds through the example host (packages/vwish_editor_engine/example/android: gradlew.bat :vwish_editor_engine:assembleDebug, or flutter build apk --debug in the example).
- JVM unit tests: :vwish_editor_engine:testDebugUnitTest. Scope them with --tests while iterating; run the full suite once at the end.
- Lint (:vwish_editor_engine:lintDebug), which enforces the Media3 opt-in.
- Instrumented tests on the emulator, under the lock: :vwish_editor_engine:connectedDebugAndroidTest scoped with -Pandroid.testInstrumentationRunnerArguments.package=com.vecvel.vwish.editor.engine.<topic>.
- At the end of the group, once each: scripts/ci/editor/android_unit.sh and android_emulator.sh (the latter under the lock).
- flutter analyze and flutter test for any Dart you touch.
When done, every acceptance criterion of your tickets must be met or explicitly listed in deferred with the reason.
`

const RESULT_SCHEMA = {
  type: 'object',
  properties: {
    tickets: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          id: { type: 'string' },
          status: { type: 'string', enum: ['done', 'partial', 'blocked', 'not_needed'] },
          notes: { type: 'string' },
          files: { type: 'array', items: { type: 'string' }, description: 'repo-relative paths (forward slashes) created or changed for this ticket, for its own commit' },
        },
        required: ['id', 'status', 'notes', 'files'],
      },
    },
    filesChanged: { type: 'array', items: { type: 'string' } },
    verification: { type: 'string', description: 'Gradle build / JVM test / lint / emulator commands run and their final result lines' },
    deferred: { type: 'array', items: { type: 'string' }, description: 'criteria not met, each with the reason (e.g. deferred: no device available)' },
    handoff: { type: 'string', description: 'facts later tickets need (class/API names, decisions, measured emulator numbers)' },
    forMac: { type: 'string', description: 'what the Mac lead must know or do: inputs for ENG-06, [VERIFY] answers for ARCHITECTURE.md, defects against Mac tickets, needed [INTEGRATION] changes; "none" if nothing' },
  },
  required: ['tickets', 'filesChanged', 'verification', 'deferred', 'handoff', 'forMac'],
}

// Ticket groups (related tickets in one agent to avoid re-reading the same code and docs).
// deps = Windows groups that must finish first; external = Mac tickets that must be in args.landed.
const GROUPS = [
  {
    id: 'eng08', tickets: ['ENG-08'], deps: [], external: ['ENG-09'], model: 'opus',
    note: `Thin Kotlin glue for every host API against ENG-01's generated Pigeon Kotlin (Mac-owned, read only). Write the engine core: EngineContext, ErrorCodes, EventHub, EngineThreads (vwish-preview, vwish-gl, vwish-export, vwish-jobs, vwish-io) and Paths. Create D-33 placeholders for every Android service file of ARCH §4.4 (AND-02..AND-17, incl. preview/{PausedFrameRenderer,LayerCompositorGl,StructuralDebouncer} and an empty preview/fallback/ package) returning notSupportedOnDevice, each with the header '// OWNER: <ticket>'. Also build.gradle.kts and lint.xml per the ticket spec, and the plugin manifest per ARCH §20.4. ENG-01 left minimal placeholders in build.gradle.kts, AndroidManifest.xml and VwishEditorEnginePlugin.kt (§7 order ENG-01 -> ENG-08 -> ENG-06); replace them. Build to the ENG-08 spec only. The AND-01 changes in docs/editor/spikes/AND-01.md §6 (minSdk 29, JNI shim, extra Media3 artifacts, Kotlin opt-in flag) are applied by ENG-06 on the Mac: don't pre-apply them, but keep the files easy to amend. The ENG-09 example host (packages/vwish_editor_engine/example) is the harness: capabilities() must round-trip on the emulator through it, and the example's manifest merge must be clean. Lint must fail on a negative fixture missing the opt-in (keep that fixture out of the shipped source set). ARCHITECTURE.md is ENG-06's file. Put the V-N14 outcome, the glue class list, the placeholder list and every Gradle/manifest fact ENG-06 needs in forMac and handoff. The Mac may have started ENG-08 before the split, so apply the resume rule.`,
  },
  {
    id: 'ai-android', tickets: ['AI-04'], deps: [], external: [], model: 'opus',
    note: `whisper Android native build (ai.md §4.3). AI-03 is DONE: its C shim, src/CMakeLists.txt and host tests in packages/vwish_whisper/src/ are read-only for you, as are the vendored whisper.cpp sources. Gradle externalNativeBuild with src/cmake/android.cmake produces:
- libvwish_whisper.so: arm64-v8a armv8-a baseline, plus x86_64
- libvwish_whisper_v82.so: arm64-v8a armv8.2-a+fp16+dotprod (AI-07's Dart loader picks it at runtime from getauxval(AT_HWCAP); record the exact names and selection facts in handoff)
Build settings: c++_static; 16 KB page alignment (pass -Wl,-z,max-page-size=16384 explicitly so it also holds on NDK 27); only vw_* exported via vw_exports.map; no armeabi-v7a (owner default D-43); -O3; no OpenMP. Use the SDK CMake 3.22.1 (version = "3.22.1") with its Ninja, and the NDK the build pins (flutter.ndkVersion or an explicit ndkVersion), which must be one of the installed 27.0.12077973 / 28.2.13676358; do not install another. Answer V-A8 (is the SDK's CMake 3.22.1 sufficient) in handoff and forMac; ARCHITECTURE.md is not your file.
check_native_libs.sh follows the scripts/ci/editor/README.md script contract and must run in Git Bash on Windows, in bash 3.2 on macOS and on Linux CI:
- Locate llvm-readelf under the NDK's toolchains/llvm/prebuilt/<windows-x86_64|darwin-x86_64|linux-x86_64>/bin (.exe on Windows).
- Unpack the AAB/APK with a tool present on all three platforms, and document the choice.
- Check: ABIs present, no armeabi-v7a whisper library, 16 KB LOAD alignment, exported symbols exactly vw_*, size <= 3 MB per .so.
Prove it against an AAB you built. The root app gets vwish_whisper only at INT-04 (Mac, later). If no in-repo host includes the plugin yet, build a throwaway host outside the repo (e.g. in the temp dir) that depends on packages/vwish_whisper by path, and record that the app-level check repeats at INT-04/INT-05. The release keystore is not on this machine, so use debug signing. Check that there is no libc++_shared conflict with media_kit where a host includes both. Native compiles are CPU-heavy: cap parallel jobs at 8.`,
  },
  {
    id: 'and-m2a', tickets: ['AND-02', 'AND-03', 'AND-04', 'AND-05'], deps: [], external: ['ENG-06'], model: 'opus',
    note: `Android native media services on Media3 1.11.1, as ENG-06 froze build.gradle.kts and lint.xml. Read AND-01.md §6-7 (AND-02: HDR editability depends on GL_EXT_YUV_target and a 10-bit decoder; V-N5 is deferred to a device) and the ARCH §13.3/§15 rows these tickets cite. They follow the same contracts as IOS-02..IOS-05: read those iOS ticket bodies, and the iOS code if present, for parity only; never edit iOS files. Use ENG-05's fixtures (incl. MKV/WebM). Unit-test AND-02's gate and tier logic with injected profiles. Run the GLES 3 and maxTextureSize checks on the API 35 emulator; the API 29 run is 'deferred: API 29 emulator not installed'. Record performance criteria (cache hit/miss times, >= 60x realtime) as emulator numbers and defer the device-tier criterion. Order: AND-02 first (the others depend on it), then AND-03, AND-04 and AND-05.`,
  },
  {
    id: 'and-m2b', tickets: ['AND-06', 'AND-07'], deps: ['and-m2a'], external: [], model: 'opus',
    note: `AND-06: FrameExtractor with SeekParameters.EXACT, PNG still at the Dart path, SourceFrameCache. LayerLookEffect overrides apply once AND-09 lands; it may be built in parallel right now. Use it if it is complete in the tree, otherwise return unprocessed frames as the ticket allows and say so in handoff. AND-07: chunked reverse with the same algorithm and preflight as IOS-07 (read it for parity only). Use AND-04's PcmDecoder and AND-05's JobRegistry from the hand-off below.`,
  },
  {
    id: 'and-m3-render', tickets: ['AND-08'], deps: [], external: ['ENG-06'], model: 'opus',
    note: `Plan reader, ParamSnapshot and CompositionMapper. ARCH §11 overrides native.md §4.2: the plan is a flat, fully lowered layer list. AND-01 recorded NO-GO for CompositionPlayer as the preview engine (AND-16 active) and GO for Transformer export. Read AND-01.md and ENG-06's ARCH §13.3 record for what the mapper must serve (Transformer export for AND-11, and the plan/ParamSnapshot types that AND-16's slot players, AND-17 and AND-10 consume). Apply AND-01.md §7:
- Gaps in video sequences are transparent image items at the output fps, not addGap.
- Clip starts use the rule-frame PTS (the ε mechanism AND-01 chose).
- Items faster than 1x use EditedMediaItem.setFrameRate(gridFps).
- setDurationUs is the full source duration.
Anchor every item and gap boundary at P(k). Contract fixtures and vectors come from packages/vwish_editor_core/test/fixtures (frame_grid.json incl. androidSeekMsRounding, grid_cuts_30fps.json, expected_active.json, packing and classification vectors), plus API-03's render-math vectors in packages/vwish_editor_engine_api. Read them; never edit them. Per-layer effect lists reference AND-09 classes; AND-09 may be built in parallel right now, so code against its ENG-08 placeholders/public names.`,
  },
  {
    id: 'and-m3-text', tickets: ['AND-09'], deps: [], external: ['ENG-06', 'API-04'], model: 'opus',
    note: `GL effects in GLSL ES 1.00 per ARCH §13.3 'GL effects' and §11.6 math. Render-math vectors and parity goldens come from API-03, and the .vsprite codec from API-04 (both in packages/vwish_editor_engine_api, Mac-owned, read only). Expose a small ShaderPrograms API that AND-17's LayerCompositorGl, the PausedFrameRenderer and AND-16 reuse. Only the vwish-gl thread touches GL (assert it), and resources are released on effect release. Run the goldens on the API 35 emulator; its GPU path differs from devices. If a golden misses only because of emulator rendering, record the measured error and defer the device check; never loosen a tolerance silently. GL timer-query numbers from the emulator are emulator numbers; the 1080p <= 8 ms mid-device budget is deferred: no device available.`,
  },
  {
    id: 'and-m3-preview', tickets: ['AND-17', 'AND-10', 'AND-16'], deps: ['and-m3-render', 'and-m3-text', 'and-m2b'], external: ['ENG-02'], model: 'opus',
    note: `Order: AND-17, then AND-10, then AND-16. AND-01 reported NO-GO for CompositionPlayer preview. Read docs/editor/spikes/AND-01.md (§1-2 and §5-7) and what ENG-06 recorded (ARCH §13.3/§13.4 and AND-16's ticket status).
If ENG-06 activated AND-16:
- AND-10 ships the PreviewSession shell, SurfaceBridge, SeekController, QualityGovernor, PreviewSessionManager and the PreviewBackend interface, and meets its playback criteria through AND-16's MultiPlayerBackend.
- The MultiPlayerBackend has one ExoPlayer per packing slot into a SurfaceTexture (OES), plus audio slot players. AND-17's LayerCompositorGl composites them on a Choreographer frame clock. Drift above half a frame is corrected by seeking the late player.
- AND-01's prototype in spikes/android_engine is the reference (read only).
- AND-16 also needs the JNI shim (android/src/main/cpp/, AND-01 §6.3). Use the owner ENG-06/BUILD_PLAN records. If none is recorded, AND-16 creates it and says so in forMac, so the lead can update BUILD_PLAN §6/§7.
If ENG-06 recorded GO instead, close AND-16 with status not_needed, citing AND-01's report.
With any CompositionPlayer, detach with clearVideoSurface(surface); the no-arg overload throws in 1.11.1. Report the owner's D-43e sign-off status (AND-01 §7, as recorded in ARCHITECTURE) in forMac, and build anyway. example/integration_test/android_preview_test.dart drives MobileEditorEngine and ENG-02's mobile_preview_session.dart on the emulator. Record emulator numbers for the ARCH §13.4 mid/low device budgets; the device criteria are deferred: no device available.`,
  },
  {
    id: 'and-m4-services', tickets: ['AND-13', 'AND-14', 'AND-15'], deps: [], external: ['ENG-03'], model: 'opus',
    note: `Recorder, pickers/URI grants/permissions and drop target behind the calls ENG-03's Dart glue makes (mobile_jobs.dart, mobile_recorder.dart and the platform services; Mac-owned). Implement the service classes ENG-08's glue already calls. AND-13: the emulator mic is virtual; verify the WAV format, that an interruption keeps a valid file, and the denied/permanently-denied states; latency is an emulator number. AND-14: Photo Picker and V-D2 (persistence across relaunch, grant budget) on the API 35 emulator; API < 33 permission flows are deferred unless such an emulator exists; quickHash must equal the core fixtures. AND-15: synthesized DragEvents with ClipData from a test ContentProvider; the cross-app tablet drag is a manual checklist item, deferred: no tablet device/emulator available.`,
  },
  {
    id: 'and-m4-export', tickets: ['AND-11'], deps: ['and-m3-render', 'and-m3-text', 'and-m3-preview'], external: ['ENG-04'], model: 'opus',
    note: `Transformer export (AND-01: GO). ENG-04's mobile_export.dart (Mac) is the Dart side. Build export compositions with AND-08's mapper (target export) and AND-09's SpriteBandEffect. Define the ActiveExportStore format here; AND-12's service writes its detached records later (D-39). Test on the emulator: V-N13 (hvc1 tag) and V-N24 (no-audio, all-muted and images/text-only fixtures get a silent AAC 48 kHz stereo track). Record which encoder actually ran; the emulator may only have software HEVC, so defer the hardware-encoder criteria. Exercise the portrait retry path with an injected refusal. Check 'interrupted after process death' with am kill or force-stop from an instrumented test. Preview suspension on minimal/low/mid tiers goes through AND-10's PreviewSessionManager.`,
  },
  {
    id: 'and-m5', tickets: ['AND-12'], deps: ['and-m4-export'], external: [], model: 'opus',
    note: `ExportService foreground service: type mediaProcessing on API 35+, dataSync on 29-34. It shows a determinate progress notification with a Cancel action that works with the activity destroyed; API 35 onTimeout -> interrupted. BackgroundGuard leases live in the same service. MediaStoreSaver uses RELATIVE_PATH Movies/Vwish and IS_PENDING. FileHandoff uses ACTION_CREATE_DOCUMENT and ACTION_SEND via the FileProvider '<applicationId>.vwish.editor.files' declared in ENG-08's manifest. Implement detached completion (D-39) with AND-11's ActiveExportStore. Only the API 35 emulator exists: the API 29/34 FGS-type checks are 'deferred: API 29/34 emulators not installed'. Run the swipe-from-recents case with UiAutomator on the emulator, and verify the gallery insert with a MediaStore query. If the emulator image has no Photos app, defer that visual check.`,
  },
]

const byId = Object.fromEntries(GROUPS.map((g) => [g.id, g]))

function uniq(list) {
  return list.filter((x, i) => list.indexOf(x) === i)
}

// ---------- preloaded / landed groups ----------

function normalizePreloaded(g, value) {
  if (value === undefined || value === null || value === false) return null
  if (typeof value === 'object' && Array.isArray(value.tickets)) {
    return {
      filesChanged: [], verification: '', deferred: [], handoff: '', forMac: '',
      ...value,
      tickets: value.tickets.map((t) => ({ notes: '', files: [], ...t })),
    }
  }
  return {
    tickets: g.tickets.map((id) => ({ id, status: 'done', notes: 'preloaded (finished in an earlier run)', files: [] })),
    filesChanged: [], verification: 'preloaded', deferred: [], handoff: typeof value === 'string' ? value : '', forMac: '',
  }
}

const PRELOADED = {}
for (const key of Object.keys(RAW_PRELOADED)) {
  if (!byId[key]) {
    log(`ignoring unknown preloaded group '${key}' (known: ${GROUPS.map((g) => g.id).join(', ')})`)
    continue
  }
  const r = normalizePreloaded(byId[key], RAW_PRELOADED[key])
  if (r) PRELOADED[key] = r
}
for (const g of GROUPS) {
  if (!PRELOADED[g.id] && g.tickets.every((t) => LANDED.has(t))) {
    PRELOADED[g.id] = {
      tickets: g.tickets.map((id) => ({ id, status: 'done', notes: 'landed from editor-wip (args.landed)', files: [] })),
      filesChanged: [], verification: 'landed from editor-wip', deferred: [], handoff: '', forMac: '',
    }
  }
}
if (ONLY) {
  for (const id of ONLY) if (!byId[id]) log(`ignoring unknown group '${id}' in args.only`)
}
for (const t of ['ENG-02', 'ENG-03', 'ENG-04']) {
  if (LANDED.has(t) && !LANDED.has('ENG-06')) log(`warning: args.landed has ${t} but not ENG-06, which ${t} depends on; check args.landed`)
}

// Mac tickets a group still waits for (its own gates plus those of the Windows groups it depends on).
const macMemo = {}
function macBlockers(id) {
  if (macMemo[id]) return macMemo[id]
  const g = byId[id]
  if (PRELOADED[id]) return (macMemo[id] = [])
  const own = g.external.filter((t) => !LANDED.has(t))
  return (macMemo[id] = uniq(own.concat(...g.deps.map(macBlockers))))
}

// ---------- plan ----------

const ready = []
for (const g of GROUPS) {
  const label = `${g.id} (${g.tickets.join(', ')})`
  if (PRELOADED[g.id]) log(`finished earlier: ${label}`)
  else if (macBlockers(g.id).length) log(`waiting for Mac: ${label} needs ${macBlockers(g.id).join(', ')}`)
  else if (ONLY && !ONLY.has(g.id)) log(`not selected (args.only): ${label}`)
  else ready.push(g.id)
}
log(`ready to build: ${ready.join(', ') || 'none'}; Mac tickets landed: ${[...LANDED].join(', ') || 'none'}; up to ${MAX_PARALLEL} builders at once`)

// ---------- build ----------

const results = {}
const running = {}
const built = []
const notFinished = {}

let active = 0
const slotWaiters = []
function acquireSlot() {
  if (active < MAX_PARALLEL) {
    active++
    return Promise.resolve()
  }
  return new Promise((resolve) => slotWaiters.push(resolve))
}
function releaseSlot() {
  const next = slotWaiters.shift()
  if (next) next()
  else active--
}

function reasonFor(id) {
  if (results[id]) return 'has a blocked ticket'
  if (macBlockers(id).length) return `waiting for Mac: ${macBlockers(id).join(', ')}`
  if (notFinished[id] && notFinished[id].indexOf('dependency not finished') === 0) return 'skipped too'
  return notFinished[id] || 'not finished'
}

function runGroup(id) {
  if (running[id]) return running[id]
  const g = byId[id]
  running[id] = (async () => {
    if (PRELOADED[id]) {
      results[id] = PRELOADED[id]
      return PRELOADED[id]
    }
    if (macBlockers(id).length) return null
    if (ONLY && !ONLY.has(id)) {
      notFinished[id] = 'not selected (args.only)'
      return null
    }
    const deps = await Promise.all(g.deps.map(runGroup))
    const failedDeps = g.deps.filter((d, i) => !deps[i] || deps[i].tickets.some((t) => t.status === 'blocked'))
    if (failedDeps.length) {
      notFinished[id] = `dependency not finished: ${failedDeps.map((d) => `${d} (${reasonFor(d)})`).join(', ')}`
      log(`skip ${id}: ${notFinished[id]}`)
      return null
    }
    const handoffFrom = uniq(g.deps.concat(id === 'eng08' ? [] : ['eng08']))
    const handoff = handoffFrom
      .filter((d) => results[d] && results[d].handoff)
      .map((d) => `${d}: ${results[d].handoff}`)
      .join('\n')
    await acquireSlot()
    let r = null
    try {
      r = await agent(`${CONTEXT}

YOUR TICKETS: ${g.tickets.map((t) => `${t} · ${TITLES[t]}`).join('; ')}. Read each ticket body in BUILD_PLAN §6 and the ARCHITECTURE sections it cites.
FILES YOUR TICKETS OWN (summary of the §6 owns lists; §6 wins if they differ):
${OWNS_LEGEND}
${ownsText(g.tickets)}
${g.note ? 'LEAD NOTE: ' + g.note : ''}
Mac-side tickets already merged into this tree: ${[...LANDED].join(', ') || 'none'}.
Hand-off from earlier lane groups:
${handoff || '(none)'}
Implement the tickets completely to their acceptance criteria with tests. Verify with the Gradle build, JVM unit tests, lint, emulator instrumented tests and any native or Dart build your tickets require. Return the structured result. In tickets[].files, list every file you created or changed for that ticket (repo-relative, forward slashes) so the lead can commit each ticket on its own.`, { label: `build:${id}`, phase: 'Build', schema: RESULT_SCHEMA, model: g.model, ...(g.effort ? { effort: g.effort } : {}) })
    } catch (e) {
      notFinished[id] = `builder failed: ${e && e.message ? e.message : String(e)}`
      log(`${id}: ${notFinished[id]}`)
      r = null
    } finally {
      releaseSlot()
    }
    if (r) {
      results[id] = r
      built.push(id)
      log(`${id} finished: ${r.tickets.map((t) => `${t.id} ${t.status}`).join(', ')}`)
    } else if (!notFinished[id]) {
      notFinished[id] = 'builder returned no result (skipped or terminal error)'
    }
    return r
  })()
  return running[id]
}

phase('Build')
await Promise.all(GROUPS.map((g) => runGroup(g.id)))

const waitingForMac = GROUPS
  .filter((g) => !PRELOADED[g.id] && macBlockers(g.id).length)
  .map((g) => ({ group: g.id, tickets: g.tickets, needs: macBlockers(g.id) }))
const notFinishedList = Object.keys(notFinished).map((group) => ({ group, reason: notFinished[group] }))

const preloadForNextRun = {}
for (const id of Object.keys(PRELOADED)) preloadForNextRun[id] = RAW_PRELOADED[id] !== undefined ? RAW_PRELOADED[id] : true
for (const id of built) {
  if (results[id].tickets.every((t) => t.status === 'done' || t.status === 'not_needed')) preloadForNextRun[id] = results[id]
}
const rerunNext = built.filter((id) => !preloadForNextRun[id])
if (rerunNext.length) log(`partial or blocked (left out of preloadForNextRun, so they resume next run): ${rerunNext.join(', ')}`)

const commitPlan = []
for (const id of built) {
  for (const t of results[id].tickets) {
    if (!t.files || !t.files.length) continue
    commitPlan.push({
      ticket: t.id,
      status: t.status,
      message: `feat(editor): ${t.id} ${TITLES[t.id] || ''}`.trim() + (t.status === 'done' || t.status === 'not_needed' ? '' : ` (${t.status})`),
      files: t.files,
    })
  }
}

const forMac = built
  .map((id) => ({ group: id, note: results[id].forMac }))
  .filter((x) => x.note && !/^\s*(none|n\/a)?\.?\s*$/i.test(x.note))

if (!built.length) {
  log('no lane group was built in this run')
  return { built, preloaded: Object.keys(PRELOADED), waitingForMac, notFinished: notFinishedList, commitPlan, forMac, review: null, fix: null, preloadForNextRun }
}

if (!RUN_REVIEW) {
  log('review skipped (args.review = false)')
  return {
    built, preloaded: Object.keys(PRELOADED), waitingForMac, notFinished: notFinishedList,
    groups: built.map((id) => ({ id, tickets: results[id].tickets.map((t) => `${t.id}:${t.status}`), deferred: results[id].deferred })),
    commitPlan, forMac, review: null, fix: null, preloadForNextRun,
  }
}

// ---------- review ----------

const summary = GROUPS.filter((g) => results[g.id]).map((g) => {
  const r = results[g.id]
  const origin = built.includes(g.id) ? 'built in this run' : 'finished earlier'
  return `## ${g.id} (${g.tickets.join(', ')}), ${origin}\n${r.tickets.map((t) => `- ${t.id}: ${t.status} — ${t.notes}`).join('\n')}\nverification: ${r.verification}\ndeferred: ${r.deferred.join(' | ')}`
}).join('\n\n')

const ALL_LANE_TICKETS = GROUPS.flatMap((g) => g.tickets)
const FROZEN = LANDED.has('ENG-06')
  ? 'ENG-06 HAS landed: the Pigeon surface, glue, build.gradle.kts and lint.xml are frozen; findings in them go to forMac, not fixed here.'
  : 'ENG-06 has NOT landed yet: ENG-08 still owns its glue, build.gradle.kts, lint.xml and manifest, so findings there can be fixed here.'

const REVIEW_SCHEMA = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          severity: { type: 'string', enum: ['blocker', 'major', 'minor'] },
          ticket: { type: 'string' },
          file: { type: 'string' },
          issue: { type: 'string' },
          evidence: { type: 'string' },
          fix: { type: 'string' },
        },
        required: ['severity', 'ticket', 'file', 'issue', 'evidence', 'fix'],
      },
    },
    verdict: { type: 'string' },
  },
  required: ['findings', 'verdict'],
}

phase('Review')
const review = await agent(`${CONTEXT}

You are the REVIEWER for this Android-lane round on Windows. Builder reports:
${summary}
Waiting for Mac: ${waitingForMac.map((w) => `${w.group} (needs ${w.needs.join(', ')})`).join('; ') || 'none'}
Not finished: ${notFinishedList.map((n) => `${n.group} (${n.reason})`).join('; ') || 'none'}
${FROZEN}

SCOPE: review only files owned by the lane's tickets (${ALL_LANE_TICKETS.join(', ')}) that changed:
- git diff --name-status origin/editor-wip...HEAD (lane commits since the last editor-wip merge)
- working-tree changes: git status --porcelain, git diff HEAD and untracked files
Focus on the groups built in this run (${built.join(', ')}), but cover every changed lane file. A changed file outside these owned paths is an ownership finding, unless it is a §7 shared file with a minimal insertion. Read Mac-owned files only to check contracts.
${OWNS_LEGEND}
${ownsText(ALL_LANE_TICKETS)}

CHECK:
- Kotlin/Media3 1.11.1 correctness: API use, @file:OptIn, Transformer/FrameExtractor/ExoPlayer/MediaCodec/MediaExtractorCompat lifecycles and release, frame grid D-35 (P(k) anchoring, frameIndexNearest, androidSeekMsRounding), AND-01's carried rules.
- Threading and lifecycle: GL only on vwish-gl; no main-thread blocking beyond the 500 ms surface latch; HandlerThread/Looper teardown; leaked codecs, surfaces, EGL contexts or SurfaceTextures; cancellation and partial-file cleanup; activity/Flutter engine detach and reattach.
- Contract drift against the Dart engine API (packages/vwish_editor_engine_api) and the frozen Pigeon surface (packages/vwish_editor_engine/pigeons/engine_api.dart and the generated Kotlin): field meanings, units, error codes, events.
- Missing or weak tests against each ticket's acceptance criteria, and anything faking a result: device runs or measurements that did not happen, emulator numbers reported as device numbers, skipped/@Ignore'd or assertion-free tests counted as green, criteria marked done that should be deferred.
- Windows artefacts: CRLF in LF files, backslash or absolute local paths in committed files, local.properties or secrets.
Re-run the Gradle build, the JVM tests, lint and, holding the emulator lock, the affected instrumented tests to confirm claims; stop the emulator afterwards if no lock exists. Report only real defects with evidence. Do not edit files.`, { label: 'review', phase: 'Review', schema: REVIEW_SCHEMA, model: 'opus' })

// ---------- fix ----------

const FIX_SCHEMA = {
  type: 'object',
  properties: {
    results: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          finding: { type: 'integer', description: '1-based index of the finding' },
          outcome: { type: 'string', enum: ['fixed', 'skipped', 'needs_mac'] },
          reason: { type: 'string' },
          files: { type: 'array', items: { type: 'string' } },
        },
        required: ['finding', 'outcome', 'reason', 'files'],
      },
    },
    verification: { type: 'string', description: 'final Gradle build / JVM test / lint / emulator result lines' },
    forMac: { type: 'string' },
  },
  required: ['results', 'verification', 'forMac'],
}

phase('Fix')
const findings = review && review.findings ? review.findings : []
const fix = findings.length ? await agent(`${CONTEXT}

You are the FIXER for this Android-lane round. ${FROZEN}
For each finding below:
- Verify it yourself first. Reviewers can be wrong.
- Fix the real ones with minimal changes inside the owning lane tickets' files.
- Skip the rest with a reason.
- Findings in Mac-owned or frozen files are needs_mac: describe them in forMac and do not edit those files.
Then rerun, all green: the Gradle build through the example host, the full :vwish_editor_engine:testDebugUnitTest, lint, and the affected instrumented tests on the emulator (under the lock; stop the emulator afterwards if no lock exists). Report each finding as fixed, skipped or needs_mac, with the files you changed.
Findings:
${findings.map((f, i) => `${i + 1}. [${f.severity}] ${f.ticket} ${f.file}: ${f.issue}\n   evidence: ${f.evidence}\n   fix: ${f.fix}`).join('\n')}`, { label: 'fix', phase: 'Fix', schema: FIX_SCHEMA, model: 'opus' }) : null

if (fix && fix.results) {
  const fixFiles = uniq(fix.results.filter((x) => x.outcome === 'fixed').flatMap((x) => x.files || []))
  if (fixFiles.length) {
    const tickets = uniq(fix.results.filter((x) => x.outcome === 'fixed').map((x) => (findings[x.finding - 1] || {}).ticket).filter(Boolean))
    commitPlan.push({ ticket: tickets.join(', ') || 'review', status: 'done', message: `fix(editor): Android lane review fixes (${tickets.join(', ') || 'review'})`, files: fixFiles })
  }
  if (fix.forMac && !/^\s*(none|n\/a)?\.?\s*$/i.test(fix.forMac)) forMac.push({ group: 'fix', note: fix.forMac })
}

return {
  built,
  preloaded: Object.keys(PRELOADED),
  waitingForMac,
  notFinished: notFinishedList,
  groups: built.map((id) => ({ id, tickets: results[id].tickets.map((t) => `${t.id}:${t.status}`), deferred: results[id].deferred })),
  commitPlan,
  forMac,
  review: review ? { verdict: review.verdict, findings: review.findings } : null,
  fix: fix || (review ? 'no findings' : 'review did not return'),
  preloadForNextRun,
}
