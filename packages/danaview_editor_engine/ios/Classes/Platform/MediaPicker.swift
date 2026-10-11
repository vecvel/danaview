// OWNER: IOS-15
//
// Pickers (ARCH §9.1, §15), on main:
// - Photos: PHPickerViewController without a photo library (no NSPhotoLibraryUsageDescription),
//   `preferredAssetRepresentationMode = .current` (HEVC and other originals are never
//   transcoded), multi-select when requested, video/image filters. Inside
//   `NSItemProvider.loadFileRepresentation`'s completion handler — before it returns, because the
//   system deletes its temp file then and Dart only runs after the channel hop — the file is
//   cloned with APFS `clonefile` (copy fallback) into `<cache>/danaview/editor/work/picks/<uuid>/<name>`
//   and that path is returned with `isTemporaryCopy = true`. Dart hashes it and moves it into
//   `media/` (ARCH §9.1); `work/picks/` older than 24 h is wiped by DiskCache.
// - Files: UIDocumentPickerViewController with `asCopy: false` (the user's file stays where it
//   is): video, audio, image, `.cube` (public.data + extension check) and srt/vtt. Each URL comes
//   back with a bookmark made inside its security scope (`origin = files`, not a temp copy).
// - An empty list means cancelled. One picker at a time (`busy` otherwise).
//
// `ItemProviderImport` is shared with the drop target (IOS-16): it classifies providers by kind,
// and loads/clones them into a work directory.

import Flutter
import Foundation
import PhotosUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Item provider import (picks and drops)

enum ItemProviderImport {
    /// Extensions accepted for the kinds that have no system UTType.
    static let lutExtensions: Set<String> = ["cube"]
    static let subtitleExtensions: Set<String> = ["srt", "vtt"]

    /// The type identifier to load from [provider] and the kind it matched, or nil when no
    /// registered representation is one of [kinds].
    static func classify(_ provider: NSItemProvider, kinds: Set<MediaPickKindMsg>) -> (typeIdentifier: String, kind: MediaPickKindMsg)? {
        let suggestedExtension = provider.suggestedName.map { ($0 as NSString).pathExtension.lowercased() } ?? ""
        for identifier in provider.registeredTypeIdentifiers {
            guard let type = UTType(identifier) else { continue }
            if let kind = kind(of: type, extension: suggestedExtension, kinds: kinds) {
                return (identifier, kind)
            }
        }
        return nil
    }

    /// The kind of a file of [type] / [ext] among [kinds].
    static func kind(of type: UTType?, extension ext: String, kinds: Set<MediaPickKindMsg>) -> MediaPickKindMsg? {
        let typeExtension = type?.preferredFilenameExtension?.lowercased() ?? ""
        let extensions: Set<String> = [ext.lowercased(), typeExtension]
        if kinds.contains(.lut), !extensions.isDisjoint(with: lutExtensions) { return .lut }
        if kinds.contains(.subtitle), !extensions.isDisjoint(with: subtitleExtensions) { return .subtitle }
        guard let type = type else { return nil }
        if kinds.contains(.video), type.conforms(to: .movie) { return .video }
        if kinds.contains(.audio), type.conforms(to: .audio) { return .audio }
        if kinds.contains(.image), type.conforms(to: .image) { return .image }
        return nil
    }

