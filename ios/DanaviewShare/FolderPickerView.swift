// OWNER: HOM-21 (the file was a placeholder of INT-104, which created the DanaviewShare target)
//
// The extension's folder picker (default "Imported"), reading the folder-list snapshot the app
// writes into the App Group (`folder-snapshot.json`, danaview_library's folder_snapshot.dart),
// never library.db (ARCH v1.2 §5.6). Without a readable snapshot (the app never ran with the Files
// & Media Home) it offers "Imported" only, which the app resolves to its Imported folder.
//
// The snapshot model and the style tokens are Foundation-only, so the plugin's XCTests parse
// snapshots on macOS; the list view is UIKit (dark, Figtree when the app's font can be loaded,
// hairline separators, no hover or press effects, rows of at least 52 pt, VoiceOver labels).

import Foundation

/// One folder of the snapshot.
struct SnapshotFolder: Equatable {
  /// `fd_…`, or nil for the "Imported" fallback (no snapshot).
  var id: String?
  var name: String
  var depth: Int
  var isImported: Bool
}

/// The folder list the app wrote.
enum FolderSnapshot {
  static let fileName = "folder-snapshot.json"
  static let format = "danaview.folderSnapshot"

  /// The fallback when no snapshot can be read: the app's Imported folder.
  static let importedOnly = [SnapshotFolder(id: nil, name: "Imported", depth: 0, isImported: true)]

  /// The folders of [data]; [importedOnly] when it is missing, malformed or of a newer schema.
  static func parse(_ data: Data?) -> [SnapshotFolder] {
    guard let data = data,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          json["format"] as? String == format,
          let schema = (json["schema"] as? NSNumber)?.intValue, schema == 1,
          let list = json["folders"] as? [[String: Any]] else { return importedOnly }
    var out: [SnapshotFolder] = []
    for f in list {
      guard let id = f["id"] as? String, id.hasPrefix("fd_"), let name = f["name"] as? String, !name.isEmpty else { continue }
      let depth = max(0, min(12, (f["depth"] as? NSNumber)?.intValue ?? 0))
      out.append(SnapshotFolder(id: id, name: name, depth: depth, isImported: (f["imported"] as? Bool) ?? false))
    }
    return out.contains(where: { $0.isImported }) ? out : importedOnly + out
  }

  /// The snapshot in the App Group [groupRoot].
  static func load(groupRoot: URL?) -> [SnapshotFolder] {
    guard let root = groupRoot else { return importedOnly }
    return parse(try? Data(contentsOf: root.appendingPathComponent(fileName)))
  }

  /// The row selected first: the Imported folder.
  static func defaultIndex(_ folders: [SnapshotFolder]) -> Int {
    folders.firstIndex(where: { $0.isImported }) ?? 0
  }
}

#if canImport(UIKit)
import CoreText
import UIKit

/// Colours and fonts of danaview_ui_kit (DanaviewColors), for the extension's UIKit views.
enum ShareStyle {
  static let background = UIColor(red: 0x07 / 255, green: 0x08 / 255, blue: 0x0C / 255, alpha: 1)
  static let surface = UIColor(red: 0x0F / 255, green: 0x11 / 255, blue: 0x18 / 255, alpha: 1)
  static let hairline = UIColor(white: 1, alpha: 0x14 / 255)
  static let selected = UIColor(red: 0x63 / 255, green: 0x66 / 255, blue: 0xF1 / 255, alpha: 0x1F / 255)
  static let primary = UIColor(red: 0x5E / 255, green: 0x60 / 255, blue: 0xEE / 255, alpha: 1)
  static let textPrimary = UIColor.white
  static let textSecondary = UIColor(red: 0xA0 / 255, green: 0xA6 / 255, blue: 0xBC / 255, alpha: 1)
  static let error = UIColor(red: 0xF8 / 255, green: 0x71 / 255, blue: 0x71 / 255, alpha: 1)

  private static var registered = false

  /// Registers the app's Figtree faces (flutter_assets of the containing app, read-only) once.
  static func registerFonts() {
    guard !registered else { return }
    registered = true
    let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    let fonts = app.appendingPathComponent("Frameworks/App.framework/flutter_assets/packages/danaview_ui_kit/fonts")
    for face in ["Regular", "Medium", "SemiBold"] {
      let url = fonts.appendingPathComponent("Figtree-\(face).ttf") as CFURL
      CTFontManagerRegisterFontsForURL(url, .process, nil)
    }
  }

