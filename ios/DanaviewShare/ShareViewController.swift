// OWNER: HOM-21 (the file was a placeholder of INT-104, which created the DanaviewShare target)
//
// Principal class of the Share Extension "Share → Danaview" (Info.plist NSExtensionPrincipalClass;
// ARCH v1.2 §5.6, HOM plan §8.2). The user picks a Danaview folder (FolderPickerView, default
// "Imported"); Save streams each shared item into the App Group inbox one at a time (InboxWriter:
// file representations copied by FileManager, never loaded into memory, so a 2 GB video stays
// under the extension memory limit), writes `manifest.json` last and closes. The app imports the
// batch on its next launch or foreground (InboxImporter). Cancel, or the extension being killed,
// leaves no manifest, so nothing half-shared is ever imported. Nothing is logged (rule 30).

import UIKit
import UniformTypeIdentifiers

@objc(ShareViewController)
final class ShareViewController: UIViewController {
  /// The types the extension accepts, most specific first (the Info.plist activation rule).
  static let acceptedTypes: [UTType] = [
    .image, .movie, .pdf, .rtf, .plainText, .commaSeparatedText, .delimitedText, .json,
  ] + [
    "com.microsoft.word.doc", "org.openxmlformats.wordprocessingml.document",
    "com.microsoft.excel.xls", "org.openxmlformats.spreadsheetml.sheet",
    "com.microsoft.powerpoint.ppt", "org.openxmlformats.presentationml.presentation",
    "org.oasis-open.opendocument.text", "org.oasis-open.opendocument.spreadsheet",
    "org.oasis-open.opendocument.presentation",
    "com.apple.iwork.pages.pages", "com.apple.iwork.pages.sffpages",
    "com.apple.iwork.numbers.numbers", "com.apple.iwork.numbers.sffnumbers",
    "com.apple.iwork.keynote.key", "com.apple.iwork.keynote.sffkey",
  ].compactMap { UTType($0) }

