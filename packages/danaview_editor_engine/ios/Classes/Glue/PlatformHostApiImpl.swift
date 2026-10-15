// OWNER: ENG-07 (frozen by ENG-06; amended by INT-06: `powerState`, D-45; by INT-07:
// `materializePick`, PickMaterializer.swift, on the io queue)
//
// Glue of `PlatformHostApi` (ARCH §9, §12.4, §15): pickers, Files/share sheets, notification
// permission, background leases and the drop target run on main (UIKit); bookmarks, stat,
// quickHash, backup exclusion and Photos saves on the io queue. `excludeFromBackup` refuses
// directories outside the editor and speech roots with `permissionDenied` (D-44).

import Flutter
import Foundation

final class PlatformHostApiImpl: PlatformHostApi {
    private let context: EngineContext
    private let services: EngineServices

    init(context: EngineContext, services: EngineServices) {
        self.context = context
        self.services = services
    }

    private var io: DispatchQueue { context.queues.io }

    func pick(request: MediaPickRequestMsg, completion: @escaping (Result<[PickedMediaMsg], Error>) -> Void) {
        GlueDispatch.hop(
            "platform.pick", on: .main, completion: completion,
            validate: {
                _ = try context.requirePaths()
                try Validate.pickRequest(request)
            }
        ) { [picker = services.picker] _, reply in
            picker.pick(request, reply: reply)
        }
    }

    func saveToPhotos(path: String, completion: @escaping (Result<FileHandoffResultMsg, Error>) -> Void) {
        GlueDispatch.hop(
            "platform.saveToPhotos", on: io, completion: completion,
            validate: { try Paths.absoluteURL(path, name: "path") }
        ) { [photos = services.photos] url, reply in
            photos.saveToPhotos(fileURL: url, reply: reply)
        }
    }

    func saveToFiles(path: String, suggestedName: String, completion: @escaping (Result<FileHandoffResultMsg, Error>) -> Void) {
        GlueDispatch.hop(
            "platform.saveToFiles", on: .main, completion: completion,
            validate: { () -> URL in
                try Validate.fileName(suggestedName, "suggestedName")
                return try Paths.absoluteURL(path, name: "path")
            }
        ) { [files = services.files] url, reply in
            files.saveToFiles(fileURL: url, suggestedName: suggestedName, reply: reply)
        }
    }

    func share(path: String, completion: @escaping (Result<FileHandoffResultMsg, Error>) -> Void) {
        GlueDispatch.hop(
            "platform.share", on: .main, completion: completion,
            validate: { try Paths.absoluteURL(path, name: "path") }
        ) { [files = services.files] url, reply in
            files.share(fileURL: url, reply: reply)
        }
    }

    func createBookmark(uri: String, completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void) {
        GlueDispatch.hop(
            "platform.createBookmark", on: io, completion: completion,
            validate: { try Paths.fileURL(fromPathOrUri: uri, name: "uri") }
        ) { [access = services.access] url, reply in
            access.createBookmark(fileURL: url) { reply($0.map { FlutterStandardTypedData(bytes: $0) }) }
        }
    }

    func resolveBookmark(bookmark: FlutterStandardTypedData, completion: @escaping (Result<ResolvedBookmarkMsg, Error>) -> Void) {
        GlueDispatch.hop(
            "platform.resolveBookmark", on: io, completion: completion,
            validate: { try Validate.bookmark(bookmark, "bookmark") }
        ) { [access = services.access] data, reply in
            access.resolveBookmark(data, reply: reply)
        }
    }

    func persistUriGrant(uri: String, completion: @escaping (Result<Void, Error>) -> Void) {
        GlueDispatch.hop(
            "platform.persistUriGrant", on: io, completion: completion,
            validate: { try Validate.text(uri, "uri", maxBytes: 8192, allowEmpty: false) }
        ) { [access = services.access] _, reply in
            access.persistUriGrant(uri: uri, reply: reply)
        }
    }

    func releaseUriGrant(uri: String, completion: @escaping (Result<Void, Error>) -> Void) {
        GlueDispatch.hop(
            "platform.releaseUriGrant", on: io, completion: completion,
            validate: { try Validate.text(uri, "uri", maxBytes: 8192, allowEmpty: false) }
        ) { [access = services.access] _, reply in
            access.releaseUriGrant(uri: uri, reply: reply)
        }
    }

