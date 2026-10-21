// OWNER: HOM-02
//
// BackupFlagHostApi on Apple (ARCH v1.2 §5.2): `NSURLIsExcludedFromBackupKey` on an app path
// (HOM-17 excludes `imports/` only). Touches only the resource value, never the file's bytes.

import Foundation

final class BackupFlagHostApiImpl: BackupFlagHostApi {
  init(context: LibraryPluginContext) {}

  func setExcludedFromBackup(path: String, excluded: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
    DispatchQueue.global(qos: .utility).async {
      do {
        try Self.setExcluded(path: path, excluded: excluded)
        completion(.success(()))
      } catch let e as LibraryPigeonError {
        completion(.failure(e))
      } catch {
        completion(.failure(LibraryErrors.error(.ioError, "could not set the backup flag")))
      }
    }
  }

  func isExcludedFromBackup(path: String, completion: @escaping (Result<Bool, Error>) -> Void) {
    DispatchQueue.global(qos: .utility).async {
      do {
        completion(.success(try Self.isExcluded(path: path)))
      } catch let e as LibraryPigeonError {
        completion(.failure(e))
      } catch {
        completion(.failure(LibraryErrors.error(.ioError, "could not read the backup flag")))
      }
    }
  }

  static func setExcluded(path: String, excluded: Bool) throws {
    guard path.hasPrefix("/") else { throw LibraryErrors.error(.invalidArgument, "path is not absolute") }
    guard FileManager.default.fileExists(atPath: path) else { throw LibraryErrors.error(.notFound, "path does not exist") }
    var url = URL(fileURLWithPath: path)
    var values = URLResourceValues()
    values.isExcludedFromBackup = excluded
    try url.setResourceValues(values)
  }

  static func isExcluded(path: String) throws -> Bool {
    guard path.hasPrefix("/") else { throw LibraryErrors.error(.invalidArgument, "path is not absolute") }
    guard FileManager.default.fileExists(atPath: path) else { throw LibraryErrors.error(.notFound, "path does not exist") }
    let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [.isExcludedFromBackupKey])
    return values.isExcludedFromBackup ?? false
  }
}
