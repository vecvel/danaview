// OWNER: ENG-07 (frozen by ENG-06)
//
// Argument validation of the host APIs (ARCH §12.6). Dart is trusted but buggy callers must fail
// with a typed error instead of reaching media code: contract violations are `internal`
// ("invalid argument <name>: <reason>", never retryable), empty plan/patch payloads are
// `planInvalid`, output paths outside the editor roots and backup exclusions outside the editor or
// speech roots are `permissionDenied` (ARCH §20.1, D-44). Messages never contain the value of a
// path argument.

import Flutter
import Foundation

enum Validate {
    /// Longest accepted time (100 h in µs).
    static let maxTimeUs: Int64 = 100 * 3600 * 1_000_000
    /// Largest plan or patch payload (64 MiB).
    static let maxPlanBytes = 64 << 20
    /// Largest transient payload (1 MiB).
    static let maxTransientBytes = 1 << 20
    /// Largest bookmark (64 KiB).
    static let maxBookmarkBytes = 64 << 10

    // MARK: Scalars

    /// Ids (sessions, items, jobs, requests, recordings, leases, fingerprints): non-empty, at most
    /// 256 bytes, no control characters, no path separators, not `.` or `..`.
    static func id(_ value: String, _ name: String) throws {
        guard !value.isEmpty else { throw EngineError.invalidArgument(name, "empty") }
        guard value.utf8.count <= 256 else { throw EngineError.invalidArgument(name, "longer than 256 bytes") }
        guard value != "." && value != ".." else { throw EngineError.invalidArgument(name, "reserved name") }
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\"))
        guard value.rangeOfCharacter(from: forbidden) == nil else {
            throw EngineError.invalidArgument(name, "contains a control character or a path separator")
        }
    }

    static func timeUs(_ value: Int64, _ name: String) throws {
        guard value >= 0 && value <= maxTimeUs else { throw EngineError.invalidArgument(name, "out of range") }
    }

    static func int(_ value: Int64, _ name: String, _ range: ClosedRange<Int64>) throws {
        guard range.contains(value) else {
            throw EngineError.invalidArgument(name, "\(value) not in \(range.lowerBound)...\(range.upperBound)")
        }
    }

    static func unit(_ value: Double, _ name: String) throws {
        guard value.isFinite && value >= 0 && value <= 1 else { throw EngineError.invalidArgument(name, "not in 0...1") }
    }

    static func text(_ value: String, _ name: String, maxBytes: Int = 1024, allowEmpty: Bool = true) throws {
        guard allowEmpty || !value.isEmpty else { throw EngineError.invalidArgument(name, "empty") }
        guard value.utf8.count <= maxBytes else { throw EngineError.invalidArgument(name, "longer than \(maxBytes) bytes") }
        guard !value.contains("\u{0}") else { throw EngineError.invalidArgument(name, "contains NUL") }
    }

    /// A file name (no directories).
    static func fileName(_ value: String, _ name: String) throws {
        try id(value, name)
        guard value.utf8.count <= 255 else { throw EngineError.invalidArgument(name, "longer than 255 bytes") }
    }

    // MARK: Payloads

    /// A plan or patch payload (UTF-8 JSON). Empty → `planInvalid`.
    static func plan(_ data: FlutterStandardTypedData, _ name: String) throws -> Data {
        let bytes = data.data
        guard !bytes.isEmpty else { throw EngineError(.planInvalid, "\(name) is empty") }
        guard bytes.count <= maxPlanBytes else { throw EngineError(.planInvalid, "\(name) exceeds \(maxPlanBytes) bytes") }
        return bytes
    }

    /// A transient parameter payload (UTF-8 JSON).
    static func transient(_ data: FlutterStandardTypedData) throws -> Data {
        let bytes = data.data
        guard !bytes.isEmpty else { throw EngineError.invalidArgument("params", "empty") }
        guard bytes.count <= maxTransientBytes else { throw EngineError.invalidArgument("params", "too large") }
        return bytes
    }

    static func bookmark(_ data: FlutterStandardTypedData, _ name: String) throws -> Data {
        let bytes = data.data
        guard !bytes.isEmpty else { throw EngineError.invalidArgument(name, "empty") }
        guard bytes.count <= maxBookmarkBytes else { throw EngineError.invalidArgument(name, "too large") }
        return bytes
    }

    // MARK: Media

    /// A `ResolvedMediaMsg`: file URI or absolute path, fingerprint id, optional bookmark.
    static func media(_ media: ResolvedMediaMsg, _ name: String = "media") throws -> URL {
        try id(media.fingerprint, "\(name).fingerprint")
        if let bookmark = media.bookmark {
            _ = try self.bookmark(bookmark, "\(name).bookmark")
        }
        return try Paths.fileURL(fromPathOrUri: media.uri, name: "\(name).uri")
    }

    static func mediaRef(_ media: MediaRefMsg) throws -> URL {
        if let bookmark = media.bookmark {
            _ = try self.bookmark(bookmark, "media.bookmark")
        }
        return try Paths.fileURL(fromPathOrUri: media.uri, name: "media.uri")
    }