  private var providers: [NSItemProvider] = []
  private var folders: [SnapshotFolder] = FolderSnapshot.importedOnly
  private var writer: InboxWriter?
  private var cancelled = false
  private var saving = false

  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private var picker: FolderPickerView!
  private let statusLabel = UILabel()
  private let progress = UIProgressView(progressViewStyle: .default)
  private let cancelButton = ShareButton(title: "Cancel", primary: false)
  private let saveButton = ShareButton(title: "Save", primary: true)

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = ShareStyle.background
    overrideUserInterfaceStyle = .dark
    providers = ShareViewController.supportedProviders(extensionContext?.inputItems ?? [])
    folders = FolderSnapshot.load(groupRoot: DanaviewAppGroup.containerURL())
    buildLayout()
  }

  /// The attachments of [inputItems] the extension can save, in share order.
  static func supportedProviders(_ inputItems: [Any]) -> [NSItemProvider] {
    inputItems.compactMap { $0 as? NSExtensionItem }.flatMap { $0.attachments ?? [] }.filter { typeIdentifier(of: $0) != nil }
  }

  /// The registered type of [provider] to load: its most faithful type that conforms to an
  /// accepted type.
  static func typeIdentifier(of provider: NSItemProvider) -> String? {
    for id in provider.registeredTypeIdentifiers {
      guard let type = UTType(id) else { continue }
      if acceptedTypes.contains(where: { type.conforms(to: $0) }) { return id }
    }
    return nil
  }

  // MARK: Layout

  private func buildLayout() {
    titleLabel.text = "Save to Danaview"
    titleLabel.font = ShareStyle.font(20, .semibold, style: .title3)
    titleLabel.textColor = ShareStyle.textPrimary
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.accessibilityTraits = .header

    subtitleLabel.text = providers.count == 1 ? "1 item · choose a folder" : "\(providers.count) items · choose a folder"
    subtitleLabel.font = ShareStyle.font(14, .regular, style: .subheadline)
    subtitleLabel.textColor = ShareStyle.textSecondary
    subtitleLabel.adjustsFontForContentSizeCategory = true
    subtitleLabel.numberOfLines = 2

    picker = FolderPickerView(folders: folders)

    statusLabel.font = ShareStyle.font(14, .regular, style: .footnote)
    statusLabel.textColor = ShareStyle.textSecondary
    statusLabel.adjustsFontForContentSizeCategory = true
    statusLabel.numberOfLines = 3
    statusLabel.isHidden = true
    progress.progressTintColor = ShareStyle.primary
    progress.trackTintColor = ShareStyle.hairline
    progress.isHidden = true
    progress.isAccessibilityElement = false

    cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
    saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
    saveButton.accessibilityHint = "Saves the shared items to the chosen Danaview folder"
    saveButton.isEnabled = !providers.isEmpty
    if providers.isEmpty { showStatus("Danaview can't save these items.", error: true) }

    let buttons = UIStackView(arrangedSubviews: [cancelButton, saveButton])
    buttons.axis = .horizontal
    buttons.spacing = 12
    buttons.distribution = .fillEqually

    let header = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
    header.axis = .vertical
    header.spacing = 4

    let stack = UIStackView(arrangedSubviews: [header, picker, progress, statusLabel, buttons])
    stack.axis = .vertical
    stack.spacing = 16
    stack.setCustomSpacing(8, after: progress)
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)

    let guide = view.safeAreaLayoutGuide
    let maxWidth = stack.widthAnchor.constraint(lessThanOrEqualToConstant: 560)
    let fill = stack.widthAnchor.constraint(equalTo: guide.widthAnchor, constant: -32)
    fill.priority = .defaultHigh
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 20),
      stack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
      stack.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 16),
      maxWidth, fill,
      buttons.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
    ])
    picker.setContentHuggingPriority(.defaultLow, for: .vertical)
  }

  private func showStatus(_ text: String, error: Bool = false) {
    statusLabel.text = text
    statusLabel.textColor = error ? ShareStyle.error : ShareStyle.textSecondary
    statusLabel.isHidden = false
    UIAccessibility.post(notification: .announcement, argument: text)
  }

  // MARK: Actions

  @objc private func cancelTapped() {
    cancelled = true
    writer?.abandon()
    extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
  }

  @objc private func saveTapped() {
    guard !saving, !providers.isEmpty else { return }
    guard let group = DanaviewAppGroup.containerURL() else {
      return showStatus("Danaview can't receive items on this device.", error: true)
    }
    saving = true
    saveButton.isEnabled = false
    picker.setEnabled(false)
    progress.isHidden = false
    progress.progress = 0
    let w = InboxWriter(groupRoot: group, targetFolderId: picker.selectedFolder.id)
    writer = w
    do {
      try w.begin()
    } catch {
      return fail("Couldn't save. Try again.")
    }
    copy(index: 0, failures: 0, writer: w)
  }

  /// Copies item [index] and continues with the next one (one at a time, so only one file
  /// representation is open).
  private func copy(index: Int, failures: Int, writer w: InboxWriter) {
    guard !cancelled else { return }
    guard index < providers.count else { return finish(writer: w, failures: failures) }
    showStatus("Saving \(index + 1) of \(providers.count)…")
    progress.setProgress(Float(index) / Float(providers.count), animated: true)
    let provider = providers[index]
    guard let type = ShareViewController.typeIdentifier(of: provider) else {
      return copy(index: index + 1, failures: failures + 1, writer: w)
    }
    ShareViewController.write(provider, type: type, into: w) { [weak self] outcome in
      DispatchQueue.main.async {
        guard let self = self, !self.cancelled else { return }
        switch outcome {
        case .success: self.copy(index: index + 1, failures: failures, writer: w)
        case .failure(InboxWriterError.noSpace):
          w.abandon()
          self.fail("There isn't enough space to save these items.")
        case .failure: self.copy(index: index + 1, failures: failures + 1, writer: w)
        }
      }
    }
  }

  /// Streams one attachment into [writer]. The file the provider hands out is valid only inside
  /// its callback, so the copy happens there (on the provider's queue).
  static func write(_ provider: NSItemProvider, type: String, into writer: InboxWriter, completion: @escaping (Result<Void, Error>) -> Void) {
    let utType = UTType(type)
    _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
      if let url = url {
        let name = ShareViewController.fileName(suggested: provider.suggestedName, file: url, type: utType)
        do {
          try writer.addFile(at: url, name: name, uti: type)
          completion(.success(()))
        } catch {
          completion(.failure(error))
        }
        return
      }
      // Shared text without a file representation: its (small) data.
      guard utType?.conforms(to: .text) == true else { return completion(.failure(error ?? InboxWriterError.copyFailed)) }
      _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
        guard let data = data else { return completion(.failure(error ?? InboxWriterError.copyFailed)) }
        let ext = utType?.preferredFilenameExtension ?? "txt"
        let name = ShareViewController.fileName(suggested: provider.suggestedName, file: nil, type: utType, fallback: "Shared text.\(ext)")
        do {
          try writer.addData(data, name: name, uti: type)
          completion(.success(()))
        } catch {
          completion(.failure(error))
        }
      }
    }
  }

  /// The name an item is saved as: the suggested name with the file's extension, else the file's
  /// own name, else [fallback].
  static func fileName(suggested: String?, file: URL?, type: UTType?, fallback: String = "Shared item") -> String {
    let ext = file?.pathExtension.isEmpty == false ? file!.pathExtension : (type?.preferredFilenameExtension ?? "")
    if let s = suggested?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
      let hasExt = !(s as NSString).pathExtension.isEmpty
      return hasExt || ext.isEmpty ? s : "\(s).\(ext)"
    }
    if let f = file?.lastPathComponent, !f.isEmpty { return f }
    return fallback
  }

  private func finish(writer w: InboxWriter, failures: Int) {
    progress.setProgress(1, animated: true)
    guard !w.items.isEmpty else {
      w.abandon()
      return fail(failures == 1 ? "Couldn't save this item." : "Couldn't save these items.")
    }
    do {
      try w.finish()
    } catch {
      w.abandon()
      return fail("Couldn't save. Try again.")
    }
    extensionContext?.completeRequest(returningItems: nil)
  }

  private func fail(_ message: String) {
    saving = false
    writer = nil
    progress.isHidden = true
    picker.setEnabled(true)
    saveButton.isEnabled = !providers.isEmpty
    showStatus(message, error: true)
  }
}

/// A button without hover or press effects (owner UI rules): filled primary or hairline
/// secondary, at least 48 pt tall, Dynamic Type.
final class ShareButton: UIControl {
  private let label = UILabel()
  private let primary: Bool

  init(title: String, primary: Bool) {
    self.primary = primary
    super.init(frame: .zero)
    label.text = title
    label.font = ShareStyle.font(16, .semibold)
    label.adjustsFontForContentSizeCategory = true
    label.textAlignment = .center
    label.numberOfLines = 1
    label.adjustsFontSizeToFitWidth = true
    label.minimumScaleFactor = 0.8
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
      heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
    ])
    layer.cornerRadius = 12
    layer.borderWidth = primary ? 0 : 1
    layer.borderColor = ShareStyle.hairline.cgColor
    isAccessibilityElement = true
    accessibilityLabel = title
    accessibilityTraits = .button
    update()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  override var isEnabled: Bool { didSet { update() } }

  private func update() {
    backgroundColor = primary ? ShareStyle.primary : ShareStyle.surface
    label.textColor = .white
    alpha = isEnabled ? 1 : 0.45
    accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
  }
}
