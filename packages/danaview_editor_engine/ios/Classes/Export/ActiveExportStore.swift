// OWNER: IOS-13
//
// Persisted export records (D-22, D-39, ARCH §14.1 step 6–7, §14.2). The export coordinator
// (IOS-12) discovers this class as its `ExportJobLifecycle` hook (`init(context:)`), calls it on
// the export queue and merges `records()` into `activeJobs()` after its own (deduplicated by job
// id, so a job running in this process or one whose job directory survived is reported by the
// coordinator first).
//
// The store keeps `<supportRoot>/exports/active-exports.json` (outside work/, so the launch wipe
// never touches it), written atomically:
// - running entries (exportStarted → exportCompleted / exportEnded). After process death an entry
//   whose job directory still holds a checkpoint with a finished segment reports `resumable`
//   (doneFraction from the checkpoint); otherwise — no directory left, or nothing finished — it
//   reports `interrupted`, until consumed (UX-39 shows it once and consumes it).
// - completedWhileDetached entries (D-39): when a job completes with no Dart listener attached,
//   the store takes the handoff over (exportCompleted returns true, the coordinator then deletes
//   the job directory): the output is exempted from the work/ wipe for 7 days, and with
//   `whenDetached = saveToGallery` and add-only Photos access already authorized, PhotosSaver saves
//   it natively (`savedToGallery`, `savedUri` = the asset's localIdentifier). The record is
//   reported until consumed, then forgotten; the output stays for Dart's handoff and its
//   OwnedFileDeleter. Records whose 7 days passed are dropped (the wipe then deletes the output).
// - Continued background (iPad, `BackgroundExecution.kind == .continued`): exportStarted begins
//   the system task with the checkpoint's doneFraction as progress; completion/end finish it.
// Nothing here logs paths or titles.

import Foundation

/// Native Photos save of a detached completion (PhotosSaver; tests inject fakes).
protocol DetachedGallerySaving: AnyObject {
    func saveDetached(fileURL: URL, completion: @escaping (_ saved: Bool, _ localIdentifier: String?) -> Void)
}

extension PhotosSaver: DetachedGallerySaving {}

final class ActiveExportStore: ExportJobLifecycle {
    static let directoryName = "exports"
    static let fileName = "active-exports.json"
    /// How long a completedWhileDetached record (and the output's wipe exemption) lives.
    static let detachedLifetime = WorkExemptions.detachedOutputLifetime

    struct Entry: Codable, Equatable {
        enum State: String, Codable {
            case running
            case completedDetached
        }

        var jobId: String
        var state: State
        var settings: EncoderSettings?
        /// `saveToGallery` or `keepForLater`.
        var whenDetached: String
        var result: ExportJob.StoredResult?
        var savedToGallery = false
        var savedUri: String?
        var createdAt: Date
        /// completedDetached: when the record and the output's exemption end.
        var expiresAt: Date?
    }

    private struct File: Codable {
        var version = 1
        var entries: [Entry] = []
    }

    private let context: EngineContext?
    private let paths: () -> Paths?
    private let gallery: DetachedGallerySaving
    let background: BackgroundExecution
    private let now: () -> Date
    private let lock = NSLock()

    convenience init(context: EngineContext) {
        self.init(
            context: context, paths: { [weak context] in context?.paths }, gallery: PhotosSaver(context: context),
            background: BackgroundExecution())
    }

    /// Tests inject the roots, the gallery, the background execution and the clock.
    init(context: EngineContext?, paths: @escaping () -> Paths?, gallery: DetachedGallerySaving, background: BackgroundExecution,
         now: @escaping () -> Date = Date.init) {
        self.context = context
        self.paths = paths
        self.gallery = gallery
        self.background = background
        self.now = now
    }

    static func url(_ paths: Paths) -> URL {
        paths.supportRoot.appendingPathComponent(directoryName, isDirectory: true).appendingPathComponent(fileName)
    }

    // MARK: ExportJobLifecycle

    func exportStarted(jobId: String, settings: EncodeSettingsMsg, title: String, whenDetached: DetachedHandoffMsg) {
        let entry = Entry(
            jobId: jobId, state: .running, settings: try? EncoderSettings(msg: settings),
            whenDetached: ActiveExportStore.name(whenDetached), result: nil, createdAt: now(), expiresAt: nil)
        mutate { entries in
            entries.removeAll { $0.jobId == jobId }
            entries.append(entry)
        }
        let directory = paths().map { ExportJob.directory(for: jobId, work: $0.work) }
        background.begin(
            jobId: jobId, title: title,
            progress: { directory.flatMap { SegmentCheckpoint.load(from: $0)?.doneFraction } ?? 0 },
            onExpired: { jobId in
                // The system suspends the app next; the pipeline stops on the encoder loss and the
                // coordinator keeps the checkpoint (the paused path).
                Log.info(.export, "export \(jobId): background time over; the export pauses")
            })
    }

