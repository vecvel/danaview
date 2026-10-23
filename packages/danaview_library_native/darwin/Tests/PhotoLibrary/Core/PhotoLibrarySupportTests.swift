// OWNER: HOM-02
//
// Pure tests of the PhotoKit library helpers (no photo library needed): change tokens, page
// windows, type mapping (V2-V2: HEIC, AVIF, RAW, Live), create-new naming, EXIF parsing and the
// photo-only album listing (Android 5ee89f2 parity).

import Foundation
import ImageIO
import XCTest

@testable import DanaviewPhotoLibraryCore

final class PhotoLibrarySupportTests: XCTestCase {
  func testTokenMovesOnlyWhenIndicesShift() {
    var book = PhotoSnapshotBook()
    let first = book.token
    XCTAssertFalse(book.isStale(nil))
    XCTAssertFalse(book.isStale(first))
    XCTAssertEqual(book.record(shiftsIndices: false), first, "in-place changes keep the token")
    let second = book.record(shiftsIndices: true)
    XCTAssertNotEqual(second, first)
    XCTAssertTrue(book.isStale(first))
    XCTAssertFalse(book.isStale(second))
  }

  func testWindowClampsAndRejects() throws {
    XCTAssertEqual(try PhotoSnapshotBook.window(offset: 0, limit: 200, count: 450), 0..<200)
    XCTAssertEqual(try PhotoSnapshotBook.window(offset: 400, limit: 200, count: 450), 400..<450)
    XCTAssertEqual(try PhotoSnapshotBook.window(offset: 900, limit: 200, count: 450), 450..<450)
    XCTAssertEqual(try PhotoSnapshotBook.window(offset: 0, limit: 10_000, count: 2_000), 0..<500)
    XCTAssertThrowsError(try PhotoSnapshotBook.window(offset: -1, limit: 1, count: 3)) { error in
      XCTAssertEqual((error as? PhotoLibraryFailure)?.code, .invalidArgument)
    }
    XCTAssertThrowsError(try PhotoSnapshotBook.window(offset: 0, limit: 0, count: 3))
  }

  func testWindowsCoverEveryIndexOnce() throws {
    for count in [0, 1, 7, 200, 201, 999] {
      var seen = [Int]()
      var offset = 0
      while true {
        let w = try PhotoSnapshotBook.window(offset: offset, limit: 200, count: count)
        if w.isEmpty { break }
        seen.append(contentsOf: w)
        offset = w.upperBound
      }
      XCTAssertEqual(seen, Array(0..<count))
    }
  }

  func testRawDetection() {
    for uti in ["com.adobe.raw-image", "com.canon.cr2-raw-image", "com.canon.cr3-raw-image", "com.nikon.raw-image", "com.sony.arw-raw-image", "public.camera-raw-image"] {
      XCTAssertTrue(PhotoTypes.isRaw(uti: uti), uti)
    }
    for uti in ["public.jpeg", "public.heic", "public.avif", "public.png", "com.apple.quicktime-movie"] {
      XCTAssertFalse(PhotoTypes.isRaw(uti: uti), uti)
    }
    XCTAssertFalse(PhotoTypes.isRaw(uti: nil))
  }

  func testMimeTypes() {
    XCTAssertEqual(PhotoTypes.mimeType(uti: "public.heic"), "image/heic")
    XCTAssertEqual(PhotoTypes.mimeType(uti: "public.avif"), "image/avif")
    XCTAssertEqual(PhotoTypes.mimeType(uti: "public.jpeg"), "image/jpeg")
    XCTAssertEqual(PhotoTypes.mimeType(uti: "com.adobe.raw-image"), "image/x-adobe-dng")
    XCTAssertEqual(PhotoTypes.mimeType(uti: "com.apple.quicktime-movie"), "video/quicktime")
    XCTAssertNil(PhotoTypes.mimeType(uti: nil))
    XCTAssertEqual(PhotoTypes.mimeType(fileName: "IMG_0001.HEIC"), "image/heic")
    XCTAssertEqual(PhotoTypes.mimeType(fileName: "clip.mov"), "video/quicktime")
    XCTAssertNil(PhotoTypes.mimeType(fileName: "noext"))
  }

  func testSanitizeKeepsOneComponent() {
    XCTAssertEqual(CopyNaming.sanitize("IMG_0001.HEIC", fallback: "Photo.jpg"), "IMG_0001.HEIC")
    XCTAssertEqual(CopyNaming.sanitize("../a/b:c.jpg", fallback: "Photo.jpg"), "_a_b_c.jpg")
    XCTAssertEqual(CopyNaming.sanitize("...", fallback: "Photo.jpg"), "Photo.jpg")
    XCTAssertEqual(CopyNaming.sanitize(nil, fallback: "Video.mov"), "Video.mov")
    let long = String(repeating: "x", count: 300) + ".jpg"
    let s = CopyNaming.sanitize(long, fallback: "Photo.jpg")
    XCTAssertLessThanOrEqual(s.count, 200)
    XCTAssertTrue(s.hasSuffix(".jpg"))
  }

