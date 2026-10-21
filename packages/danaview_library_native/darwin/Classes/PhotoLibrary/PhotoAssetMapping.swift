// OWNER: HOM-02
//
// PHAsset → PhotoAssetRecord and image properties → PhotoDetailRecord (ARCH v1.2 §8; V2-V2 Apple
// half): RAW from the asset's resources (`public.camera-raw-image` conformance, RAW+JPEG pairs as
// `.alternatePhoto`), HDR from `photoHDR`, Live from `photoLive` (or a paired-video resource),
// HEIC/AVIF from the primary resource's UTI. EXIF basics come from ImageIO properties, which reads
// headers without decoding pixels.

import Foundation
import ImageIO
import Photos

enum PhotoAssetMapping {
  /// The resource whose name, type and bytes stand for [asset] (the original, not an edit).
  static func primaryResource(_ resources: [PHAssetResource], kind: PhotoAssetKind) -> PHAssetResource? {
    let preferred: [PHAssetResourceType] = kind == .video ? [.video, .fullSizeVideo] : [.photo, .fullSizePhoto, .alternatePhoto]
    for type in preferred {
      if let r = resources.first(where: { $0.type == type }) { return r }
    }
    return resources.first
  }

  /// The resource a copy writes: the current (edited) version when there is one, else the original.
  static func copyResource(_ resources: [PHAssetResource], kind: PhotoAssetKind, pairedVideo: Bool) -> PHAssetResource? {
    let order: [PHAssetResourceType]
    if pairedVideo {
      order = [.fullSizePairedVideo, .pairedVideo]
    } else if kind == .video {
      order = [.fullSizeVideo, .video]
    } else {
      order = [.fullSizePhoto, .photo, .alternatePhoto]
    }
    for type in order {
      if let r = resources.first(where: { $0.type == type }) { return r }
    }
    return nil
  }

  /// The kind of [asset], or nil for audio and unknown assets (never listed).
  static func kind(of asset: PHAsset) -> PhotoAssetKind? {
    switch asset.mediaType {
    case .image: return .photo
    case .video: return .video
    default: return nil
    }
  }

  /// The grid record of [asset]; [resources] defaults to the asset's resources.
  static func record(from asset: PHAsset, resources: [PHAssetResource]? = nil) -> PhotoAssetRecord? {
    guard let kind = kind(of: asset) else { return nil }
    let all = resources ?? PHAssetResource.assetResources(for: asset)
    let primary = primaryResource(all, kind: kind)
    let subtypes = asset.mediaSubtypes
    let isRaw = kind == .photo && all.contains { ($0.type == .photo || $0.type == .alternatePhoto) && PhotoTypes.isRaw(uti: $0.uniformTypeIdentifier) }
    let uti = primary?.uniformTypeIdentifier
    let name = primary?.originalFilename
    return PhotoAssetRecord(
      localIdentifier: asset.localIdentifier,
      kind: kind,
      widthPx: asset.pixelWidth,
      heightPx: asset.pixelHeight,
      creationTimeMs: asset.creationDate.map(millis),
      modificationTimeMs: asset.modificationDate.map(millis),
      durationMs: kind == .video ? Int64((asset.duration * 1000).rounded()) : 0,
      isFavorite: asset.isFavorite,
      isRaw: isRaw,
      isHdr: subtypes.contains(.photoHDR),
      isLivePhoto: kind == .photo && (subtypes.contains(.photoLive) || all.contains { $0.type == .pairedVideo }),
      isScreenshot: subtypes.contains(.photoScreenshot),
      originalFilename: name,
      uti: uti,
      mimeType: PhotoTypes.mimeType(uti: uti) ?? PhotoTypes.mimeType(fileName: name)
    )
  }

  /// Milliseconds since the epoch.
  static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

  /// Fills the EXIF fields of [base] from ImageIO [properties] (`CGImageSourceCopyPropertiesAtIndex`).
  static func detail(from properties: [String: Any], base: PhotoDetailRecord) -> PhotoDetailRecord {
    var d = base
    let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
    let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
    let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
    let aux = properties[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] ?? [:]
    if let isos = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber], let iso = isos.first {
      d.iso = iso.intValue
    }
    d.aperture = (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue ?? d.aperture
    d.exposureSeconds = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue ?? d.exposureSeconds
    d.focalLengthMm = (exif[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue ?? d.focalLengthMm
    d.cameraMake = nonEmpty(tiff[kCGImagePropertyTIFFMake as String]) ?? d.cameraMake
    d.cameraModel = nonEmpty(tiff[kCGImagePropertyTIFFModel as String]) ?? d.cameraModel
    d.lensModel = nonEmpty(exif[kCGImagePropertyExifLensModel as String]) ?? nonEmpty(aux[kCGImagePropertyExifAuxLensModel as String]) ?? d.lensModel
    if let original = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
      let offset = exif["OffsetTimeOriginal"] as? String
      d.takenAtMs = exifDate(original, offset: offset).map(millis) ?? d.takenAtMs
    }
    if let lat = (gps[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue,
       let lon = (gps[kCGImagePropertyGPSLongitude as String] as? NSNumber)?.doubleValue {
      let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String
      let lonRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String
      d.latitude = latRef == "S" ? -lat : lat
      d.longitude = lonRef == "W" ? -lon : lon
    }
    d.colorProfile = nonEmpty(properties[kCGImagePropertyProfileName as String]) ?? d.colorProfile
    d.bitDepth = (properties[kCGImagePropertyDepth as String] as? NSNumber)?.intValue ?? d.bitDepth
    return d
  }

  /// Parses an EXIF `yyyy:MM:dd HH:mm:ss` time with an optional `±HH:mm` offset (local time of the
  /// device otherwise, as cameras record it).
  static func exifDate(_ value: String, offset: String?) -> Date? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    if let offset = offset, !offset.isEmpty {
      f.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
      if let d = f.date(from: value + offset) { return d }
    }
    f.dateFormat = "yyyy:MM:dd HH:mm:ss"
    f.timeZone = TimeZone.current
    return f.date(from: value)
  }

  private static func nonEmpty(_ value: Any?) -> String? {
    guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
    return s
  }
}