    func exportCompleted(jobId: String, result: ExportResultMsg, listenerAttached: Bool, whenDetached: DetachedHandoffMsg) -> Bool {
        background.end(jobId: jobId, success: true)
        guard !listenerAttached, let paths = paths() else {
            mutate { $0.removeAll { $0.jobId == jobId } }
            return false
        }
        let output = URL(fileURLWithPath: result.path)
        let expires = now().addingTimeInterval(ActiveExportStore.detachedLifetime)
        WorkExemptions.add(output, expires: expires, paths: paths)
        let stored = ExportJob.StoredResult(
            path: result.path, bytes: result.bytes, durationUs: result.durationUs, videoEncoderName: result.videoEncoderName,
            hardwareEncoder: result.hardwareEncoder)
        mutate { entries in
            var entry = entries.first { $0.jobId == jobId }
                ?? Entry(jobId: jobId, state: .running, settings: nil, whenDetached: ActiveExportStore.name(whenDetached),
                         result: nil, createdAt: self.now(), expiresAt: nil)
            entries.removeAll { $0.jobId == jobId }
            entry.state = .completedDetached
            entry.whenDetached = ActiveExportStore.name(whenDetached)
            entry.result = stored
            entry.expiresAt = expires
            entries.append(entry)
        }
        Log.info(.export, "export \(jobId): completed while detached")
        if whenDetached == .saveToGallery {
            gallery.saveDetached(fileURL: output) { [weak self] saved, identifier in
                guard saved, let self = self else { return }
                self.mutate { entries in
                    guard let i = entries.firstIndex(where: { $0.jobId == jobId && $0.state == .completedDetached }) else { return }
                    entries[i].savedToGallery = true
                    entries[i].savedUri = identifier
                }
                Log.info(.export, "export \(jobId): saved to Photos while detached")
            }
        }
        return true
    }

    func exportEnded(jobId: String) {
        background.end(jobId: jobId, success: false)
        mutate { $0.removeAll { $0.jobId == jobId } }
    }

    func records() -> [ExportJobRecordMsg] {
        guard let paths = paths() else { return [] }
        let current = now()
        var expired: [Entry] = []
        let entries = mutate { entries -> [Entry] in
            expired = entries.filter { $0.state == .completedDetached && ($0.expiresAt ?? .distantFuture) <= current }
            entries.removeAll { e in expired.contains { $0.jobId == e.jobId } }
            return entries
        }
        for entry in expired {
            if let path = entry.result?.path { WorkExemptions.remove(URL(fileURLWithPath: path), paths: paths) }
        }
        return entries.sorted { $0.createdAt < $1.createdAt }.map { entry in
            let settings = entry.settings?.msg
            switch entry.state {
            case .completedDetached:
                return ExportJobRecordMsg(
                    jobId: entry.jobId, state: .completedWhileDetached, doneFraction: 1, result: entry.result?.msg,
                    savedToGallery: entry.savedToGallery, savedUri: entry.savedUri, settings: settings)
            case .running:
                let checkpoint = SegmentCheckpoint.load(from: ExportJob.directory(for: entry.jobId, work: paths.work))
                let resumable = checkpoint?.completed.contains { $0.frames > 0 } ?? false
                return ExportJobRecordMsg(
                    jobId: entry.jobId, state: resumable ? .resumable : .interrupted,
                    doneFraction: resumable ? checkpoint?.doneFraction : 0, result: nil, savedToGallery: false, savedUri: nil,
                    settings: settings)
            }
        }
    }

    func consume(jobId: String) {
        var removed: Entry?
        mutate { entries in
            removed = entries.first { $0.jobId == jobId }
            entries.removeAll { $0.jobId == jobId }
        }
        // The output of a detached completion stays for Dart's handoff; only its exemption ends.
        if let entry = removed, entry.state == .completedDetached, let path = entry.result?.path, let paths = paths() {
            WorkExemptions.remove(URL(fileURLWithPath: path), paths: paths)
        }
    }

    // MARK: Persistence

    /// The persisted entries (tests).
    var entries: [Entry] { mutate { $0 } }

    @discardableResult
    private func mutate<T>(_ body: (inout [Entry]) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let paths = paths() else {
            var scratch: [Entry] = []
            return body(&scratch)
        }
        let url = ActiveExportStore.url(paths)
        var file = ActiveExportStore.load(url)
        let before = file.entries
        let value = body(&file.entries)
        if file.entries != before { ActiveExportStore.save(file, to: url) }
        return value
    }

    private static func load(_ url: URL) -> File {
        guard let data = try? Data(contentsOf: url) else { return File() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(File.self, from: data)) ?? File()
    }

    private static func save(_ file: File, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(file).write(to: url, options: .atomic)
        } catch {
            Log.error(.export, "active export records not saved: \(EngineError.from(error).code.rawValue)")
        }
    }

    private static func name(_ handoff: DetachedHandoffMsg) -> String {
        handoff == .keepForLater ? "keepForLater" : "saveToGallery"
    }
}