  func testUniqueNeverReusesAnExistingName() {
    var taken: Set<String> = ["/d/IMG.jpg", "/d/IMG (2).jpg"]
    XCTAssertEqual(CopyNaming.unique(directory: "/d", name: "IMG.jpg", exists: { taken.contains($0) }), "/d/IMG (3).jpg")
    XCTAssertEqual(CopyNaming.unique(directory: "/d/", name: "clip", exists: { taken.contains($0) }), "/d/clip")
    taken = Set((1...999).map { $0 == 1 ? "/d/a.jpg" : "/d/a (\($0)).jpg" })
    XCTAssertNil(CopyNaming.unique(directory: "/d", name: "a.jpg", exists: { taken.contains($0) }))
  }

  func testExifDate() {
    let withOffset = PhotoAssetMapping.exifDate("2024:05:06 07:08:09", offset: "+02:00")
    XCTAssertEqual(withOffset.map(PhotoAssetMapping.millis), 1_714_972_089_000)
    XCTAssertNotNil(PhotoAssetMapping.exifDate("2024:05:06 07:08:09", offset: nil))
    XCTAssertNil(PhotoAssetMapping.exifDate("garbage", offset: nil))
  }

  /// EXIF of a JPEG written locally with ImageIO (no downloaded media).
  func testDetailFromImageProperties() throws {
    let data = try TestMedia.jpeg(width: 64, height: 48, exif: [
      kCGImagePropertyExifISOSpeedRatings as String: [200],
      kCGImagePropertyExifFNumber as String: 1.8,
      kCGImagePropertyExifExposureTime as String: 0.008,
      kCGImagePropertyExifFocalLength as String: 4.2,
      kCGImagePropertyExifDateTimeOriginal as String: "2024:05:06 07:08:09",
      kCGImagePropertyExifLensModel as String: "Test Lens",
    ], tiff: [
      kCGImagePropertyTIFFMake as String: "Danaview",
      kCGImagePropertyTIFFModel as String: "Fixture Cam",
    ], gps: [
      kCGImagePropertyGPSLatitude as String: 52.5,
      kCGImagePropertyGPSLatitudeRef as String: "N",
      kCGImagePropertyGPSLongitude as String: 13.4,
      kCGImagePropertyGPSLongitudeRef as String: "W",
    ])
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    let base = PhotoDetailRecord(localIdentifier: "x", isRaw: false, isHdr: false, isLivePhoto: false, locallyAvailable: true)
    let d = PhotoAssetMapping.detail(from: props, base: base)
    XCTAssertEqual(d.iso, 200)
    XCTAssertEqual(d.aperture ?? 0, 1.8, accuracy: 0.01)
    XCTAssertEqual(d.exposureSeconds ?? 0, 0.008, accuracy: 0.0001)
    XCTAssertEqual(d.focalLengthMm ?? 0, 4.2, accuracy: 0.01)
    XCTAssertEqual(d.cameraMake, "Danaview")
    XCTAssertEqual(d.cameraModel, "Fixture Cam")
    XCTAssertEqual(d.lensModel, "Test Lens")
    XCTAssertNotNil(d.takenAtMs)
    XCTAssertEqual(d.latitude ?? 0, 52.5, accuracy: 0.001)
    XCTAssertEqual(d.longitude ?? 0, -13.4, accuracy: 0.001)
    XCTAssertEqual(d.bitDepth, 8)
  }

  func testAlbumsListOnlyThoseHoldingPhotosCountedByPhotos() {
    typealias C = PhotoAlbumListing.Candidate
    let candidates = [
      C(albumId: "favs", title: "Favourites", isSmart: true, isCloudShared: false, isExcludedSmart: false, photoCount: 4),
      C(albumId: "videos", title: "Videos", isSmart: true, isCloudShared: false, isExcludedSmart: false, photoCount: 0),
      C(albumId: "recents", title: "Recents", isSmart: true, isCloudShared: false, isExcludedSmart: true, photoCount: 9),
      C(albumId: "trip", title: "Trip", isSmart: false, isCloudShared: false, isExcludedSmart: false, photoCount: 2),
      C(albumId: "clips", title: "Clips only", isSmart: false, isCloudShared: false, isExcludedSmart: false, photoCount: 0),
      C(albumId: "family", title: nil, isSmart: false, isCloudShared: true, isExcludedSmart: false, photoCount: 1),
    ]
    XCTAssertEqual(PhotoAlbumListing.records(candidates), [
      PhotoAlbumRecord(albumId: "favs", title: "Favourites", kind: .smart, estimatedCount: 4),
      PhotoAlbumRecord(albumId: "trip", title: "Trip", kind: .user, estimatedCount: 2),
      PhotoAlbumRecord(albumId: "family", title: "", kind: .shared, estimatedCount: 1),
    ])
    XCTAssertEqual(PhotoAlbumListing.records([]), [])
  }
}