    /// Loads every supported provider into `<directory>/<uuid>/<name>` (in order; unsupported or
    /// failed items are skipped). [completion] runs once on an arbitrary queue with the items, or
    /// with the first error when every supported item failed.
    static func load(
        _ providers: [NSItemProvider], kinds: Set<MediaPickKindMsg>, into directory: URL, origin: PickOriginMsg,
        completion: @escaping (Result<[PickedMediaMsg], Error>) -> Void
    ) {
        let group = DispatchGroup()
        let lock = NSLock()
        var results = [PickedMediaMsg?](repeating: nil, count: providers.count)
        var firstError: Error?
        var attempted = 0
        for (index, provider) in providers.enumerated() {
            guard let (typeIdentifier, _) = classify(provider, kinds: kinds) else { continue }
            attempted += 1
            group.enter()
            _ = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                // Runs before the provider deletes its temp file: clone it now.
                defer { group.leave() }
                do {
                    guard let url = url else { throw error.map(EngineError.from) ?? EngineError(.io, "item has no file") }
                    let name = displayName(suggested: provider.suggestedName, file: url)
                    let copy = try cloneIntoWork(url, directory: directory, name: name)
                    let size = (try? FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? NSNumber)?.int64Value
                    let item = PickedMediaMsg(
                        uri: copy.absoluteString, displayName: name, origin: origin, isTemporaryCopy: true, bookmark: nil,
                        sizeBytes: size)
                    lock.lock()
                    results[index] = item
                    lock.unlock()
                } catch {
                    Log.error(.platform, "item load failed: \(EngineError.from(error).code.rawValue)")
                    lock.lock()
                    if firstError == nil { firstError = error }
                    lock.unlock()
                }
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            let items = results.compactMap { $0 }
            if items.isEmpty, attempted > 0, let error = firstError {
                completion(.failure(EngineError.from(error)))
            } else {
                completion(.success(items))
            }
        }
    }

    /// The user-facing name of an item: the suggested name with the file's extension.
    static func displayName(suggested: String?, file: URL) -> String {
        let ext = file.pathExtension
        guard var name = suggested?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return sanitize(file.lastPathComponent)
        }
        if !ext.isEmpty && !sameFileType((name as NSString).pathExtension, ext) {
            name += "." + ext
        }
        return sanitize(name)
    }

    /// Whether two extensions name the same file type (`jpg`/`jpeg`, `MOV`/`mov`, `tif`/`tiff`).
    static func sameFileType(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        if a == b { return true }
        guard !a.isEmpty, !b.isEmpty, let typeA = UTType(filenameExtension: a), let typeB = UTType(filenameExtension: b),
            !typeA.isDynamic, !typeB.isDynamic
        else { return false }
        return typeA == typeB
    }

    /// A single safe path component (no separators, NUL or leading dots; at most 200 UTF-8 bytes).
    static func sanitize(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\u{0}", with: "")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.isEmpty { cleaned = "media" }
        while cleaned.utf8.count > 200 {
            let ext = (cleaned as NSString).pathExtension
            let stem = (cleaned as NSString).deletingPathExtension
            guard stem.count > 1 else { break }
            cleaned = String(stem.dropLast(max(1, stem.count / 4))) + (ext.isEmpty ? "" : "." + ext)
        }
        return cleaned
    }

    /// Clones [source] into a new `<directory>/<uuid>/<name>` (APFS clonefile, copy fallback).
    static func cloneIntoWork(_ source: URL, directory: URL, name: String) throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw EngineError.from(error)
        }
        let destination = folder.appendingPathComponent(sanitize(name), isDirectory: false)
        if clonefile(source.path, destination.path, 0) == 0 { return destination }
        let cloneErrno = errno
        Log.debug(.platform, "clonefile failed (errno \(cloneErrno)); copying")
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw EngineError.from(error)
        }
    }
}

// MARK: - Picker

final class MediaPicker: NSObject, MediaPicking {
    private let context: EngineContext
    /// The running picker session (main thread); retained until it replies.
    private var active: AnyObject?

    init(context: EngineContext) {
        self.context = context
    }

    func pick(_ request: MediaPickRequestMsg, reply: @escaping EngineReply<[PickedMediaMsg]>) {
        guard active == nil else {
            reply(.failure(EngineError(.busy, "a picker is already open", retryable: true)))
            return
        }
        do {
            let paths = try context.requirePaths()
            guard let presenter = context.presentingViewController() else {
                throw EngineError(.internal, "no view controller to present the picker")
            }
            let finish: EngineReply<[PickedMediaMsg]> = { [weak self] result in
                DispatchQueue.main.async {
                    self?.active = nil
                    reply(result)
                }
            }
            let kinds = Set(request.kinds)
            switch request.source {
            case .photos:
                let configuration = try MediaPicker.photosConfiguration(request)
                let session = PhotosPickSession(kinds: kinds, directory: paths.workPicks, reply: finish)
                let controller = PHPickerViewController(configuration: configuration)
                controller.delegate = session
                controller.presentationController?.delegate = session
                active = session
                presenter.present(controller, animated: true)
            case .files:
                let controller = UIDocumentPickerViewController(
                    forOpeningContentTypes: MediaPicker.documentTypes(kinds), asCopy: false)
                controller.allowsMultipleSelection = request.multiple
                let session = FilesPickSession(kinds: kinds, reply: finish)
                controller.delegate = session
                controller.presentationController?.delegate = session
                active = session
                presenter.present(controller, animated: true)
            }
        } catch {
            reply(.failure(error))
        }
    }

