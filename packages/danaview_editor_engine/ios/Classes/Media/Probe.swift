// OWNER: IOS-02
//
// Media probe (ARCH §15 'Probe / compatibility', §12.5, D-27). Containers are sniffed from the
// first bytes (MKV/WebM/AVI are never handed to AVFoundation: probe answers editable = false with
// `container_unsupported_ios`, D-43 owner default "no remux"). Images go through ImageIO; audio and
// video through AVURLAsset async loads (duration, tracks, isPlayable, isComposable,
// hasProtectedContent) and the tracks' format descriptions: codec, bit depth, transfer
// (HLG/PQ -> ColorTransfer), nominal and measured fps with VFR detection (minFrameDuration against
// the average), preferredTransform -> rotation and display size, audio streams, channels and rate.
// Never puts paths into errors or logs.

import AVFoundation
import CoreMedia
import Foundation
import ImageIO

/// Container families recognised from the first bytes of a file.
enum SniffedContainer: String {
    case mp4, mov, m4a, threeGP = "3gp", matroska, webm, avi, wav, aiff, mp3, aac, flac, caf, ogg
    case jpeg, png, heic, gif, tiff, webp, bmp
    case unknown

    /// Containers AVFoundation cannot edit on iOS (ARCH §15).
    var unsupportedOnIOS: Bool { self == .matroska || self == .webm || self == .avi || self == .ogg }

    var isImage: Bool {
        switch self {
        case .jpeg, .png, .heic, .gif, .tiff, .webp, .bmp: return true
        default: return false
        }
    }

    /// Sniffs [url]'s first 64 bytes; falls back to the extension.
    static func sniff(_ url: URL) -> SniffedContainer {
        var head = Data()
        if let handle = try? FileHandle(forReadingFrom: url) {
            head = handle.readData(ofLength: 64)
            try? handle.close()
        }
        return sniff(head: head, ext: url.pathExtension.lowercased())
    }

    static func sniff(head: Data, ext: String) -> SniffedContainer {
        let b = [UInt8](head)
        func ascii(_ offset: Int, _ length: Int) -> String? {
            guard b.count >= offset + length else { return nil }
            return String(bytes: b[offset..<(offset + length)], encoding: .ascii)
        }
        if b.count >= 4, b[0] == 0x1A, b[1] == 0x45, b[2] == 0xDF, b[3] == 0xA3 {
            // EBML: the DocType decides between Matroska and WebM.
            let text = String(decoding: b, as: UTF8.self)
            return text.contains("webm") ? .webm : .matroska
        }
        if ascii(0, 4) == "RIFF" {
            switch ascii(8, 4) {
            case "AVI ": return .avi
            case "WAVE": return .wav
            case "WEBP": return .webp
            default: break
            }
        }
        if ascii(0, 4) == "FORM", let kind = ascii(8, 4), kind == "AIFF" || kind == "AIFC" { return .aiff }
        if ascii(0, 4) == "OggS" { return .ogg }
        if ascii(0, 4) == "fLaC" { return .flac }
        if ascii(0, 4) == "caff" { return .caf }
        if ascii(0, 3) == "ID3" { return .mp3 }
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return .jpeg }
        if b.count >= 4, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return .png }
        if ascii(0, 4) == "GIF8" { return .gif }
        if b.count >= 2, b[0] == 0x42, b[1] == 0x4D, ext == "bmp" { return .bmp }
        if b.count >= 4, (b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A) || (b[0] == 0x4D && b[1] == 0x4D && b[3] == 0x2A) {
            return .tiff
        }
        if ascii(4, 4) == "ftyp", let brand = ascii(8, 4) {
            switch brand {
            case "qt  ": return .mov
            case "M4A ", "M4B ", "M4P ": return .m4a
            case "heic", "heix", "mif1", "msf1", "heim", "heis", "avif": return .heic
            default:
                if brand.hasPrefix("3g") { return .threeGP }
                return ext == "mov" ? .mov : (ext == "m4a" ? .m4a : .mp4)
            }
        }
        // QuickTime files without ftyp start with moov/mdat/wide/free atoms.
        if let atom = ascii(4, 4), ["moov", "mdat", "wide", "free", "skip", "pnot"].contains(atom) { return .mov }
        if b.count >= 2, b[0] == 0xFF, (b[1] & 0xE0) == 0xE0 {
            // MPEG audio or ADTS frame sync.
            return (b[1] & 0x06) == 0 ? .aac : .mp3
        }
        switch ext {
        case "mp4", "m4v": return .mp4
        case "mov", "qt": return .mov
        case "m4a": return .m4a
        case "mkv": return .matroska
        case "webm": return .webm
        case "avi": return .avi
        case "wav": return .wav
        case "mp3": return .mp3
        case "aac": return .aac
        default: return .unknown
        }
    }
}

