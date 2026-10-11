export const meta = {
  name: 'editor-android-lane',
  description: 'Build the Danaview editor Android lane on the Windows laptop (ENG-08, AI-04, AND-02..AND-19) in dependency order, gated on Mac tickets merged from editor-wip, then one review and one fix pass',
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
 * Builds the Android lane of the Danaview editor (docs/editor/BUILD_PLAN.md): ENG-08, AI-04 and
 * AND-02..AND-19. One builder agent per ticket group, then one reviewer and one fixer. The Mac
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
 *      ticket, leave it out. The groups that need it just wait. ENG-09, API-04 and AI-03 were
 *      done at hand-off and always count as landed.
 *   3. Close anything heavy (Android Studio builds, a second emulator).
 *
 * RUN
 *   Workflow({
 *     scriptPath: 'C:/dev/danaview/docs/editor/handoff/android_lane_workflow.js',
 *     args: {
 *       root: 'C:/dev/danaview',                     // required: repo root, forward slashes
 *       landed: ['ENG-09', 'API-04'],                    // Mac tickets merged into this tree
 *       preloaded: {},                                   // finished groups, see RESUME
 *       // optional: only: ['ai-android'], maxParallel: 1, review: true
 *     },
 *   })
 *
 * ARGS
 *   root         Required. Absolute repo root on this machine, e.g. 'C:/dev/danaview'.
 *   landed       Ticket ids merged into this working tree from editor-wip, plus owner tokens.
 *                ENG-09, API-04 and AI-03 are done and always counted. Gates still to come:
 *                ENG-06 (every AND group), ENG-02 (and-m3-preview), ENG-03 (and-m4-services) and
 *                ENG-04 (and-m4-export), INT-06 (and-m4-rpreview: the render-preview engine
 *                interface additions, ARCH D-45). and-m3-fallback (AND-16) also needs one token, added only
 *                on the lead's word: AND16-SHIM (ENG-06 assigned android/src/main/cpp/ and added the
 *                externalNativeBuild block). The owner signed D-43(e) on 2026-10-11 (ARCH D-43, D-45),
 *                so there is no D-43E gate any more.
 *                A group runs only when all of its gates are listed. Otherwise the group, and every
 *                group that depends on it, is logged as 'waiting for Mac/owner: ...' and skipped.
 *                ENG-06 listed means ENG-08 has landed too (ENG-06 depends on it), so eng08 counts
 *                as finished and is never rebuilt against the frozen files.
 *   preloaded    {groupId: result} for groups that are already finished and committed. They are
 *                not re-run, and their hand-off goes to the groups that depend on them. A result
 *                can be a builder's returned object (from this script's preloadForNextRun, or from
 *                journal.jsonl), a plain hand-off string, or true.
 *   only         Optional list of group ids to run this time. Others are skipped unless preloaded.
 *   maxParallel  Optional number of builders at once (default 1, max 4). ANDROID_LANE.md §3 runs one
 *                group at a time; more than 1 is an opt-in, and those builders share one Gradle
 *                module, one working tree and the emulator lock.
 *   review       Optional. false skips the review and fix agents.
 *
 * GROUPS            tickets                          Windows deps                          Mac/owner gates
 *   eng08           ENG-08                           -                                     ENG-09 (done)
 *   ai-android      AI-04                            -                                     - (AI-03 done)
 *   and-m2a         AND-02, AND-03, AND-04, AND-05   eng08                                 ENG-06
 *   and-m2b         AND-06, AND-07                   and-m2a                               (ENG-06)
 *   and-m3-render   AND-08                           eng08                                 ENG-06
 *   and-m3-text     AND-09                           eng08                                 ENG-06 (API-04 done)
 *   and-m3-paused   AND-17                           and-m3-render, and-m3-text, and-m2b   (ENG-06)
 *   and-m3-preview  AND-10                           and-m3-paused                         ENG-02
 *   and-m3-fallback AND-16                           and-m3-preview                        ENG-06, AND16-SHIM
 *   and-m4-services AND-13, AND-14, AND-15           eng08                                 ENG-06, ENG-03
 *   and-m4-export   AND-11                           and-m3-render, and-m3-text,           ENG-04
 *                                                    and-m3-preview
 *   and-m4-rpreview AND-18                           and-m3-fallback                       INT-06 (ENG-06, AND16-SHIM)
 *   and-m4-precomp  AND-19                           and-m4-export                         (ENG-04)
 *   and-m5          AND-12                           and-m4-export                         (ENG-04)
 *   A gate in parentheses comes from a Windows dependency. Cross-machine order: ENG-08 (here) must
 *   land on editor-wip before the Mac's ENG-06, and ENG-06 must land here before any AND ticket.
 *   Builders share one emulator through a lock directory at <root>/build/danaview_locks/emulator
 *   (gitignored). Delete it if a killed run leaves it behind.
 *
 * AFTER A RUN (the lead does this; builder agents never change git state)
 *   - The result has commitPlan: one entry per finished (done or not_needed) ticket with a commit
 *     message and its files. Review fixes are folded into that ticket's entry; a fix to a ticket
 *     committed in an earlier run gets its own 'fix(editor): <TICKET> review fixes' entry.
 *     Commit each entry on its own, e.g.
 *       git add <files> && git commit -m "feat(editor): AND-02 Android probe, compatibility, ..."
 *     Partial or blocked tickets get no entry: their files (leftInTree) stay uncommitted and the
 *     next run resumes them. Never add a co-author trailer (owner rule). Never commit
 *     android/key.properties, *.jks or local.properties.
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
  throw new Error("android_lane_workflow: args.root is required (absolute repo root with forward slashes), e.g. Workflow({scriptPath: '<repo>/docs/editor/handoff/android_lane_workflow.js', args: {root: 'C:/dev/danaview', landed: ['ENG-09', 'API-04'], preloaded: {}}})")
}
const ROOT = A.root.replace(/\\/g, '/').replace(/\/+$/, '')