    /// The PHPicker configuration of [request] (no library: no permission prompt).
    static func photosConfiguration(_ request: MediaPickRequestMsg) throws -> PHPickerConfiguration {
        var configuration = PHPickerConfiguration()
        configuration.preferredAssetRepresentationMode = .current
        configuration.selectionLimit = request.multiple ? 0 : 1
        let kinds = Set(request.kinds)
        switch (kinds.contains(.video), kinds.contains(.image)) {
        case (true, true): configuration.filter = .any(of: [.videos, .images])
        case (true, false): configuration.filter = .videos
        case (false, true): configuration.filter = .images
        case (false, false):
            throw EngineError.invalidArgument("request.kinds", "Photos offers only video and image")
        }
        return configuration
    }

    /// Content types the document picker offers for [kinds].
    static func documentTypes(_ kinds: Set<MediaPickKindMsg>) -> [UTType] {
        var types: [UTType] = []
        if kinds.contains(.video) { types.append(.movie) }
        if kinds.contains(.audio) { types.append(.audio) }
        if kinds.contains(.image) { types.append(.image) }
        if kinds.contains(.subtitle) {
            types += ["srt", "vtt"].compactMap { UTType(filenameExtension: $0) }
        }
        // `.cube` has no system type: offer public.data and check the extension after the pick.
        if kinds.contains(.lut) || kinds.contains(.subtitle) { types.append(.data) }
        return types
    }

    /// The picked Files URLs of [kinds] as messages with bookmarks (security scope held while
    /// the bookmark and size are read).
    static func filesItems(_ urls: [URL], kinds: Set<MediaPickKindMsg>, scopes: ScopedAccessRegistry = .shared) -> [PickedMediaMsg] {
        urls.compactMap { url in
            let ext = url.pathExtension
            guard ItemProviderImport.kind(of: UTType(filenameExtension: ext), extension: ext, kinds: kinds) != nil else {
                Log.info(.platform, "picked file of an unsupported kind skipped")
                return nil
            }
            return scopes.with(url) {
                let bookmark = try? MediaAccess.bookmarkData(url)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
                return PickedMediaMsg(
                    uri: url.standardizedFileURL.absoluteString, displayName: url.lastPathComponent, origin: .files,
                    isTemporaryCopy: false, bookmark: bookmark.map { FlutterStandardTypedData(bytes: $0) }, sizeBytes: size)
            }
        }
    }
}

/// One PHPicker presentation.
private final class PhotosPickSession: NSObject, PHPickerViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    private let kinds: Set<MediaPickKindMsg>
    private let directory: URL
    private var reply: EngineReply<[PickedMediaMsg]>?

    init(kinds: Set<MediaPickKindMsg>, directory: URL, reply: @escaping EngineReply<[PickedMediaMsg]>) {
        self.kinds = kinds
        self.directory = directory
        self.reply = reply
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let reply = reply else { return }
        self.reply = nil
        if results.isEmpty {
            reply(.success([]))
            return
        }
        ItemProviderImport.load(results.map(\.itemProvider), kinds: kinds, into: directory, origin: .photos, completion: reply)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard let reply = reply else { return }
        self.reply = nil
        reply(.success([]))
    }
}

/// One document picker presentation.
private final class FilesPickSession: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    private let kinds: Set<MediaPickKindMsg>
    private var reply: EngineReply<[PickedMediaMsg]>?

    init(kinds: Set<MediaPickKindMsg>, reply: @escaping EngineReply<[PickedMediaMsg]>) {
        self.kinds = kinds
        self.reply = reply
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let reply = reply else { return }
        self.reply = nil
        reply(.success(MediaPicker.filesItems(urls, kinds: kinds)))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finishCancelled()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finishCancelled()
    }

    private func finishCancelled() {
        guard let reply = reply else { return }
        self.reply = nil
        reply(.success([]))
    }
}
