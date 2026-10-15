// OWNER: IOS-13
//
// Files export and the share sheet (ARCH §14.1, §14.2). The glue calls it through `FileHandingOff`
// (Glue/ServiceProtocols.swift) on the main queue and builds it with `init(context:)`
// (Glue/EngineServices.swift).
//
// - saveToFiles: `UIDocumentPickerViewController(forExporting: [url], asCopy: true)`. The exported
//   copy takes its name from the file it copies, so the source is first cloned (APFS clone, else
//   copy) into `work/handoff-<uuid>/<suggestedName>`; that staging directory is deleted when the
//   picker answers. Picked → `done` with the destination URL as `savedUri`; cancelled → `cancelled`.
// - share: `UIActivityViewController(activityItems: [url])`, anchored to the presenting view on
//   iPad. Completed → `done` (`savedUri` = the activity type); dismissed → `cancelled`; an activity
//   error → `io`.
// - One sheet at a time (`busy` otherwise); no presenting view controller → `notSupportedOnDevice`.
// - The source file is never moved or deleted: Dart deletes the temp export through
//   OwnedFileDeleter after the handoff.
// Nothing here logs paths.

import Foundation
import UIKit

final class FileHandoff: NSObject, FileHandingOff, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    /// Presents [controller]; returns false when nothing can present (tests inject a recorder).
    typealias Presenter = (_ controller: UIViewController) -> Bool

    private let context: EngineContext?
    private let present: Presenter
    private let stagingRoot: () -> URL?

    /// The sheet on screen (main thread).
    private var pending: (controller: UIViewController, staging: URL?, reply: EngineReply<FileHandoffResultMsg>)?

    init(context: EngineContext) {
        self.context = context
        present = { [weak context] controller in
            guard let presenter = context?.presentingViewController() else { return false }
            FileHandoff.anchor(controller, in: presenter)
            presenter.present(controller, animated: true)
            return true
        }
        stagingRoot = { [weak context] in context?.paths?.work }
        super.init()
    }

    /// Tests inject the presenter and the staging root.
    init(context: EngineContext?, stagingRoot: URL?, present: @escaping Presenter) {
        self.context = context
        self.present = present
        self.stagingRoot = { stagingRoot }
        super.init()
    }

    /// The controller on screen (tests).
    var presentedController: UIViewController? { pending?.controller }

    // MARK: FileHandingOff

    func saveToFiles(fileURL: URL, suggestedName: String, reply: @escaping EngineReply<FileHandoffResultMsg>) {
        guard pending == nil else { return reply(.failure(EngineError(.busy, "another sheet is open", retryable: true))) }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return reply(.failure(EngineError(.mediaOffline, "the file to save does not exist")))
        }
        let staging: URL?
        let exported: URL
        do {
            (staging, exported) = try stage(fileURL, as: FileHandoff.exportName(suggestedName, source: fileURL))
        } catch {
            return reply(.failure(EngineError.from(error)))
        }
        let picker = UIDocumentPickerViewController(forExporting: [exported], asCopy: true)
        picker.delegate = self
        picker.shouldShowFileExtensions = true
        show(picker, staging: staging, reply: reply)
    }

    func share(fileURL: URL, reply: @escaping EngineReply<FileHandoffResultMsg>) {
        guard pending == nil else { return reply(.failure(EngineError(.busy, "another sheet is open", retryable: true))) }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return reply(.failure(EngineError(.mediaOffline, "the file to share does not exist")))
        }
        let sheet = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        sheet.completionWithItemsHandler = { [weak self] activity, completed, _, error in
            let result: Result<FileHandoffResultMsg, Error>
            if let error = error {
                let ns = error as NSError
                Log.error(.platform, "share failed: \(ns.domain) \(ns.code)")
                result = .failure(EngineError(.io, "share failed (\(ns.code))"))
            } else if completed {
                result = .success(FileHandoffResultMsg(outcome: .done, savedUri: activity?.rawValue))
            } else {
                result = .success(FileHandoffResultMsg(outcome: .cancelled))
            }
            self?.finish(sheet, result)
        }
        show(sheet, staging: nil, reply: reply)
    }

    // MARK: Presentation

    private func show(_ controller: UIViewController, staging: URL?, reply: @escaping EngineReply<FileHandoffResultMsg>) {
        pending = (controller, staging, reply)
        guard present(controller) else {
            pending = nil
            FileHandoff.removeStaging(staging)
            return reply(.failure(EngineError(.notSupportedOnDevice, "no view controller to present the sheet")))
        }
        controller.presentationController?.delegate = self
    }

    /// Answers the sheet [controller] once and cleans its staging copy (main thread).
    private func finish(_ controller: UIViewController, _ result: Result<FileHandoffResultMsg, Error>) {
        guard let current = pending, current.controller === controller else { return }
        pending = nil
        FileHandoff.removeStaging(current.staging)
        current.reply(result)
    }

    /// iPad: popovers need an anchor (the centre of the presenting view, no arrow).
    static func anchor(_ controller: UIViewController, in presenter: UIViewController) {
        guard let popover = controller.popoverPresentationController else { return }
        popover.sourceView = presenter.view
        let bounds = presenter.view.bounds
        popover.sourceRect = CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
    }

    // MARK: UIDocumentPickerDelegate

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(controller, .success(FileHandoffResultMsg(outcome: .done, savedUri: urls.first?.absoluteString)))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(controller, .success(FileHandoffResultMsg(outcome: .cancelled)))
    }

    // MARK: UIAdaptivePresentationControllerDelegate

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        // Swiped away without an answer from the sheet itself.
        let controller = presentationController.presentedViewController
        if controller is UIActivityViewController { return }  // its completion handler answers
        finish(controller, .success(FileHandoffResultMsg(outcome: .cancelled)))
    }

    // MARK: Staging

    /// The exported file name: [suggestedName] (path separators removed) with the source's extension
    /// when it has none.
    static func exportName(_ suggestedName: String, source: URL) -> String {
        var name = suggestedName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { name = source.lastPathComponent }
        if (name as NSString).pathExtension.isEmpty, !source.pathExtension.isEmpty {
            name += "." + source.pathExtension
        }
        return name
    }

    /// Clones [source] under a fresh staging directory as [name]; no staging when the names match.
    private func stage(_ source: URL, as name: String) throws -> (URL?, URL) {
        if source.lastPathComponent == name { return (nil, source) }
        guard let root = stagingRoot() else { return (nil, source) }
        let directory = root.appendingPathComponent("handoff-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: source, to: target)  // APFS clones when it can
        } catch {
            FileHandoff.removeStaging(directory)
            throw error
        }
        return (directory, target)
    }

    private static func removeStaging(_ directory: URL?) {
        guard let directory = directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