function toIdList(value, name) {
  if (value === undefined || value === null) return []
  if (typeof value === 'string') return value.split(/[\s,]+/).filter(Boolean)
  if (!Array.isArray(value)) throw new Error(`android_lane_workflow: args.${name} must be an array of ids`)
  return value.map((s) => String(s).trim()).filter(Boolean)
}

const LANDED = new Set(toIdList(A.landed, 'landed').map((s) => s.toUpperCase()))
// Done and pushed on editor-wip at hand-off (BUILD_STATE.md).
for (const t of ['ENG-09', 'API-04', 'AI-03']) LANDED.add(t)
// ENG-06 depends on ENG-08, so ENG-06 landed means ENG-08 is landed and frozen.
if (LANDED.has('ENG-06')) LANDED.add('ENG-08')
const ONLY = A.only ? new Set(toIdList(A.only, 'only')) : null
const MAX_PARALLEL = Math.max(1, Math.min(4, Number.isFinite(Number(A.maxParallel)) && A.maxParallel ? Math.floor(Number(A.maxParallel)) : 1))
const RUN_REVIEW = A.review !== false
const RAW_PRELOADED = parseMaybeJson((A && A.preloaded) || {}, 'preloaded') || {}
const LOCK = `${ROOT}/build/danaview_locks/emulator`

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
  'AND-18': 'Android render-preview renderer and playback swap-in',
  'AND-19': 'Android multi-pass export precompose',
}

const OWNS_LEGEND = `Path prefixes:
K/ = packages/danaview_editor_engine/android/src/main/kotlin/com/vecvel/danaview/editor/engine/
T/ = packages/danaview_editor_engine/android/src/test/kotlin/com/vecvel/danaview/editor/engine/
A/ = packages/danaview_editor_engine/android/src/androidTest/kotlin/com/vecvel/danaview/editor/engine/
E/ = packages/danaview_editor_engine/
(a path ending in / is the whole directory)`

// Summary of the BUILD_PLAN §6 owns lists (BUILD_PLAN wins if they differ).
const OWNS = {
  'ENG-08': ['E/android/build.gradle.kts', 'E/android/lint.xml', 'E/android/src/main/AndroidManifest.xml', 'E/android/src/main/res/xml/danaview_editor_file_paths.xml', 'K/DanaviewEditorEnginePlugin.kt', 'K/glue/', 'K/core/EngineContext.kt', 'K/core/ErrorCodes.kt', 'K/core/EventHub.kt', 'K/core/EngineThreads.kt', 'K/core/Paths.kt', 'T/glue/', '+ D-33 placeholders (header // OWNER: <ticket>) for every Android service file of ARCH §4.4'],
  'AI-04': ['packages/danaview_whisper/android/build.gradle.kts', 'packages/danaview_whisper/android/src/main/AndroidManifest.xml', 'packages/danaview_whisper/src/cmake/android.cmake', 'packages/danaview_whisper/src/dv_exports.map', 'scripts/ci/editor/check_native_libs.sh'],
  'AND-02': ['K/media/Probe.kt', 'K/media/Compatibility.kt', 'K/core/DeviceProfile.kt', 'K/core/Capabilities.kt', 'T/probe/', 'A/probe/'],
  'AND-03': ['K/media/ThumbnailService.kt', 'K/media/DiskCache.kt', 'T/thumbs/', 'A/thumbs/'],
  'AND-04': ['K/media/PcmDecoder.kt', 'K/media/WaveformService.kt', 'K/media/SpeechAudioExtractor.kt', 'T/audio/', 'A/audio/'],
  'AND-05': ['K/core/JobRegistry.kt', 'K/media/ProxyJob.kt', 'K/media/ProxyRegistry.kt', 'T/proxy/', 'A/proxy/'],
  'AND-06': ['K/media/FreezeFrameJob.kt', 'K/preview/SourceFrameCache.kt', 'T/freeze/', 'A/freeze/'],
  'AND-07': ['K/media/ReverseJob.kt', 'T/reverse/', 'A/reverse/'],
  'AND-08': ['K/plan/', 'K/composition/', 'T/composition/', 'A/composition/'],
  'AND-09': ['K/effects/', 'E/android/src/main/assets/danaview_shaders/', 'T/effects/', 'A/effects/'],
  'AND-17': ['K/preview/PausedFrameRenderer.kt', 'K/preview/LayerCompositorGl.kt', 'K/preview/StructuralDebouncer.kt', 'A/paused/'],
  'AND-10': ['K/preview/PreviewSession.kt', 'K/preview/PreviewSessionManager.kt', 'K/preview/SurfaceBridge.kt', 'K/preview/SeekController.kt', 'K/preview/QualityGovernor.kt', 'A/preview/', 'E/example/integration_test/android_preview_test.dart'],
  'AND-16': ['K/preview/fallback/', 'A/fallback/'],
  'AND-11': ['K/export/ExportCoordinator.kt', 'K/export/TransformerExport.kt', 'K/export/EncoderSettings.kt', 'K/export/HardwareEncoderSelector.kt', 'K/export/ActiveExportStore.kt', 'T/export/', 'A/export/'],
  'AND-13': ['K/recording/VoiceRecorder.kt', 'A/recording/'],
  'AND-14': ['K/platform/MediaPicker.kt', 'K/platform/MediaAccess.kt', 'K/platform/Permissions.kt', 'A/platform/'],
  'AND-15': ['K/platform/DropTarget.kt', 'A/drop/'],
  'AND-12': ['K/export/ExportService.kt', 'K/export/ExportNotification.kt', 'K/platform/BackgroundGuard.kt', 'K/platform/MediaStoreSaver.kt', 'K/platform/FileHandoff.kt', 'E/android/src/main/res/drawable/danaview_export_notification.xml', 'A/service/'],
  'AND-18': ['K/preview/render/', 'T/render/', 'A/render/'],
  'AND-19': ['K/export/precompose/', 'T/precompose/', 'A/precompose/'],
}

