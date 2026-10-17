import CoreImage
import Foundation

/// IOS-01 spike (V-N9 alternative): `[[stitchable]]` Core Image kernels compiled without
/// `-fcikernel` (linked with `-framework CoreImage`), loaded from
/// `DVSpikeStitchable.bundle/dv_spike_stitchable.<sdk>.metallib` with the same
/// `CIKernel(functionName:fromMetalLibraryData:)` initializers.
public final class StitchableKernels {
  public enum LoadError: Error, CustomStringConvertible {
    case bundleMissing
    case metallibMissing(String)
    case kernel(String, String)

    public var description: String {
      switch self {
      case .bundleMissing: return "DVSpikeStitchable.bundle not found"
      case .metallibMissing(let path): return "\(StitchableKernels.metallibName).metallib missing in \(path)"
      case .kernel(let name, let error): return "kernel \(name) failed to load: \(error)"
      }
    }
  }

  public static var metallibName: String {
    #if targetEnvironment(simulator)
      return "dv_spike_stitchable.iphonesimulator"
    #else
      return "dv_spike_stitchable.iphoneos"
    #endif
  }

  public let look: CIColorKernel
  public let blurH: CIKernel
  public let metallibURL: URL

  public init() throws {
    var found: Bundle?
    for host in [Bundle(for: StitchableKernels.self), Bundle.main] {
      if let url = host.url(forResource: "DVSpikeStitchable", withExtension: "bundle"),
        let bundle = Bundle(url: url)
      {
        found = bundle
        break
      }
    }
    guard let bundle = found else { throw LoadError.bundleMissing }
    guard let url = bundle.url(forResource: StitchableKernels.metallibName, withExtension: "metallib") else {
      throw LoadError.metallibMissing(bundle.bundlePath)
    }
    let data = try Data(contentsOf: url)
    do {
      look = try CIColorKernel(functionName: "dv_look_st", fromMetalLibraryData: data)
    } catch {
      throw LoadError.kernel("dv_look_st", "\(error)")
    }
    do {
      blurH = try CIKernel(functionName: "dv_blur_h_st", fromMetalLibraryData: data)
    } catch {
      throw LoadError.kernel("dv_blur_h_st", "\(error)")
    }
    metallibURL = url
  }

  public func applyLook(
    _ image: CIImage, exposure: Float, brightness: Float, contrast: Float, saturation: Float
  ) -> CIImage {
    look.apply(extent: image.extent, arguments: [image, exposure, brightness, contrast, saturation])
      ?? image
  }

  public func applyBlurH(_ image: CIImage, sigma: Float) -> CIImage {
    let r = CGFloat(ceil(3 * sigma))
    return blurH.apply(
      extent: image.extent,
      roiCallback: { _, rect in rect.insetBy(dx: -r, dy: 0) },
      arguments: [image.clampedToExtent(), sigma])?.cropped(to: image.extent) ?? image
  }
}
