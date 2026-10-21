// OWNER: HOM-16
//
// SourceHint of a library entry (ARCH v1.2 §5.1, HOM plan §8.1): where a Danaview folder file came
// from. Append-only like FileKind; a stored code this build doesn't know decodes to
// [SourceHint.unknown].

/// Where a library entry was imported from (ARCH v1.2 §5.1 `FileEntry.sourceHint`).
enum SourceHint {
  /// Picked from Photos / the Android photo picker.
  photos('photos'),

  /// Picked from Files / the Storage Access Framework / an open panel.
  files('files'),

  /// Opened with Danaview from another app (Open with, Finder, file association).
  openWith('openWith'),

  /// Shared to Danaview through the iOS Share Extension or `ACTION_SEND`.
  shareExtension('shareExtension'),

  /// Copied in from a linked folder.
  linkedFolder('linkedFolder'),

  /// Saved by the editor's export.
  editorExport('editorExport'),

  /// Saved from the player ("Save to Danaview folder").
  player('player'),

  /// A stored source this build doesn't know (appended by a later version).
  unknown('unknown');

  const SourceHint(this.code);

  /// The stable string stored in `library.db` (`entries.source_hint`).
  final String code;

  /// The source stored as [code], or null when this build doesn't know it.
  static SourceHint? tryDecode(String code) {
    for (final hint in values) {
      if (hint.code == code) return hint;
    }
    return null;
  }

  /// The source stored as [code]; [SourceHint.unknown] for a code this build doesn't know.
  static SourceHint decode(String code) => tryDecode(code) ?? SourceHint.unknown;
}