function ownsText(tickets) {
  return tickets.map((t) => `${t}: ${(OWNS[t] || []).join(', ')}`).join('\n')
}

// ---------- context for every agent ----------

const CONTEXT = `
You are an engineer on Danaview (Flutter 3.44.2 / Dart 3.12 monorepo at ${ROOT}) working the ANDROID LANE on the owner's WINDOWS laptop (32 GB RAM, no Xcode). We are building a production video editor for iOS + Android per the FINAL docs:
- ${ROOT}/docs/editor/ARCHITECTURE.md (source of truth; decisions D-1..D-45; D-43(e) signed off by the owner 2026-10-11, D-45 render-preview cache and multi-pass export; read only the sections your tickets cite)
- ${ROOT}/docs/editor/BUILD_PLAN.md (§1 how to work a ticket, §2 ownership rules, §5 dependency index, §6 ticket bodies with acceptance criteria, §7 shared/integration file register)
- ${ROOT}/docs/editor/spikes/AND-01.md (Android spike: verdict, measurements, what ENG-06 applies, rules carried into the AND tickets; read it before any AND ticket)
- ${ROOT}/docs/editor/handoff/ (ANDROID_LANE.md lane plan, WINDOWS_SETUP.md Windows pitfalls, BUILD_STATE.md status and hand-off facts of finished tickets; read the parts relevant to you)

SPLIT (decided by the owner; do not re-litigate): the build runs on two machines. The Mac keeps everything except the Android lane: all core/UI/UX/integration/QA tickets, all iOS tickets, ENG-01..07, ENG-09, ENG-02/03/04, ENG-06 (integration freeze), AI-05, IOS-01 and AND-01. This Windows laptop owns ONLY the Android lane: ENG-08, AI-04, AND-02..AND-19. Windows can never build or test iOS: never edit iOS/Swift/podspec files and never claim an iOS criterion. Cross-machine gates: ENG-08 (Windows) lands before ENG-06 (Mac); ENG-06 lands before AND-02..AND-19. Your group was started only after its Mac-side gates were merged into this working tree. If something you need from a Mac ticket is missing or wrong, report it in forMac and deferred as a defect against that ticket; never edit its files.

GIT: the lane works on branch editor-android (from editor-wip, github.com/vecvel/danaview). Do NOT run state-changing git commands (no add, commit, stash, checkout/switch, reset, restore, merge, rebase, pull, push, clean, branch, tag, config). Read-only git (status, diff, log, show, ls-files) is fine. The lead commits each ticket after this run as 'feat(editor): <TICKET> <title>' with no co-author trailer, so report exact per-ticket file lists. Never create or commit secrets (android/key.properties, *.jks) or machine files (local.properties).

OWNERSHIP: only create/edit files your tickets own (BUILD_PLAN §2 and the §6 owns lists) plus placeholders whose header says '// OWNER: <your ticket>' (replace the placeholder). The only §7 shared files the lane touches are ENG-08's own (build.gradle.kts, the manifest, the plugin class, glue/, lint.xml), and only inside ENG-08; every other §7 file is edited by Mac integration tickets. The Pigeon surface (packages/danaview_editor_engine/pigeons/, lib/src/pigeon/, android/.../pigeon/), the Kotlin glue (android/.../glue/), build.gradle.kts and lint.xml are frozen after ENG-06. Service tickets implement the service classes the glue already calls. Never run Pigeon generation and never change dependency versions (Media3 is pinned to 1.11.1; upgrading means rerunning AND-01). If a Pigeon/glue/Gradle/manifest change is truly needed, stop and report it in forMac as needing a lead-approved [INTEGRATION] ticket. When maxParallel > 1, other builders may be working in parallel in this same working tree on disjoint files and compiling the same Gradle module. If a build fails because of another ticket's half-written file, or Gradle reports a lock held by another build, wait a minute and retry; never edit their files.

RESUME RULE: always inspect what already exists for your tickets first (git status/diff, your owned paths, placeholders); an earlier attempt may have been cut off. Continue from there; never redo finished work.

DOWNLOAD RULE: no internet downloads except normal package-manager resolution (pub, Gradle/Maven). Never download speech models, media or tools, and never install SDK components or software. Use fake HTTP servers and test fixtures. Reuse ENG-05's committed fixtures (packages/danaview_editor_engine/test_fixtures/, packed into the test APK by example/android/danaview_test_harness.gradle). Generate any new media locally with ffmpeg from PATH (not /opt/homebrew/bin/ffmpeg) or MediaCodec, inside your owned test directories, and record its provenance. whisper.cpp v1.9.4 is vendored at packages/danaview_whisper/third_party/whisper.cpp; never modify vendored sources.

DEVICE RULE: there is no physical Android device. Verification runs as JVM unit tests and on x86_64 emulators: Pixel_9_Pro_XL_API_35 (default), plus Pixel_API_29, Pixel_API_34 and Pixel_Tablet_API_35 where a criterion names API 29, API 34 or a tablet. Check which exist with 'emulator -list-avds'; only when a needed AVD is missing, mark that criterion 'deferred: <AVD> not installed'. Mark criteria that need a real device, a named device class (Pixel 7a, 4 GB, low/mid tier) or real-hardware performance 'deferred: no device available', with the reason. Never fake them. Report emulator measurements as emulator measurements, never as device numbers. A test that is skipped, @Ignore'd or asserts nothing is not a pass.

OWNER DEFAULTS (D-43, owner defaults 2026-10-08, revisable): Android editor gate API 29 + GLES3 + 2 GB RAM (devices below 3 GB run the minimal tier, D-40); no auto captions on armeabi-v7a; Android editor data excluded from backup.
OWNER DECISION D-43(e) (2026-10-11, ARCH D-43 and D-45): preview adapts to the device, export is always full quality and never refused (only slower on weak devices). Proxies on by default on minimal/low; adaptive preview quality full -> 1/2 -> 1/4 unless pinned; layers over the live decode budget show paused-exact stills during playback only (paused, scrub and seek always exact); exact seek may be +30% on AND-16 (nearest frame first, then exact); drop a frame rather than show a late or wrong one; maxVisualSequences limits live preview only, and above the device's decoder limit export runs a multi-pass precompose (AND-19); heavy ranges can be pre-rendered into the render-preview cache (AND-18).

TIME RULE (BUILD_PLAN §1.7, ARCH §5, D-35): any code that turns a platform clock or presentation time into a frame uses frameIndexNearest and evaluates at timeOfFrame(k); boundaries are anchored at P(k) = round(k*1e6/gridFps); never compare a raw platform microsecond value with a plan edge. Every Media3 file starts with @file:OptIn(UnstableApi::class, ExperimentalApi::class). Nothing logs media paths, transcript text or user content.

WINDOWS: your Bash tool runs Git Bash. Run the repo's .sh scripts with Git Bash (e.g. bash scripts/ci/editor/android_unit.sh). Use PowerShell (powershell -NoProfile -Command "...") for other Windows-native work: gradlew.bat, starting/stopping the emulator, process checks. Use forward slashes in paths (C:/Users/...; Git Bash also accepts /c/Users/...). Files keep LF line endings (.gitattributes: * text=auto eol=lf; only .bat/.cmd/.ps1 are CRLF). Never convert line endings and never write absolute local paths into committed files. Android SDK: $ANDROID_HOME (default C:/Users/<you>/AppData/Local/Android/Sdk). The CI scripts only probe macOS/Linux default SDK paths, so pass ANDROID_HOME on the command line if it is unset. NDKs 27.0.12077973 and 28.2.13676358 are under <sdk>/ndk/. CMake 3.22.1 and Ninja are under <sdk>/cmake/3.22.1/bin/ (cmake.exe, ninja.exe). llvm-readelf is under <ndk>/toolchains/llvm/prebuilt/windows-x86_64/bin/. JDK 21 is installed; keep the JVM 17 source/target pins. If a Windows-specific problem blocks you (path length, a file locked by a Gradle daemon, a missing tool), report the ticket as blocked with the exact error. Do not change system settings, the registry, PATH or the global git config.

EMULATOR: one emulator at a time, default Pixel_9_Pro_XL_API_35. Up to ${MAX_PARALLEL} builder(s) run at once; serialize instrumented runs with the lock directory ${LOCK}:
- Take the lock with mkdir -p "${ROOT}/build/danaview_locks" && mkdir "${LOCK}". mkdir is atomic. If it fails, another builder is testing: wait and retry.
- Write your group id into "${LOCK}/owner" and touch that file before each long run. A lock whose owner file is untouched for 60 minutes is stale; remove it.
- If adb devices shows no emulator, start the default one headless in the background: <sdk>/emulator/emulator.exe -avd Pixel_9_Pro_XL_API_35 -no-window -no-audio -no-boot-anim -no-snapshot-save. Wait for adb wait-for-device and getprop sys.boot_completed = 1.
- For an API 29, API 34 or tablet run: while holding the lock, stop the running emulator (adb emu kill), boot the named AVD the same way, run the scoped tests with ANDROID_SERIAL set to its serial from adb devices, then stop it.
- Remove the lock right after your connected test run.
- When your group is finished and no lock exists, stop the emulator (adb emu kill).
- Never run two emulators at once.

VERIFICATION (every group; report the commands and their final result lines):
- The engine builds through the example host (packages/danaview_editor_engine/example/android: gradlew.bat :danaview_editor_engine:assembleDebug, or flutter build apk --debug in the example).
- JVM unit tests: :danaview_editor_engine:testDebugUnitTest. Scope them with --tests while iterating; run the full suite once at the end.
- Lint (:danaview_editor_engine:lintDebug), which enforces the Media3 opt-in.
- Instrumented tests on the emulator, under the lock: :danaview_editor_engine:connectedDebugAndroidTest scoped with -Pandroid.testInstrumentationRunnerArguments.package=com.vecvel.danaview.editor.engine.<topic>.
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
    note: `Thin Kotlin glue for every host API against ENG-01's generated Pigeon Kotlin (Mac-owned, read only). Write the engine core: EngineContext, ErrorCodes, EventHub, EngineThreads (danaview-preview, danaview-gl, danaview-export, danaview-jobs, danaview-io) and Paths. Create D-33 placeholders for every Android service file of ARCH §4.4 (AND-02..AND-17, incl. preview/{PausedFrameRenderer,LayerCompositorGl,StructuralDebouncer} and an empty preview/fallback/ package) returning notSupportedOnDevice, each with the header '// OWNER: <ticket>'. Also build.gradle.kts and lint.xml per the ticket spec, and the plugin manifest per ARCH §20.4. ENG-01 left minimal placeholders in build.gradle.kts, AndroidManifest.xml and DanaviewEditorEnginePlugin.kt (§7 order ENG-01 -> ENG-08 -> ENG-06); replace them. build.gradle.kts freezes at ENG-06, so declare every dependency the lane will need now (BUILD_PLAN §2, ANDROID_LANE.md §5 ENG-08): androidTestImplementation androidx.test:rules (AND-13/AND-14 permission rules) and androidx.test.uiautomator:uiautomator (AND-12's UiAutomator criterion), plus anything else AND-02..AND-17 will need. List them with versions and V-N14 compatibility in handoff and forMac. Do not pre-apply the AND-01 changes in docs/editor/spikes/AND-01.md §6 (minSdk 29, JNI shim and externalNativeBuild, extra Media3 artifacts, Kotlin opt-in flag): ENG-06 applies them on the Mac, so keep the files easy to amend. The ENG-09 example host (packages/danaview_editor_engine/example) is the harness: capabilities() must round-trip on the emulator through it, and the example's manifest merge must be clean. Lint must fail on a negative fixture missing the opt-in (keep that fixture out of the shipped source set). ARCHITECTURE.md is ENG-06's file. Put the V-N14 outcome, the glue class list, the placeholder list and every Gradle/manifest fact ENG-06 needs in forMac and handoff.`,
  },
  {
    id: 'ai-android', tickets: ['AI-04'], deps: [], external: [], model: 'opus',
    note: `whisper Android native build (ai.md §4.3). AI-03 is DONE: its C shim, src/CMakeLists.txt and host tests in packages/danaview_whisper/src/ are read-only for you, as are the vendored whisper.cpp sources. Gradle externalNativeBuild with src/cmake/android.cmake produces:
- libdanaview_whisper.so: arm64-v8a armv8-a baseline, plus x86_64
- libdanaview_whisper_v82.so: arm64-v8a armv8.2-a+fp16+dotprod (AI-07's Dart loader picks it at runtime from getauxval(AT_HWCAP); record the exact names and selection facts in handoff)
Build settings: c++_static; 16 KB page alignment (pass -Wl,-z,max-page-size=16384 explicitly so it also holds on NDK 27); only dv_* exported via dv_exports.map; no armeabi-v7a (owner default D-43); -O3; no OpenMP. Use the SDK CMake 3.22.1 (version = "3.22.1") with its Ninja, and the NDK the build pins (flutter.ndkVersion or an explicit ndkVersion), which must be one of the installed 27.0.12077973 / 28.2.13676358; do not install another. Answer V-A8 (is the SDK's CMake 3.22.1 sufficient) in handoff and forMac; ARCHITECTURE.md is not your file.
check_native_libs.sh follows the scripts/ci/editor/README.md script contract and must run in Git Bash on Windows, in bash 3.2 on macOS and on Linux CI:
- Locate llvm-readelf under the NDK's toolchains/llvm/prebuilt/<windows-x86_64|darwin-x86_64|linux-x86_64>/bin (.exe on Windows).
- Unpack the AAB/APK with a tool present on all three platforms, and document the choice.
- Check: ABIs present, no armeabi-v7a whisper library, 16 KB LOAD alignment, exported symbols exactly dv_*, size <= 3 MB per .so.
Prove it against an AAB you built. The root app first pulls in danaview_whisper at INT-02 (Mac, later; through danaview_editor -> danaview_transcription, BUILD_PLAN note 7). If no in-repo host includes the plugin yet, build a throwaway host outside the repo at a short path such as C:/dev/scratch/whisper_host that depends on packages/danaview_whisper by path, and record that the app-level check repeats at INT-02. Use debug signing, never the release keystore. Never add media_kit to any host: its Gradle script downloads libmpv jars from github.com, which the owner has not approved. Record the 'no libc++_shared conflict with media_kit' criterion as 'checked by the Mac in INT-02'. The root .gitignore does not cover .cxx/, so set externalNativeBuild { cmake { buildStagingDirectory } } in your build.gradle.kts to a folder under the module's build directory; no .cxx/ tree may appear in the repo. Native compiles are CPU-heavy: cap parallel jobs at 8.`,
  },
  {
    id: 'and-m2a', tickets: ['AND-02', 'AND-03', 'AND-04', 'AND-05'], deps: ['eng08'], external: ['ENG-06'], model: 'opus',
    note: `Android native media services on Media3 1.11.1, as ENG-06 froze build.gradle.kts and lint.xml. Read AND-01.md §6-7 (AND-02: HDR editability depends on GL_EXT_YUV_target and a 10-bit decoder; V-N5 is deferred to a device) and the ARCH §13.3/§15 rows these tickets cite. They follow the same contracts as IOS-02..IOS-05: read those iOS ticket bodies, and the iOS code if present, for parity only; never edit iOS files. Use ENG-05's fixtures (incl. MKV/WebM). Unit-test AND-02's gate and tier logic with injected profiles. Run the GLES 3 and maxTextureSize checks on the API 35 emulator, and the GLES 3 check again on Pixel_API_29 per the EMULATOR rule (defer only if that AVD is missing). Record performance criteria (cache hit/miss times, >= 60x realtime) as emulator numbers and defer the device-tier criterion. Order: AND-02 first (the others depend on it), then AND-03, AND-04 and AND-05.`,
  },
  {
    id: 'and-m2b', tickets: ['AND-06', 'AND-07'], deps: ['and-m2a'], external: [], model: 'opus',
    note: `AND-06: FrameExtractor with SeekParameters.EXACT, PNG still at the Dart path, SourceFrameCache. LayerLookEffect overrides apply once AND-09 lands; it may be built in parallel right now. Use it if it is complete in the tree, otherwise return unprocessed frames as the ticket allows and say so in handoff. AND-07: chunked reverse with the same algorithm and preflight as IOS-07 (read it for parity only). Use AND-04's PcmDecoder and AND-05's JobRegistry from the hand-off below.`,
  },
  {
    id: 'and-m3-render', tickets: ['AND-08'], deps: ['eng08'], external: ['ENG-06'], model: 'opus',
    note: `Plan reader, ParamSnapshot and CompositionMapper. ARCH §11 overrides native.md §4.2: the plan is a flat, fully lowered layer list. AND-01 recorded NO-GO for CompositionPlayer as the preview engine (AND-16 active) and GO for Transformer export. Read AND-01.md and ENG-06's ARCH §13.3 record for what the mapper must serve (Transformer export for AND-11, and the plan/ParamSnapshot types that AND-16's slot players, AND-17 and AND-10 consume). Apply AND-01.md §6 item 7:
- Gaps in video sequences are transparent image items at the output fps, not addGap.
- Clip starts use the rule-frame PTS (the ε mechanism AND-01 chose).
- Items faster than 1x use EditedMediaItem.setFrameRate(gridFps).
- setDurationUs is the full source duration.
Anchor every item and gap boundary at P(k). Include z-order and gating unit tests. Contract fixtures and vectors come from packages/danaview_editor_core/test/fixtures (frame_grid.json incl. androidSeekMsRounding, grid_cuts_30fps.json, expected_active.json, packing and classification vectors), plus API-03's render-math vectors in packages/danaview_editor_engine_api. Read them; never edit them. Per-layer effect lists reference AND-09 classes; AND-09 may be built in parallel right now, so code against its ENG-08 placeholders/public names.`,
  },
  {
    id: 'and-m3-text', tickets: ['AND-09'], deps: ['eng08'], external: ['ENG-06'], model: 'opus',
    note: `GL effects in GLSL ES 1.00 per ARCH §13.3 'GL effects' and §11.6 math. Render-math vectors and parity goldens come from API-03, and the .vsprite codec from API-04 (both done, in packages/danaview_editor_engine_api, Mac-owned, read only). Expose a small ShaderPrograms API that AND-17's LayerCompositorGl, the PausedFrameRenderer and AND-16 reuse. Only the danaview-gl thread touches GL (assert it), and resources are released on effect release. Run the goldens on the API 35 emulator; its GPU path differs from devices. If a golden misses only because of emulator rendering, record the measured error and defer the device check; never loosen a tolerance silently. GL timer-query numbers from the emulator are emulator numbers; the 1080p <= 8 ms mid-device budget is deferred: no device available.`,
  },
  {
    id: 'and-m3-paused', tickets: ['AND-17'], deps: ['and-m3-render', 'and-m3-text', 'and-m2b'], external: [], model: 'opus',
    note: `AND-01 reported NO-GO for CompositionPlayer preview, so the paused-frame reference cannot come from CompositionPlayer: use the Transformer export of the same plan (AND-08's mapper) and state it in handoff. Port from spikes/android_engine/.../PausedFrameRendererProto.kt (read only). Reuse AND-09's ShaderPrograms. AND-16 later composites its slot textures through LayerCompositorGl, so record its API in handoff. With any player, detach with clearVideoSurface(surface); the no-arg overload throws in 1.11.1. Record emulator numbers for the paused budgets; the mid/low device criteria are deferred: no device available.`,
  },
  {
    id: 'and-m3-preview', tickets: ['AND-10'], deps: ['and-m3-paused'], external: ['ENG-02'], model: 'opus',
    note: `AND-01 reported NO-GO for CompositionPlayer preview and ENG-06 activates AND-16 (read docs/editor/spikes/AND-01.md §1-2 and §6-7, and what ENG-06 recorded in ARCH §13.3/§13.4). AND-10 ships the PreviewSession shell, SurfaceBridge (resetInBackground, latch <= 500 ms), SeekController, QualityGovernor, PreviewSessionManager and the PreviewBackend interface that AND-16's MultiPlayerBackend implements. Meet the 'hand back now' criteria in ANDROID_LANE.md §5 AND-10. The playback criteria (exact seek ack, scrub coalescing, transient, A/V offset) are met through AND-16 later: list them in deferred as 're-run when AND-16 lands' and mark AND-10 done when everything else passes. example/integration_test/android_preview_test.dart drives MobileEditorEngine and ENG-02's mobile_preview_session.dart on the emulator. With any CompositionPlayer, detach with clearVideoSurface(surface); the no-arg overload throws in 1.11.1. Record emulator numbers for the ARCH §13.4 mid/low budgets; the device criteria are deferred: no device available.`,
  },
  {
    id: 'and-m3-fallback', tickets: ['AND-16'], deps: ['and-m3-preview'], external: ['ENG-06', 'AND16-SHIM'], model: 'opus',
    note: `Contingency preview engine, active because AND-01 was NO-GO. The owner signed its degradations on 2026-10-11 (ARCH D-43(e), D-45); this group runs only after ENG-06 assigned android/src/main/cpp/ (the JNI shim) and added its externalNativeBuild block. Owner decision points that shape AND-16 (BUILD_PLAN AND-16 amended criteria): layers beyond the tier's live decode budget play as paused-exact stills during playback only, while paused, scrub and exact seek are exact for every layer; an exact seek while playing may show the nearest decoded frame first, then refine (+30% allowed); under load drop a frame, never show a late or wrong one; adaptive quality full -> 1/2 -> 1/4 and back unless pinned; maxVisualSequences limits live preview only. Also provide a RenderedRangeHook (no-op by default) inside preview/fallback/ that AND-18 implements. If ENG-06 recorded GO instead, close AND-16 with status not_needed, citing AND-01's report. Build MultiPlayerBackend : PreviewBackend to the scope in AND-01.md §7. It overrides ARCH §13.3's pre-ENG-06 'Contingency' bullet and BUILD_PLAN's AND-16 spec text (one player per slot into a SurfaceTexture, drift fixed by seeking), which AND-01 measured as showing wrong frames:
- a deck pool with 2 decks per packing slot, each an ExoPlayer rendering into a PRIVATE ImageReader, imported as an OES texture through the HardwareBuffer JNI shim, with epoch-tagged frames;
- a Choreographer frame clock on the preview thread with a 2-frame lead, the hold/miss rule (drop a frame, never show a late one) and drift correction, following the audio master;
- audio slots: one ExoPlayer per audio interval colour with AND-08's speed and GainProcessor chain and a signed sink offset (V-N23);
- exact seek and scrub through the decks, structural re-plan by slot diff (setMediaItems on affected decks only), surface lifecycle, quality steps (ImageReader size) and thermal SEVERE;
- compositing through AND-17's LayerCompositorGl and AND-09's shaders; never edit their files or AND-10's.
Port from spikes/android_engine (ContingencyEngineProto.kt, ContingencyEngineTest.kt; read only) and split the code inside preview/fallback/. Write shim sources only where ENG-06 assigned them to AND-16, and never touch Gradle. If the shim directory or the Gradle block is missing from the tree, return AND-16 as blocked with a forMac request. Re-run AND-10's playback list through this backend (tests in androidTest/fallback/). Record emulator numbers; the mid-device transition/PiP criterion is deferred: no device available.`,
  },
  {
    id: 'and-m4-services', tickets: ['AND-13', 'AND-14', 'AND-15'], deps: ['eng08'], external: ['ENG-06', 'ENG-03'], model: 'opus',
    note: `Recorder, pickers/URI grants/permissions and drop target behind the calls ENG-03's Dart glue makes (mobile_jobs.dart, mobile_recorder.dart and the platform services; Mac-owned). Implement the service classes ENG-08's glue already calls. AND-13: the emulator mic is virtual; verify the WAV format, that an interruption keeps a valid file, and the denied/permanently-denied states; latency is an emulator number. AND-14: Photo Picker and V-D2 (persistence across relaunch, grant budget) on the API 35 emulator; run the API < 33 permission flows on Pixel_API_29 per the EMULATOR rule (defer only if that AVD is missing); quickHash must equal the core fixtures. AND-15: synthesized DragEvents with ClipData from a test ContentProvider; the cross-app drag from Files is a manual checklist item: if Pixel_Tablet_API_35 exists, try it there per the EMULATOR rule and record the evidence; otherwise 'deferred: Pixel_Tablet_API_35 not installed', left for the owner.`,
  },
  {
    id: 'and-m4-export', tickets: ['AND-11'], deps: ['and-m3-render', 'and-m3-text', 'and-m3-preview'], external: ['ENG-04'], model: 'opus',
    note: `Transformer export (AND-01: GO). ENG-04's mobile_export.dart (Mac) is the Dart side. Build export compositions with AND-08's mapper (target export) and AND-09's SpriteBandEffect. Define the ActiveExportStore format here; AND-12's service writes its detached records later (D-39). Test on the emulator: V-N13 (hvc1 tag) and V-N24 (no-audio, all-muted and images/text-only fixtures get a silent AAC 48 kHz stereo track). Record which encoder actually ran; the emulator may only have software HEVC, so defer the real-hardware preference. Test the selector with injected codec lists, including that a software or fallback encoder raises the preflight/progress warning. Exercise the portrait retry path with an injected refusal. Check 'interrupted after process death' with am kill or force-stop from an instrumented test. Preview suspension on minimal/low/mid tiers goes through AND-10's PreviewSessionManager. Owner decision 2026-10-11 (ARCH D-45, BUILD_PLAN AND-11 amended): preflight never refuses for sequence or layer counts; when the packed export plan needs more decoders than the device allows, ExportCoordinator hands the job to a MultiPassExport hook (interface in AND-11's coordinator, implemented later by AND-19) instead of failing; test it with a test double.`,
  },
  {
    id: 'and-m4-rpreview', tickets: ['AND-18'], deps: ['and-m3-fallback'], external: ['INT-06'], model: 'opus',
    note: `Render-preview renderer and playback swap-in (owner decision 2026-10-11, ARCH D-45, §13.3 'Over-budget layers and the render-preview cache'; BUILD_PLAN AND-18). RenderPreviewJob registered with AND-05's job registry: a Transformer export of a range plan through AND-08's mapper (target export at the preview canvas size and project fps, same effects, gating and working space) into <cache>/danaview/editor/renders/, H.264 all-intra (I-frame interval 0) or <= 0.5 s, video only, hardware encoder first; progress, cancel deletes the partial file, thermal SEVERE pauses, never runs during an export. RenderedRangeSwap implements AND-16's RenderedRangeHook: during playback one deck plays the cached file in place of every slot of the range, pre-rolled like a standby deck and switched at the range's exact frame boundaries under the hold/miss rule; paused, scrub and exact seek keep the normal decks; a patch touching a range drops it until the next setRenderedRanges. The Pigeon/glue additions (JobKindMsg.renderPreview, PreviewHostApi.setRenderedRanges, the powerState signal) come from the Mac's INT-06 ([INTEGRATION], ARCH D-45, §12.6), which this group waits for: INT-06 leaves notSupportedOnDevice placeholders headed // OWNER: AND-18 in preview/render/ (render-preview job service, rendered-range handler, power signal); replace them keeping their names and signatures, never edit glue or Pigeon files, and report a signature mismatch in forMac as an INT-06 defect. Never edit AND-16's, AND-10's or AND-11's files. Tests in src/test/.../render/ and src/androidTest/.../render/: rendered range vs live (barcode exact, SSIM >= 0.99), 0 wrong frames across range boundaries at 24/30/60 fps, param patch inside a range falls back to live on the next frame, cancel and process death leave no partial file. Emulator numbers recorded; device numbers deferred: no device available.`,
  },
  {
    id: 'and-m4-precomp', tickets: ['AND-19'], deps: ['and-m4-export'], external: [], model: 'opus',
    note: `Multi-pass export precompose (owner decision 2026-10-11, ARCH D-45(B), §14.3 'Multi-pass precompose'; BUILD_PLAN AND-19). Export never refuses for sequence counts. PrecomposePlanner: from the packed export plan and maxVisualSequences / codec maxSupportedInstances - 2, decide how many bottom slots each pass renders. PrecomposePass: a video-only Transformer export of the background plus those slots through AND-08's mapper (target export, same frame processor, HDR mode and working colour space) at the export size into work/export-<jobId>/pre-<n>.mp4, all-intra (I-frame interval 0) or >= 4x the export bitrate; repeat until the rest fits; the final pass maps the intermediate as an ordinary bottom video layer on the export frame grid (rule-frame clipping, ARCH §13.3) and mixes audio once. One progress fraction over all passes; cancel, failure and process death delete intermediates; disk preflight counts them. Plug into AND-11's MultiPassExport hook; never edit AND-11's files (if the hook is missing, return blocked with a FIX-AND-11 request in forMac). Tests in src/test/.../precompose/ and src/androidTest/.../precompose/: precomposed vs single-pass export of the same plan (SSIM >= 0.995 per frame, grid-cut 100% at 24/30/60 fps, identical frame count, audio within QA-11 tolerances); maxVisualSequences forced to 2 exports a 6-slot project; HDR/tone-mapped and rotated sources match; cancel in each pass leaves no intermediates.`,
  },
  {
    id: 'and-m5', tickets: ['AND-12'], deps: ['and-m4-export'], external: [], model: 'opus',
    note: `ExportService foreground service: type mediaProcessing on API 35+, dataSync on 29-34. It shows a determinate progress notification with a Cancel action that works with the activity destroyed; API 35 onTimeout -> interrupted. BackgroundGuard leases live in the same service. MediaStoreSaver uses RELATIVE_PATH Movies/Danaview and IS_PENDING. FileHandoff uses ACTION_CREATE_DOCUMENT and ACTION_SEND via the FileProvider '<applicationId>.danaview.editor.files' declared in ENG-08's manifest. Implement detached completion (D-39) with AND-11's ActiveExportStore. Check the FGS types on Pixel_9_Pro_XL_API_35, Pixel_API_34 and Pixel_API_29 per the EMULATOR rule; defer only an AVD that is missing. Run the swipe-from-recents case with UiAutomator on the emulator, and verify the gallery insert with a MediaStore query. If the emulator image has no Photos app, defer that visual check.`,
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
for (const t of ['ENG-02', 'ENG-03', 'ENG-04', 'INT-06', 'AND16-SHIM']) {
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
  else if (macBlockers(g.id).length) log(`waiting for Mac/owner: ${label} needs ${macBlockers(g.id).join(', ')}`)
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
  if (macBlockers(id).length) return `waiting for Mac/owner: ${macBlockers(id).join(', ')}`
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

// Only finished tickets are committed; partial or blocked work stays in the tree for the next run.
const commitPlan = []
const leftInTree = []
for (const id of built) {
  for (const t of results[id].tickets) {
    if (!t.files || !t.files.length) continue
    if (t.status !== 'done' && t.status !== 'not_needed') {
      leftInTree.push({ ticket: t.id, status: t.status, files: t.files })
      continue
    }
    commitPlan.push({ ticket: t.id, status: t.status, message: `feat(editor): ${t.id} ${TITLES[t.id] || ''}`.trim(), files: t.files })
  }
}

const forMac = built
  .map((id) => ({ group: id, note: results[id].forMac }))
  .filter((x) => x.note && !/^\s*(none|n\/a)?\.?\s*$/i.test(x.note))

if (!built.length) {
  log('no lane group was built in this run')
  return { built, preloaded: Object.keys(PRELOADED), waitingForMac, notFinished: notFinishedList, commitPlan, leftInTree, forMac, review: null, fix: null, preloadForNextRun }
}

if (!RUN_REVIEW) {
  log('review skipped (args.review = false)')
  return {
    built, preloaded: Object.keys(PRELOADED), waitingForMac, notFinished: notFinishedList,
    groups: built.map((id) => ({ id, tickets: results[id].tickets.map((t) => `${t.id}:${t.status}`), deferred: results[id].deferred })),
    commitPlan, leftInTree, forMac, review: null, fix: null, preloadForNextRun,
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
  ? 'ENG-06 HAS landed: the Pigeon surface, glue, build.gradle.kts, lint.xml and manifest are frozen; findings in them go to forMac, not fixed here.'
  : built.includes('eng08')
    ? 'ENG-08 was built in this run and is not committed yet: findings in its glue, build.gradle.kts, lint.xml and manifest can be fixed here and go into its commit.'
    : 'ENG-08 was committed in an earlier run and may already be on the Mac: do not edit its glue, build.gradle.kts, lint.xml or manifest. Report findings there as needs_mac with the exact fix; the lead agrees a fix(editor): ENG-08 commit with the owner before the Mac starts ENG-06.'

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
- Threading and lifecycle: GL only on danaview-gl; no main-thread blocking beyond the 500 ms surface latch; HandlerThread/Looper teardown; leaked codecs, surfaces, EGL contexts or SurfaceTextures; cancellation and partial-file cleanup; activity/Flutter engine detach and reattach.
- Contract drift against the Dart engine API (packages/danaview_editor_engine_api) and the frozen Pigeon surface (packages/danaview_editor_engine/pigeons/engine_api.dart and the generated Kotlin): field meanings, units, error codes, events.
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
Then rerun, all green: the Gradle build through the example host, the full :danaview_editor_engine:testDebugUnitTest, lint, and the affected instrumented tests on the emulator (under the lock; stop the emulator afterwards if no lock exists). Report each finding as fixed, skipped or needs_mac, with the files you changed.
Findings:
${findings.map((f, i) => `${i + 1}. [${f.severity}] ${f.ticket} ${f.file}: ${f.issue}\n   evidence: ${f.evidence}\n   fix: ${f.fix}`).join('\n')}`, { label: 'fix', phase: 'Fix', schema: FIX_SCHEMA, model: 'opus' }) : null

if (fix && fix.results) {
  // Group fixed files by ticket. A ticket committed in this run takes its fixes into its own entry;
  // a ticket left in the tree keeps them there; a ticket from an earlier run gets a fix(editor) entry.
  const fixByTicket = {}
  for (const x of fix.results) {
    if (x.outcome !== 'fixed' || !(x.files || []).length) continue
    const t = String((findings[x.finding - 1] || {}).ticket || 'review').trim()
    fixByTicket[t] = uniq((fixByTicket[t] || []).concat(x.files))
  }
  const builtTickets = new Set(built.flatMap((id) => results[id].tickets.map((t) => t.id)))
  const planned = new Set(commitPlan.flatMap((c) => c.files))
  for (const t of Object.keys(fixByTicket)) {
    const entry = commitPlan.find((c) => c.ticket === t)
    if (entry) {
      entry.files = uniq(entry.files.concat(fixByTicket[t]))
      continue
    }
    if (builtTickets.has(t)) continue
    const files = fixByTicket[t].filter((f) => !planned.has(f))
    if (files.length) commitPlan.push({ ticket: t, status: 'done', message: `fix(editor): ${t} review fixes`, files })
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
  leftInTree,
  forMac,
  review: review ? { verdict: review.verdict, findings: review.findings } : null,
  fix: fix || (review ? 'no findings' : 'review did not return'),
  preloadForNextRun,
}