  /// Figtree at [size] and [weight] (system font when the app's font is unavailable), scaled with
  /// Dynamic Type.
  static func font(_ size: CGFloat, _ weight: UIFont.Weight, style: UIFont.TextStyle = .body) -> UIFont {
    registerFonts()
    let name: String
    switch weight {
    case .semibold, .bold: name = "Figtree-SemiBold"
    case .medium: name = "Figtree-Medium"
    default: name = "Figtree-Regular"
    }
    let base = UIFont(name: name, size: size) ?? UIFont.systemFont(ofSize: size, weight: weight)
    return UIFontMetrics(forTextStyle: style).scaledFont(for: base, maximumPointSize: size * 1.35)
  }
}

/// The folder list; [onSelect] reports the chosen row.
final class FolderPickerView: UIView, UITableViewDataSource, UITableViewDelegate {
  private let table = UITableView(frame: .zero, style: .plain)
  private(set) var folders: [SnapshotFolder]
  private(set) var selectedIndex: Int
  var onSelect: ((SnapshotFolder) -> Void)?

  init(folders: [SnapshotFolder]) {
    self.folders = folders
    self.selectedIndex = FolderSnapshot.defaultIndex(folders)
    super.init(frame: .zero)
    backgroundColor = ShareStyle.surface
    layer.cornerRadius = 12
    layer.borderWidth = 1
    layer.borderColor = ShareStyle.hairline.cgColor
    clipsToBounds = true
    table.backgroundColor = .clear
    table.separatorColor = ShareStyle.hairline
    table.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
    table.rowHeight = UITableView.automaticDimension
    table.estimatedRowHeight = 52
    table.dataSource = self
    table.delegate = self
    table.register(FolderRowCell.self, forCellReuseIdentifier: FolderRowCell.reuse)
    table.translatesAutoresizingMaskIntoConstraints = false
    table.accessibilityLabel = "Danaview folders"
    addSubview(table)
    NSLayoutConstraint.activate([
      table.topAnchor.constraint(equalTo: topAnchor),
      table.bottomAnchor.constraint(equalTo: bottomAnchor),
      table.leadingAnchor.constraint(equalTo: leadingAnchor),
      table.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  /// The chosen folder.
  var selectedFolder: SnapshotFolder { folders[selectedIndex] }

  /// Enables or disables choosing (while saving).
  func setEnabled(_ enabled: Bool) {
    table.isUserInteractionEnabled = enabled
    table.alpha = enabled ? 1 : 0.6
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { folders.count }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: FolderRowCell.reuse, for: indexPath) as! FolderRowCell
    cell.configure(folders[indexPath.row], selected: indexPath.row == selectedIndex)
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    let previous = selectedIndex
    selectedIndex = indexPath.row
    tableView.reloadRows(at: Array(Set([IndexPath(row: previous, section: 0), indexPath])), with: .none)
    onSelect?(folders[indexPath.row])
  }
}

/// One folder row: indented by depth, folder glyph, name, a check on the chosen row.
final class FolderRowCell: UITableViewCell {
  static let reuse = "FolderRowCell"
  private let icon = UIImageView()
  private let title = UILabel()
  private let check = UIImageView(image: UIImage(systemName: "checkmark"))
  private var indent: NSLayoutConstraint!

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none // no press effect
    backgroundColor = .clear
    icon.tintColor = ShareStyle.textSecondary
    icon.contentMode = .scaleAspectFit
    title.font = ShareStyle.font(16, .regular)
    title.adjustsFontForContentSizeCategory = true
    title.textColor = ShareStyle.textPrimary
    title.numberOfLines = 2
    title.lineBreakMode = .byTruncatingMiddle
    check.tintColor = ShareStyle.primary
    check.contentMode = .scaleAspectFit
    for v in [icon, title, check] as [UIView] {
      v.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(v)
    }
    indent = icon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
    NSLayoutConstraint.activate([
      contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
      indent,
      icon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 22),
      icon.heightAnchor.constraint(equalToConstant: 22),
      title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
      title.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
      title.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
      check.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
      check.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
      check.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      check.widthAnchor.constraint(equalToConstant: 20),
      check.heightAnchor.constraint(equalToConstant: 20),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

  func configure(_ folder: SnapshotFolder, selected: Bool) {
    indent.constant = 16 + CGFloat(min(folder.depth, 6)) * 18
    icon.image = UIImage(systemName: folder.isImported ? "tray.and.arrow.down" : "folder")
    title.text = folder.name
    check.isHidden = !selected
    contentView.backgroundColor = selected ? ShareStyle.selected : .clear
    accessibilityLabel = folder.depth > 0 ? "\(folder.name), subfolder" : folder.name
    accessibilityTraits = selected ? [.button, .selected] : [.button]
    isAccessibilityElement = true
  }
}
#endif