    func remainingGrantBudget(completion: @escaping (Result<Int64, Error>) -> Void) {
        GlueDispatch.hop("platform.remainingGrantBudget", on: io, completion: completion) { [access = services.access] reply in
            access.remainingGrantBudget(reply: reply)
        }
    }

    func stat(media: MediaRefMsg, completion: @escaping (Result<MediaStatMsg?, Error>) -> Void) {
        GlueDispatch.hop(
            "platform.stat", on: io, completion: completion,
            validate: { try Validate.mediaRef(media) }
        ) { [access = services.access] url, reply in
            access.stat(media, fileURL: url, reply: reply)
        }
    }

    func quickHash(media: MediaRefMsg, completion: @escaping (Result<String, Error>) -> Void) {
        GlueDispatch.hop(
            "platform.quickHash", on: io, completion: completion,
            validate: { try Validate.mediaRef(media) }
        ) { [access = services.access] url, reply in
            access.quickHash(media, fileURL: url, reply: reply)
        }
    }

    func excludeFromBackup(path: String, completion: @escaping (Result<Void, Error>) -> Void) {
        GlueDispatch.hop(
            "platform.excludeFromBackup", on: io, completion: completion,
            validate: { () -> URL in
                let paths = try context.requirePaths()
                return try paths.requireInside(path, roots: paths.backupExclusionRoots, name: "path")
            }
        ) { [access = services.access] url, reply in
            access.excludeFromBackup(directoryURL: url, reply: reply)
        }
    }

    func requestNotificationPermission(completion: @escaping (Result<Bool, Error>) -> Void) {
        GlueDispatch.hop("platform.requestNotificationPermission", on: .main, completion: completion) {
            [permissions = services.permissions] reply in
            permissions.requestNotificationPermission(reply: reply)
        }
    }

    func acquireBackground(title: String, completion: @escaping (Result<String?, Error>) -> Void) {
        GlueDispatch.hop(
            "platform.acquireBackground", on: .main, completion: completion,
            validate: { try Validate.text(title, "title") }
        ) { [background = services.background] _, reply in
            background.acquire(title: title, reply: reply)
        }
    }

    func updateBackground(leaseId: String, progress: Double, completion: @escaping (Result<Void, Error>) -> Void) {
        GlueDispatch.hop(
            "platform.updateBackground", on: .main, completion: completion,
            validate: {
                try Validate.id(leaseId, "leaseId")
                try Validate.unit(progress, "progress")
            }
        ) { [background = services.background] _, reply in
            background.update(leaseId: leaseId, progress: progress, reply: reply)
        }
    }

    func releaseBackground(leaseId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        GlueDispatch.hop(
            "platform.releaseBackground", on: .main, completion: completion,
            validate: { try Validate.id(leaseId, "leaseId") }
        ) { [background = services.background] _, reply in
            background.release(leaseId: leaseId, reply: reply)
        }
    }

    func setDropTargetEnabled(enabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        GlueDispatch.hop("platform.setDropTargetEnabled", on: .main, completion: completion) { [drops = services.drops] reply in
            drops.setEnabled(enabled, reply: reply)
        }
    }

    func materializePick(uri: String, intoDir: String, completion: @escaping (Result<String, Error>) -> Void) {
        GlueDispatch.hop(
            "platform.materializePick", on: io, completion: completion,
            validate: { () -> (URL, Paths) in
                try Validate.text(uri, "uri", maxBytes: 8192, allowEmpty: false)
                let paths = try context.requirePaths()
                return (try paths.requireInside(intoDir, roots: [paths.work], name: "intoDir"), paths)
            }
        ) { value, reply in
            reply(.success(try PickMaterializer.materialize(uri: uri, intoDir: value.0, paths: value.1)))
        }
    }

    func powerState(completion: @escaping (Result<PowerStateMsg, Error>) -> Void) {
        GlueDispatch.hop("platform.powerState", on: .main, completion: completion) { [power = services.power] reply in
            power.powerState(reply: reply)
        }
    }
}