    // MARK: Messages

    static func previewConfig(_ config: PreviewConfigMsg) throws {
        try int(config.canvasWidth, "config.canvasWidth", 16...8192)
        try int(config.canvasHeight, "config.canvasHeight", 16...8192)
        try int(config.fps, "config.fps", 1...240)
    }

    static func loop(_ loop: LoopMsg?) throws {
        guard let loop = loop else { return }
        try timeUs(loop.startUs, "loop.startUs")
        try timeUs(loop.endUs, "loop.endUs")
        guard loop.startUs < loop.endUs else { throw EngineError.invalidArgument("loop", "start must precede end") }
    }

    static func editingMode(_ mode: EditingModeMsg) throws {
        switch mode.kind {
        case .normal:
            break
        case .cropSource, .matte:
            guard let itemId = mode.itemId else { throw EngineError.invalidArgument("mode.itemId", "required for \(mode.kind)") }
            try id(itemId, "mode.itemId")
        }
    }

    /// Looks of `renderLookStills`; returns the LUT file URLs, which must lie inside the roots.
    static func looks(_ looks: [LookSpecMsg], paths: Paths) throws -> [URL] {
        guard !looks.isEmpty else { throw EngineError.invalidArgument("looks", "empty") }
        guard looks.count <= 64 else { throw EngineError.invalidArgument("looks", "more than 64") }
        return try looks.enumerated().map { index, look in
            try id(look.id, "looks[\(index)].id")
            try int(look.lutSize, "looks[\(index)].lutSize", 2...65)
            try unit(look.intensity, "looks[\(index)].intensity")
            let url = try Paths.fileURL(fromPathOrUri: look.lutUri, name: "looks[\(index)].lutUri")
            return try paths.requireInside(url.path, roots: paths.writableRoots, name: "looks[\(index)].lutUri")
        }
    }

    static func thumbnailRequest(_ request: ThumbnailRequestMsg) throws -> URL {
        let url = try media(request.media, "request.media")
        try int(request.intervalMs, "request.intervalMs", 1...3_600_000)
        try int(request.tileIndex, "request.tileIndex", 0...10_000_000)
        try int(request.heightPx, "request.heightPx", 8...1024)
        try int(request.framesPerTile, "request.framesPerTile", 1...64)
        return url
    }

    /// A media job request; returns the media URL and the validated output URL (nil for kinds
    /// without one).
    static func jobRequest(_ request: JobRequestMsg, paths: Paths) throws -> (media: URL, output: URL?) {
        let mediaURL = try media(request.media, "request.media")
        if let stream = request.audioStream {
            try int(stream, "request.audioStream", 0...63)
        }
        func requireRange() throws {
            guard let start = request.sourceStartUs, let end = request.sourceEndUs else {
                throw EngineError.invalidArgument("request.sourceStartUs", "range required for \(request.kind)")
            }
            try timeUs(start, "request.sourceStartUs")
            try timeUs(end, "request.sourceEndUs")
            guard start < end else { throw EngineError.invalidArgument("request.sourceEndUs", "must follow sourceStartUs") }
        }
        func requireOutput() throws -> URL {
            guard let output = request.outputPath else {
                throw EngineError.invalidArgument("request.outputPath", "required for \(request.kind)")
            }
            return try paths.requireWritable(output, name: "request.outputPath")
        }
        switch request.kind {
        case .waveform, .proxy:
            return (mediaURL, nil)
        case .reverse, .speechAudio:
            try requireRange()
            return (mediaURL, try requireOutput())
        case .freeze:
            guard let time = request.sourceTimeUs else {
                throw EngineError.invalidArgument("request.sourceTimeUs", "required for freeze")
            }
            try timeUs(time, "request.sourceTimeUs")
            return (mediaURL, try requireOutput())
        case .export:
            throw EngineError.invalidArgument("request.kind", "exports start through ExportHostApi")
        }
    }

    static func encodeSettings(_ settings: EncodeSettingsMsg) throws {
        try int(settings.width, "settings.width", 16...8192)
        try int(settings.height, "settings.height", 16...8192)
        guard settings.width % 2 == 0 && settings.height % 2 == 0 else {
            throw EngineError.invalidArgument("settings", "width and height must be even")
        }
        try int(settings.fps, "settings.fps", 1...240)
        try int(settings.videoBitrate, "settings.videoBitrate", 1...1_000_000_000)
        try int(settings.audioBitrate, "settings.audioBitrate", 1...10_000_000)
        try int(settings.audioSampleRate, "settings.audioSampleRate", 8_000...192_000)
        try int(settings.audioChannels, "settings.audioChannels", 1...8)
        try int(settings.keyframeIntervalMs, "settings.keyframeIntervalMs", 1...600_000)
    }

    static func pickRequest(_ request: MediaPickRequestMsg) throws {
        guard !request.kinds.isEmpty else { throw EngineError.invalidArgument("request.kinds", "empty") }
    }
}
