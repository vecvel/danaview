import CoreImage
import Foundation

/// Grade parameters of the spike's `vw_look` kernel (ARCH §11.6 subset, model units in [-1, 1]).
public struct SpikeLook: Equatable {
  public var exposure: Float
  public var brightness: Float
  public var contrast: Float
  public var saturation: Float

  public init(exposure: Float = 0, brightness: Float = 0, contrast: Float = 0, saturation: Float = 0) {
    self.exposure = exposure
    self.brightness = brightness
    self.contrast = contrast
    self.saturation = saturation
  }

  public static let identity = SpikeLook()
}

/// IOS-01 spike (V-N9): Core Image kernels precompiled with `-fcikernel` (tools/build_metallibs.sh)
/// into one metallib per SDK, shipped in the pod's resource bundle
/// (`VWSpikeKernels.bundle/vw_spike_kernels.<sdk>.metallib`) and loaded with
/// `CIKernel(functionName:fromMetalLibraryData:)`.
public final class SpikeKernels {
  public enum LoadError: Error, CustomStringConvertible {
    case bundleMissing
    case metallibMissing(String)
    case kernel(String, String)

    public var description: String {
      switch self {
      case .bundleMissing: return "VWSpikeKernels.bundle not found"
      case .metallibMissing(let path): return "\(SpikeKernels.metallibName).metallib missing in \(path)"
      case .kernel(let name, let error): return "kernel \(name) failed to load: \(error)"
      }
    }
  }

  public static let bundleName = "VWSpikeKernels"

  /// The simulator needs the `air64-apple-ios15.0-simulator` build of the library.
  public static var metallibName: String {
    #if targetEnvironment(simulator)
      return "vw_spike_kernels.iphonesimulator"
    #else
      return "vw_spike_kernels.iphoneos"
    #endif
  }

  public let look: CIColorKernel
  public let blurH: CIKernel
  public let blurV: CIKernel
  /// Where the metallib was found (static library: inside the app bundle; framework: inside the
  /// framework bundle).
  public let metallibURL: URL
  public let metallibData: Data
  /// Time spent creating the three kernels from the metallib data (ms).
  public let loadMs: Double

  public init() throws {
    guard let bundle = SpikeKernels.resourceBundle() else { throw LoadError.bundleMissing }
    guard let url = bundle.url(forResource: SpikeKernels.metallibName, withExtension: "metallib") else {
      throw LoadError.metallibMissing(bundle.bundlePath)
    }
    let data = try Data(contentsOf: url)
    let start = CFAbsoluteTimeGetCurrent()
    do {
      look = try CIColorKernel(functionName: "vw_look", fromMetalLibraryData: data)
    } catch {
      throw LoadError.kernel("vw_look", "\(error)")
    }
    do {
      blurH = try CIKernel(functionName: "vw_blur_h", fromMetalLibraryData: data)
      blurV = try CIKernel(functionName: "vw_blur_v", fromMetalLibraryData: data)
    } catch {
      throw LoadError.kernel("vw_blur_h/v", "\(error)")
    }
    loadMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
    metallibURL = url
    metallibData = data
  }

  /// The pod resource bundle: next to this class (use_frameworks!) or in the main bundle (static
  /// library linkage).
  public static func resourceBundle() -> Bundle? {
    let candidates = [Bundle(for: SpikeKernels.self), Bundle.main]
    for host in candidates {
      if let url = host.url(forResource: bundleName, withExtension: "bundle"),
        let bundle = Bundle(url: url)
      {
        return bundle
      }
    }
    return nil
  }

  /// Applies `vw_look` (no-op fast path for the identity look is deliberately NOT taken, so the
  /// kernel is always exercised).
  public func applyLook(_ image: CIImage, _ p: SpikeLook) -> CIImage {
    look.apply(
      extent: image.extent,
      arguments: [image, p.exposure, p.brightness, p.contrast, p.saturation]) ?? image
  }

  /// Separable Gaussian blur with clamp-to-edge; σ in render pixels; skipped below 0.5.
  public func applyBlur(_ image: CIImage, sigma: Float) -> CIImage {
    guard sigma >= 0.5 else { return image }
    let extent = image.extent
    let r = CGFloat(ceil(3 * sigma))
    let clamped = image.clampedToExtent()
    // The kernels read clamped (infinite) inputs, so their output is non-zero everywhere. Declare
    // that honestly (infinite DOD) and crop afterwards: when the kernel output was declared with
    // the source extent, Core Image dropped the following `cropped(to: extent)` as a no-op and a
    // placed (scaled/translated) blurred layer covered the whole canvas with its clamped edges
    // (report §2.5; KernelTests.testTwoLayerCompositeWithBlurKeepsPlacement).
    let h =
      blurH.apply(
        extent: .infinite,
        roiCallback: { _, rect in rect.insetBy(dx: -r, dy: 0) },
        arguments: [clamped, sigma]) ?? image
    let v =
      blurV.apply(
        extent: .infinite,
        roiCallback: { _, rect in rect.insetBy(dx: 0, dy: -r) },
        arguments: [h, sigma]) ?? h
    return v.cropped(to: extent)
  }
}