/// Probe/compatibility issue codes (`MediaProbe.issues`, `NotEditable.code`).
enum ProbeIssue {
    static let containerUnsupportedIOS = "container_unsupported_ios"
    static let codecUnsupported = "codec_unsupported"
    static let protectedContent = "protected_content"
    static let notComposable = "not_composable"
    static let notPlayable = "not_playable"
    static let notFound = "not_found"
    static let noTracks = "no_tracks"
    // Informational (still editable).
    static let hdr = "hdr"
    static let highBitDepth = "high_bit_depth"
    static let variableFrameRate = "variable_frame_rate"
}

final class Probe: MediaProbing {
    private let context: EngineContext

    init(context: EngineContext) {
        self.context = context
    }

    func probe(_ media: ResolvedMediaMsg, url: URL, reply: @escaping EngineReply<ProbeMsg>) {
        Task.detached(priority: .userInitiated) {
            do {
                reply(.success(try await Probe.probe(url: url)))
            } catch {
                reply(.failure(EngineError.from(error)))
            }
        }
    }

    // MARK: Probe

    /// Probes [url].
    static func probe(url: URL) async throws -> ProbeMsg {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw EngineError.from(error)
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let container = SniffedContainer.sniff(url)
        if container.unsupportedOnIOS {
            return refused(container: container, size: size)
        }
        if container.isImage {
            return try probeImage(url: url, container: container, size: size)
        }
        return try await probeAV(url: url, container: container, size: size)
    }

    /// Containers AVFoundation cannot open: editable = false, nothing loaded.
    static func refused(container: SniffedContainer, size: Int64) -> ProbeMsg {
        let audioOnly = container == .ogg
        return ProbeMsg(
            kind: audioOnly ? .audio : .video, durationUs: 0, hasVideo: !audioOnly, hasAudio: audioOnly,
            rotation: 0, variableFrameRate: false, container: container.rawValue, audioStreams: 0,
            transfer: .sdr, sizeBytes: size, editable: false, issues: [ProbeIssue.containerUnsupportedIOS])
    }

    static func probeImage(url: URL, container: SniffedContainer, size: Int64) throws -> ProbeMsg {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value
        else {
            throw EngineError(.unsupportedMedia, "image not decodable")
        }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotation: Int64
        switch orientation {
        case 3, 4: rotation = 180
        case 5, 6: rotation = 90
        case 7, 8: rotation = 270
        default: rotation = 0
        }
        let swap = rotation == 90 || rotation == 270
        let depth = (props[kCGImagePropertyDepth] as? NSNumber)?.int64Value
        return ProbeMsg(
            kind: .image, durationUs: 0, hasVideo: false, hasAudio: false,
            width: swap ? height : width, height: swap ? width : height, rotation: rotation,
            variableFrameRate: false, container: container.rawValue, audioStreams: 0,
            bitDepth: depth, transfer: .sdr, sizeBytes: size, editable: true, issues: [])
    }

