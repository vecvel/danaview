// OWNER: IOS-13
//
// Add-only Photos saves (ARCH §14.1, §14.2, D-39). The glue calls it through `PhotosSaving`
// (Glue/ServiceProtocols.swift) on the io queue and builds it with `init(context:)`
// (Glue/EngineServices.swift).
//
// - Access is the add-only level (`PHAccessLevel.addOnly`, NSPhotoLibraryAddUsageDescription in the
//   host app): the app never asks for, nor needs, full library access. `notDetermined` asks once
//   (the system prompt); `denied` / `restricted` fail with `permissionDenied` (Dart maps it to
//   FileHandoffOutcome.denied).
// - The video is added with `PHAssetCreationRequest.addResource(with: .video, fileURL:)` and
//   `shouldMoveFile = false`: the source file stays where it is; Dart deletes the temp file
//   through OwnedFileDeleter after the handoff. The reply carries the new asset's
//   localIdentifier as `savedUri`.
// - `saveDetached` is the native save of ActiveExportStore (completed while no Dart listener was
//   attached): it never prompts and saves only when add-only access is already authorized.
// Nothing here logs paths.

import Foundation
import Photos

/// The Photos calls PhotosSaver needs (tests inject fakes).
protocol PhotoLibraryAdding: AnyObject {
    func addOnlyStatus() -> PHAuthorizationStatus
    func requestAddOnly(_ completion: @escaping (PHAuthorizationStatus) -> Void)
    /// Adds the video at [fileURL] without moving it; answers the new asset's localIdentifier.
    func addVideo(_ fileURL: URL, completion: @escaping (Result<String?, Error>) -> Void)
}

/// `PHPhotoLibrary.shared()` at the add-only access level.
final class SystemPhotoLibrary: PhotoLibraryAdding {
    func addOnlyStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    func requestAddOnly(_ completion: @escaping (PHAuthorizationStatus) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly, handler: completion)
    }

    func addVideo(_ fileURL: URL, completion: @escaping (Result<String?, Error>) -> Void) {
        var identifier: String?
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            request.addResource(with: .video, fileURL: fileURL, options: options)
            identifier = request.placeholderForCreatedAsset?.localIdentifier
        }, completionHandler: { success, error in
            if success {
                completion(.success(identifier))
            } else {
                completion(.failure(error ?? EngineError(.io, "Photos refused the video")))
            }
        })
    }
}

final class PhotosSaver: PhotosSaving {
    private let context: EngineContext?
    private let library: PhotoLibraryAdding

    init(context: EngineContext) {
        self.context = context
        library = SystemPhotoLibrary()
    }

    /// Tests inject the library.
    init(context: EngineContext?, library: PhotoLibraryAdding) {
        self.context = context
        self.library = library
    }

    /// Whether a save would run without a prompt.
    var isAuthorized: Bool { PhotosSaver.allows(library.addOnlyStatus()) }

    static func allows(_ status: PHAuthorizationStatus) -> Bool {
        status == .authorized || status == .limited
    }

    func saveToPhotos(fileURL: URL, reply: @escaping EngineReply<FileHandoffResultMsg>) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return reply(.failure(EngineError(.mediaOffline, "the video to save does not exist")))
        }
        let status = library.addOnlyStatus()
        switch status {
        case .notDetermined:
            // The saver stays alive until the prompt answers (one reply per call).
            library.requestAddOnly { answered in
                guard PhotosSaver.allows(answered) else { return reply(.failure(PhotosSaver.denied)) }
                self.add(fileURL, reply: reply)
            }
        default:
            guard PhotosSaver.allows(status) else { return reply(.failure(PhotosSaver.denied)) }
            add(fileURL, reply: reply)
        }
    }

    /// The native save of a job that completed while detached (D-39): no prompt; nil savedUri and
    /// false when access is not already granted or the save failed.
    func saveDetached(fileURL: URL, completion: @escaping (_ saved: Bool, _ localIdentifier: String?) -> Void) {
        guard isAuthorized, FileManager.default.fileExists(atPath: fileURL.path) else { return completion(false, nil) }
        library.addVideo(fileURL) { result in
            switch result {
            case .success(let identifier): completion(true, identifier)
            case .failure(let error):
                Log.error(.platform, "detached Photos save failed: \(EngineError.from(error).code.rawValue)")
                completion(false, nil)
            }
        }
    }

    private static let denied = EngineError(.permissionDenied, "Photos add-only access denied")

    private func add(_ fileURL: URL, reply: @escaping EngineReply<FileHandoffResultMsg>) {
        library.addVideo(fileURL) { result in
            switch result {
            case .success(let identifier):
                reply(.success(FileHandoffResultMsg(outcome: .done, savedUri: identifier)))
            case .failure(let error):
                let ns = error as NSError
                if ns.domain == PHPhotosErrorDomain,
                   ns.code == PHPhotosError.Code.accessUserDenied.rawValue || ns.code == PHPhotosError.Code.accessRestricted.rawValue {
                    return reply(.failure(PhotosSaver.denied))
                }
                if ns.domain == PHPhotosErrorDomain, ns.code == PHPhotosError.Code.userCancelled.rawValue {
                    return reply(.failure(EngineError.cancelled))
                }
                let mapped = EngineError.from(error)
                Log.error(.platform, "Photos save failed: \(ns.domain) \(ns.code)")
                reply(.failure(mapped.code == .internal ? EngineError(.io, "Photos save failed (\(ns.code))") : mapped))
            }
        }
    }
}
