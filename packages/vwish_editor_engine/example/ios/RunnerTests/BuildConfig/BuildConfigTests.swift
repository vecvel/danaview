// OWNER: ENG-06
//
// Regression tests for the frozen iOS build configuration (vwish_editor_engine.podspec), ported from
// the IOS-01 spike's linkage and kernel checks (docs/editor/spikes/IOS-01.md §2.1, §3; V-N9):
//
// - the prebuilt Core Image kernels ship in the `VWEditorKernels` resource bundle INSIDE the pod's
//   own bundle (the example host uses `use_frameworks!`, i.e. dynamic frameworks, so the pod bundle
//   is App.app/Frameworks/vwish_editor_engine.framework and Bundle.main does not have it);
// - once IOS-09 ships vw_kernels.<sdk>.metallib, every ARCH §13.2 kernel loads from the bundle with
//   CIKernel(functionName:fromMetalLibraryData:) (skipped until then);
// - the pod is built for the iOS 15.0 floor (D-29, D-41) and the frameworks the engine needs resolve.

import AVFoundation
import BackgroundTasks
import CoreImage
import Metal
import MediaToolbox
import VideoToolbox
import XCTest

@testable import vwish_editor_engine

final class BuildConfigTests: XCTestCase {
    /// The kernel names ARCH §13.2 / IOS-09 implement (D-08 order).
    private static let kernelNames = [
        "vw_look", "vw_blur_h", "vw_blur_v", "vw_sharpen", "vw_vignette_mask", "vw_cmask", "vw_reveal", "vw_matte",
    ]

    private var podBundle: Bundle { Bundle(for: VwishEditorEnginePlugin.self) }

    private var kernelBundle: Bundle? {
        podBundle.url(forResource: "VWEditorKernels", withExtension: "bundle").flatMap(Bundle.init(url:))
    }

    func testKernelResourceBundleShipsInsideThePodBundle() throws {
        XCTAssertNotEqual(podBundle.bundleURL, Bundle.main.bundleURL, "the example host links the pod as a dynamic framework")
        XCTAssertEqual(podBundle.bundleURL.lastPathComponent, "vwish_editor_engine.framework")
        let bundle = try XCTUnwrap(kernelBundle, "VWEditorKernels.bundle missing from the pod bundle (podspec resource_bundles)")
        XCTAssertEqual(bundle.bundleURL.deletingLastPathComponent().standardizedFileURL, podBundle.bundleURL.standardizedFileURL)
        XCTAssertNil(
            Bundle.main.url(forResource: "VWEditorKernels", withExtension: "bundle"),
            "with dynamic frameworks the kernels are not in Bundle.main: the loader must use Bundle(for:)"
        )
    }

    func testOnlyMetallibsShipInTheKernelBundle() throws {
        let bundle = try XCTUnwrap(kernelBundle)
        let files = try FileManager.default.contentsOfDirectory(atPath: try XCTUnwrap(bundle.resourcePath))
        let payload = files.filter { $0 != "Info.plist" && $0 != "_CodeSignature" }
        for name in payload {
            XCTAssertTrue(name.hasSuffix(".metallib"), "unexpected file in VWEditorKernels.bundle: \(name)")
            XCTAssertTrue(name.hasPrefix("vw_kernels."), "unexpected metallib name: \(name)")
        }
    }

    func testPrivacyManifestBundleShips() throws {
        let url = try XCTUnwrap(podBundle.url(forResource: "vwish_editor_engine_privacy", withExtension: "bundle"))
        let bundle = try XCTUnwrap(Bundle(url: url))
        XCTAssertNotNil(bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
    }

    func testKernelsLoadFromTheBundleWhenIOS09HasShippedThem() throws {
        #if targetEnvironment(simulator)
            let name = "vw_kernels.iphonesimulator"
        #else
            let name = "vw_kernels.iphoneos"
        #endif
        let bundle = try XCTUnwrap(kernelBundle)
        guard let url = bundle.url(forResource: name, withExtension: "metallib") else {
            throw XCTSkip("\(name).metallib not shipped yet (IOS-09 builds the kernels)")
        }
        let data = try Data(contentsOf: url)
        XCTAssertFalse(data.isEmpty)
        for kernel in Self.kernelNames {
            XCTAssertNoThrow(try CIKernel(functionName: kernel, fromMetalLibraryData: data), kernel)
        }
    }

    func testPodIsBuiltForTheIOS15Floor() throws {
        let minimum = try XCTUnwrap(podBundle.object(forInfoDictionaryKey: "MinimumOSVersion") as? String)
        XCTAssertEqual(minimum, "15.0")
    }

    func testEngineFrameworksResolve() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "the editor requires a Metal device (ARCH §3.1)")
        let context = CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        XCTAssertNotNil(context)
        XCTAssertNotNil(NSClassFromString("AVAssetReader"))
        XCTAssertNotNil(NSClassFromString("AVPlayerItemVideoOutput"))
        XCTAssertNotNil(NSClassFromString("BGTaskScheduler"), "BackgroundTasks is weak-linked but present on iOS 15+")
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: 64, height: 64, codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &session)
        XCTAssertEqual(status, noErr, "VideoToolbox linked and an H.264 encoder is available")
        if let session { VTCompressionSessionInvalidate(session) }
        let tapCreate: Any = MTAudioProcessingTapCreate
        XCTAssertNotNil(tapCreate, "MediaToolbox linked (IOS-18 GainTap)")
    }
}