    static func probeAV(url: URL, container: SniffedContainer, size: Int64) async throws -> ProbeMsg {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let (duration, playable, composable, protected) = try await asset.load(
            .duration, .isPlayable, .isComposable, .hasProtectedContent)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if videoTracks.isEmpty && audioTracks.isEmpty {
            throw EngineError(.unsupportedMedia, "no audio or video tracks")
        }
        var issues: [String] = []
        var editable = true
        if protected {
            issues.append(ProbeIssue.protectedContent)
            editable = false
        }
        if !playable {
            issues.append(ProbeIssue.codecUnsupported)
            editable = false
        }
        if !composable {
            issues.append(ProbeIssue.notComposable)
            editable = false
        }

        var message = ProbeMsg(
            kind: videoTracks.isEmpty ? .audio : .video,
            durationUs: microseconds(duration),
            hasVideo: !videoTracks.isEmpty, hasAudio: !audioTracks.isEmpty,
            rotation: 0, variableFrameRate: false, container: container == .unknown ? nil : container.rawValue,
            audioStreams: Int64(audioTracks.count), transfer: .sdr, sizeBytes: size, editable: editable,
            issues: issues)

        if let video = videoTracks.first {
            let facts = try await videoFacts(video)
            message.width = facts.displayWidth
            message.height = facts.displayHeight
            message.rotation = facts.rotation
            message.nominalFps = facts.averageFps
            message.nominalFrameRate = facts.averageFps.map { Int64(max(1, $0.rounded())) }
            message.variableFrameRate = facts.variableFrameRate
            message.videoCodec = facts.codec
            message.bitDepth = facts.bitDepth
            message.transfer = facts.transfer
            if facts.transfer != .sdr { message.issues.append(ProbeIssue.hdr) }
            if (facts.bitDepth ?? 8) > 8 { message.issues.append(ProbeIssue.highBitDepth) }
            if facts.variableFrameRate { message.issues.append(ProbeIssue.variableFrameRate) }
        }
        if let audio = audioTracks.first {
            let descriptions = try await audio.load(.formatDescriptions)
            if let description = descriptions.first {
                message.audioCodec = audioCodecName(description)
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                    message.channels = Int64(asbd.mChannelsPerFrame)
                    message.sampleRate = Int64(asbd.mSampleRate.rounded())
                }
            }
        }
        return message
    }

    // MARK: Video facts

    struct VideoFacts: Equatable {
        var displayWidth: Int64
        var displayHeight: Int64
        var rotation: Int64
        var averageFps: Double?
        var variableFrameRate: Bool
        var codec: String?
        var bitDepth: Int64?
        var transfer: ColorTransferMsg
    }

    static func videoFacts(_ track: AVAssetTrack) async throws -> VideoFacts {
        let (natural, transform, nominalRate, minFrameDuration, descriptions, timeRange) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .minFrameDuration, .formatDescriptions, .timeRange)
        let rotation = rotationDegrees(transform)
        let swap = rotation == 90 || rotation == 270
        let width = Int64(abs(natural.width).rounded())
        let height = Int64(abs(natural.height).rounded())
        let fps: Double? = nominalRate > 0 ? Double(nominalRate) : nil
        var vfr = false
        if let fps = fps, minFrameDuration.isValid, minFrameDuration.seconds > 0 {
            vfr = isVariableFrameRate(averageFps: fps, minFrameDuration: minFrameDuration.seconds)
        }
        _ = timeRange
        var facts = VideoFacts(
            displayWidth: swap ? height : width, displayHeight: swap ? width : height, rotation: rotation,
            averageFps: fps, variableFrameRate: vfr, codec: nil, bitDepth: nil, transfer: .sdr)
        if let description = descriptions.first {
            facts.codec = videoCodecName(description)
            facts.bitDepth = bitDepth(description)
            facts.transfer = transfer(description)
        }
        return facts
    }

    /// VFR when the shortest frame is clearly shorter than the average frame (> 5 %), as on
    /// screen recordings and phone captures with dropped frames.
    static func isVariableFrameRate(averageFps: Double, minFrameDuration: Double) -> Bool {
        guard averageFps > 0, minFrameDuration > 0 else { return false }
        return (1.0 / averageFps) / minFrameDuration > 1.05
    }

    /// The clockwise rotation (0/90/180/270) a preferredTransform applies.
    static func rotationDegrees(_ t: CGAffineTransform) -> Int64 {
        let degrees = atan2(Double(t.b), Double(t.a)) * 180 / .pi
        let snapped = Int64((degrees / 90).rounded()) * 90
        return ((snapped % 360) + 360) % 360
    }

    static func microseconds(_ time: CMTime) -> Int64 {
        guard time.isValid, time.isNumeric, time.timescale > 0 else { return 0 }
        return Int64((Double(time.value) * 1_000_000 / Double(time.timescale)).rounded())
    }

    // MARK: Format descriptions

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(bytes: bytes, encoding: .macOSRoman) ?? "????"
    }

    static func videoCodecName(_ description: CMFormatDescription) -> String {
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        switch fourCC(subtype) {
        case "avc1", "avc3": return "h264"
        case "hvc1", "hev1": return "hevc"
        case "dvh1", "dvhe": return "hevc"
        case "vp09": return "vp9"
        case "av01": return "av1"
        case "mp4v": return "mpeg4"
        case "jpeg", "mjpa", "mjpb": return "mjpeg"
        case "apcn", "apch", "apcs", "apco", "ap4h", "ap4x": return "prores"
        default: return fourCC(subtype).trimmingCharacters(in: .whitespaces)
        }
    }

    static func audioCodecName(_ description: CMFormatDescription) -> String {
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        switch subtype {
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD,
             kAudioFormatMPEG4AAC_ELD:
            return "aac"
        case kAudioFormatLinearPCM:
            guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return "pcm" }
            let float = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let big = asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
            let signed = asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
            let kind = float ? "f" : (signed || asbd.mBitsPerChannel > 8 ? "s" : "u")
            return "pcm_\(kind)\(asbd.mBitsPerChannel)\(asbd.mBitsPerChannel > 8 ? (big ? "be" : "le") : "")"
        case kAudioFormatAppleLossless: return "alac"
        case kAudioFormatMPEGLayer3: return "mp3"
        case kAudioFormatAC3: return "ac3"
        case kAudioFormatEnhancedAC3: return "eac3"
        case kAudioFormatOpus: return "opus"
        case kAudioFormatFLAC: return "flac"
        case kAudioFormatAppleIMA4: return "ima4"
        default: return fourCC(subtype).trimmingCharacters(in: .whitespaces)
        }
    }

    /// Bits per component: the format extension, else the HEVC/H.264 profile (Main10 / High10).
    static func bitDepth(_ description: CMFormatDescription) -> Int64? {
        let extensions = CMFormatDescriptionGetExtensions(description) as? [CFString: Any] ?? [:]
        if let bits = extensions[kCMFormatDescriptionExtension_BitsPerComponent] as? NSNumber {
            return bits.int64Value
        }
        let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? [String: Any] ?? [:]
        if let hvcC = atoms["hvcC"] as? Data, hvcC.count > 1 {
            let profile = hvcC[hvcC.startIndex + 1] & 0x1F
            return profile == 2 ? 10 : 8
        }
        if let avcC = atoms["avcC"] as? Data, avcC.count > 1 {
            let profile = avcC[avcC.startIndex + 1]
            return profile == 110 || profile == 122 || profile == 244 ? 10 : 8
        }
        return 8
    }

    static func transfer(_ description: CMFormatDescription) -> ColorTransferMsg {
        let extensions = CMFormatDescriptionGetExtensions(description) as? [CFString: Any] ?? [:]
        guard let value = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String else { return .sdr }
        if value == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String) { return .hlg }
        if value == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) { return .pq }
        return .sdr
    }
}
