// OWNER: IOS-09
//
// Core Image kernel wrappers (ARCH §11.6 render math in D-08 order, ARCH §13.2 compositor rules).
//
// The kernels are PREBUILT `-fcikernel` metallibs (Render/Shaders/DanaviewKernels.metal →
// Render/Shaders/Prebuilt/dv_kernels.<sdk>.metallib via Shaders/build_kernels.sh; IOS-01 §3, V-N9)
// shipped in the pod's `DVEditorKernels` resource bundle. The loader finds that bundle next to this
// pod's classes (`Bundle(for:)`; dynamic frameworks put it inside the framework bundle, static linkage
// in the app bundle), never through `Bundle.main` alone, and picks the simulator or device library with
// `#if targetEnvironment(simulator)`.
//
// Every function takes and returns PREMULTIPLIED CIImages in Core Image's y-up space with colour
// management off (`makeContext`: working/output colour space NSNull). Per-layer order (D-08), used by
// IOS-10's LayerRenderer:
//
//   look (crop sampling → chroma key + spill → grade → LUT) → blur → sharpen → vignette + mask
//   → place (CIImage.transformed with the §11.6 matrix, opacity) → canvas masks → composite
//
// Sprites: reveal → place. Solids/images: place (they skip crop…mask except as the plan says).
// Neighbour-reading kernels (blur, sharpen) run on `clampedToExtent()` inputs with an INFINITE
// declared extent and are cropped afterwards (IOS-01 §2.5: a crop equal to the declared extent is
// elided and a placed blurred layer would cover the canvas).

import CoreImage
import Foundation
import Metal

final class Kernels {
    enum LoadError: Error, CustomStringConvertible {
        case bundleMissing
        case metallibMissing(String)
        case kernel(String, String)

        var description: String {
            switch self {
            case .bundleMissing: return "\(Kernels.bundleName).bundle not found next to the engine classes"
            case .metallibMissing(let path): return "\(Kernels.metallibName).metallib missing in \(path)"
            case .kernel(let name, let error): return "kernel \(name) failed to load: \(error)"
            }
        }
    }

    /// The resource bundle holding the metallibs (podspec `resource_bundles`).
    static let bundleName = "DVEditorKernels"

    /// Every kernel in the metallib (ARCH §13.2).
    static let functionNames = [
        "dv_look", "dv_blur_h", "dv_blur_v", "dv_sharpen", "dv_vignette_mask", "dv_cmask", "dv_reveal", "dv_matte",
    ]

    /// The SDK-specific metallib (the simulator needs the `-simulator` AIR target).
    static var metallibName: String {
        #if targetEnvironment(simulator)
            return "dv_kernels.iphonesimulator"
        #else
            return "dv_kernels.iphoneos"
        #endif
    }

    let look: CIKernel
    let blurH: CIKernel
    let blurV: CIKernel
    let sharpenKernel: CIKernel
    let vignetteMaskKernel: CIColorKernel
    let cmaskKernel: CIColorKernel
    let revealKernel: CIColorKernel
    let matteKernel: CIColorKernel
    /// Time spent creating the kernels from the metallib data (ms).
    let loadMs: Double

    /// A 1×1 image passed as the LUT sampler when no LUT is applied.
    private let noLut = CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))

    init(metallibData data: Data) throws {
        let start = CFAbsoluteTimeGetCurrent()
        func general(_ name: String) throws -> CIKernel {
            do { return try CIKernel(functionName: name, fromMetalLibraryData: data) } catch {
                throw LoadError.kernel(name, "\(error)")
            }
        }
        func color(_ name: String) throws -> CIColorKernel {
            do { return try CIColorKernel(functionName: name, fromMetalLibraryData: data) } catch {
                throw LoadError.kernel(name, "\(error)")
            }
        }
        look = try general("dv_look")
        blurH = try general("dv_blur_h")
        blurV = try general("dv_blur_v")
        sharpenKernel = try general("dv_sharpen")
        vignetteMaskKernel = try color("dv_vignette_mask")
        cmaskKernel = try color("dv_cmask")
        revealKernel = try color("dv_reveal")
        matteKernel = try color("dv_matte")
        loadMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    /// Loads the kernels from the pod's resource bundle.
    convenience init() throws {
        try self.init(metallibData: try Data(contentsOf: try Self.metallibURL()))
    }

    /// The pod's `DVEditorKernels.bundle`: next to this class (dynamic framework), else in the main
    /// bundle (static linkage).
    static func resourceBundle() -> Bundle? {
        for host in [Bundle(for: Kernels.self), Bundle.main] {
            if let url = host.url(forResource: bundleName, withExtension: "bundle"), let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }

    static func metallibURL() throws -> URL {
        guard let bundle = resourceBundle() else { throw LoadError.bundleMissing }
        guard let url = bundle.url(forResource: metallibName, withExtension: "metallib") else {
            throw LoadError.metallibMissing(bundle.bundlePath)
        }
        return url
    }

    private static let sharedLock = NSLock()
    private static var sharedResult: Result<Kernels, Error>?

    /// The process-wide kernels (loaded once; CIKernels are immutable and thread-safe).
    static func shared() throws -> Kernels {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let r = sharedResult { return try r.get() }
        let r = Result { try Kernels() }
        sharedResult = r
        return try r.get()
    }

    // MARK: Context

    /// A CIContext with colour management off (ARCH §11.6, §13.2): Metal on [device], or the CPU
    /// renderer when [software] (V-N22, D-22 background path).
    static func makeContext(device: MTLDevice? = MTLCreateSystemDefaultDevice(), software: Bool = false) -> CIContext {
        var options: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .workingFormat: CIFormat.RGBAh,
            .name: software ? "danaview.render.software" : "danaview.render",
        ]
        if software {
            options[.useSoftwareRenderer] = true
            return CIContext(options: options)
        }
        if let device { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }

    // MARK: Look (crop → chroma → grade → LUT)

    struct LookParams {
        /// Crop in the input image's coordinates (y up); nil = the whole extent.
        var crop: CGRect?
        var chroma: PlanChroma?
        /// The eight adjustments in `PlanAdjust.names` order.
        var adjust: [Double] = Array(repeating: 0, count: 8)
        var lut: LutTexture?
        /// LUT intensity `i` ∈ [0, 1].
        var lutIntensity: Double = 1

        init(crop: CGRect? = nil, chroma: PlanChroma? = nil, adjust: [Double] = Array(repeating: 0, count: 8),
             lut: LutTexture? = nil, lutIntensity: Double = 1) {
            self.crop = crop
            self.chroma = chroma
            self.adjust = adjust
            self.lut = lut
            self.lutIntensity = lutIntensity
        }

        /// Nothing to do but (possibly) crop.
        var isIdentityLook: Bool {
            chroma == nil && adjust.allSatisfy { $0 == 0 } && (lut == nil || lutIntensity == 0)
        }
    }

    /// The crop rectangle of a plan crop `[l, t, r, b]` (normalized, y down) inside [extent] (y up).
    static func cropRect(_ crop: PlanCrop, in extent: CGRect) -> CGRect {
        CGRect(
            x: extent.minX + crop.l * extent.width, y: extent.minY + (1 - crop.b) * extent.height,
            width: (crop.r - crop.l) * extent.width, height: (crop.b - crop.t) * extent.height)
    }

    /// dv_look. The output extent is `(0, 0, crop.width, crop.height)`; output pixel p shows input
    /// pixel p + crop.origin. Identity looks are a plain crop/translate (no kernel).
    func look(_ image: CIImage, _ p: LookParams, forceKernel: Bool = false) -> CIImage {
        let crop = p.crop ?? image.extent
        let outExtent = CGRect(origin: .zero, size: crop.size)
        if p.isIdentityLook && !forceKernel {
            return image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        }
        let adj = p.adjust.count == 8 ? p.adjust : Array(repeating: 0, count: 8)
        var key = CIVector(x: 0, y: 0, z: 0, w: 1)
        var chroma = CIVector(x: 0, y: 0, z: 0, w: 0)
        if let c = p.chroma {
            let (kb, kr) = Self.cbcr(rgb: c.key)
            let len = (kb * kb + kr * kr).squareRoot()
            key = CIVector(x: kb, y: kr, z: c.sim * 0.25, w: max(0.001, c.smooth * 0.25))
            chroma = CIVector(x: 1, y: c.spill, z: len > 0 ? kb / len : 0, w: len > 0 ? kr / len : 0)
        }
        let exposure = adj[0]
        let g1 = CIVector(x: exposure != 0 ? pow(2, 2 * exposure) : 0, y: adj[1], z: adj[2], w: adj[3])
        let g2 = CIVector(x: adj[4], y: adj[5], z: adj[6], w: adj[7])
        let lutImage = p.lut?.image ?? noLut
        let lutp: CIVector
        if let lut = p.lut, p.lutIntensity != 0 {
            lutp = CIVector(x: CGFloat(lut.n), y: CGFloat(lut.columns), z: p.lutIntensity, w: 1)
        } else {
            lutp = CIVector(x: 2, y: 1, z: 0, w: 0)
        }
        let lutH = CGFloat(p.lut?.height ?? 1)
        let origin = crop.origin
        let lutExtent = lutImage.extent
        return look.apply(
            extent: outExtent,
            roiCallback: { index, rect in
                index == 0 ? rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -1, dy: -1) : lutExtent
            },
            arguments: [
                image, lutImage, CIVector(x: origin.x, y: origin.y, z: 0, w: 0), key, chroma, g1, g2, lutp, lutH,
            ]) ?? image
    }

    /// `(Cb, Cr)` of an RGB key `0xRRGGBB` (ARCH §11.6 chroma key).
    static func cbcr(rgb: UInt32) -> (Double, Double) {
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return ((b - y) / 1.8556, (r - y) / 1.5748)
    }

    // MARK: Blur

    /// `σ = blur·0.03·min(W, H)` in plan-canvas px.
    static func blurSigmaCanvasPx(blur: Double, canvasW: Int, canvasH: Int) -> Double {
        blur * 0.03 * Double(min(canvasW, canvasH))
    }

    /// σ in the px of the layer's source image: canvas σ ÷ `canvasPxPerSourcePx`
    /// (`base.w·|xf.s| / crop width in source px`).
    static func blurSigmaSourcePx(sigmaCanvasPx: Double, canvasPxPerSourcePx: Double) -> Double {
        sigmaCanvasPx / canvasPxPerSourcePx
    }

    /// σ in render px (render px per canvas px = [renderScale]).
    static func blurSigmaRenderPx(sigmaCanvasPx: Double, renderScale: Double) -> Double {
        sigmaCanvasPx * renderScale
    }

    /// Kernel radius `⌈3σ⌉`.
    static func blurRadius(_ sigma: Double) -> Int { Int((3 * sigma).rounded(.up)) }

    /// Blur is skipped below σ = 0.5 (px of the image being blurred).
    static func blurSkipped(_ sigma: Double) -> Bool { !(sigma >= 0.5) }

    /// Separable Gaussian (dv_blur_h then dv_blur_v), clamp-to-edge, cropped back to the input extent.
    func blur(_ image: CIImage, sigma: Double) -> CIImage {
        guard !Self.blurSkipped(sigma) else { return image }
        let extent = image.extent
        let r = CGFloat(Self.blurRadius(sigma))
        let clamped = image.clampedToExtent()
        let h = blurH.apply(
            extent: .infinite, roiCallback: { _, rect in rect.insetBy(dx: -r - 1, dy: 0) },
            arguments: [clamped, Float(sigma)]) ?? clamped
        let v = blurV.apply(
            extent: .infinite, roiCallback: { _, rect in rect.insetBy(dx: 0, dy: -r - 1) },
            arguments: [h, Float(sigma)]) ?? h
        return v.cropped(to: extent)
    }

    // MARK: Sharpen

    /// `c += sharpen·1.5·(c − box3×3(c))` on premultiplied RGB, clamped to [0, alpha].
    func sharpen(_ image: CIImage, amount: Double) -> CIImage {
        guard amount != 0 else { return image }
        let extent = image.extent
        let out = sharpenKernel.apply(
            extent: .infinite, roiCallback: { _, rect in rect.insetBy(dx: -2, dy: -2) },
            arguments: [image.clampedToExtent(), Float(amount * 1.5)])
        return out?.cropped(to: extent) ?? image
    }

    // MARK: Vignette and mask

    /// `(cos, sin)` of [deg] degrees, exact at multiples of 90° (as core `cosSinDeg`).
    static func cosSinDeg(_ deg: Double) -> (Double, Double) {
        let m = deg.truncatingRemainder(dividingBy: 360)
        let q = m < 0 ? m + 360 : m
        switch q {
        case 0: return (1, 0)
        case 90: return (0, 1)
        case 180: return (-1, 0)
        case 270: return (0, -1)
        default:
            let rad = deg * Double.pi / 180
            return (cos(rad), sin(rad))
        }
    }

    /// dv_vignette_mask over the image's extent (the layer box): vignette `amount` with
    /// `aspect = base.w / base.h`, then the item [mask] in base px.
    func vignetteMask(_ image: CIImage, vignette: Double, aspect: Double, mask: PlanMask?, base: PlanSize) -> CIImage {
        guard vignette > 0 || mask != nil else { return image }
        let e = image.extent
        let box = CIVector(x: e.minX, y: e.minY, z: e.width, w: e.height)
        let vig = CIVector(x: max(0, vignette), y: aspect, z: 0, w: 0)
        var mgeom = CIVector(x: 0.5, y: 0.5, z: base.w, w: base.h)
        var msize = CIVector(x: 0, y: 0, z: 0, w: 0)
        var mrot = CIVector(x: 1, y: 0, z: 0, w: 0)
        var mopt = CIVector(x: 0, y: 0, z: 0, w: 0)
        if let m = mask {
            let w = m.w * base.w
            let h = m.h * base.h
            let mn = min(w, h)
            mgeom = CIVector(x: m.cx, y: m.cy, z: base.w, w: base.h)
            msize = CIVector(x: w / 2, y: h / 2, z: m.corner * mn, w: m.feather * 0.25 * mn)
            let (c, s) = Self.cosSinDeg(m.r)
            mrot = CIVector(x: c, y: s, z: 0, w: 0)
            mopt = CIVector(x: 1, y: m.shape == .ellipse ? 1 : 0, z: m.inv ? 1 : 0, w: m.op)
        }
        return vignetteMaskKernel.apply(extent: e, arguments: [image, box, vig, mgeom, msize, mrot, mopt]) ?? image
    }

    // MARK: Canvas masks

    /// dv_cmask: the canvas mask (values already evaluated, plan canvas px) applied to a placed layer in
    /// render px; [canvasHeight] is the render canvas height (px), [renderScale] render px per canvas px.
    func canvasMask(_ image: CIImage, _ m: CanvasMask, canvasHeight: Double, renderScale: Double) -> CIImage {
        let rs = renderScale
        let (c, s) = Self.cosSinDeg(m.r)
        let rect = CIVector(x: m.cx * rs, y: m.cy * rs, z: m.w * rs / 2, w: m.h * rs / 2)
        let p = CIVector(x: c, y: s, z: m.feather * rs, w: m.inv ? 1 : 0)
        return cmaskKernel.apply(extent: image.extent, arguments: [image, rect, p, Float(canvasHeight)]) ?? image
    }

    // MARK: Sprites and matte

    /// dv_reveal: keeps sprite texels whose glyph < [shown] (`floor(reveal(t))`); nil = not animated.
    func reveal(_ sprite: CIImage, glyphs: CIImage?, shown: Int?) -> CIImage {
        guard let shown, let glyphs else { return sprite }
        return revealKernel.apply(extent: sprite.extent, arguments: [sprite, glyphs, Float(shown)]) ?? sprite
    }

    /// dv_matte: the layer's alpha as opaque grey (chroma matte editing mode).
    func matte(_ image: CIImage) -> CIImage {
        matteKernel.apply(extent: image.extent, arguments: [image]) ?? image
    }

    // MARK: Place and composite

    /// The Core Image transform placing [imageExtent] (the processed layer, y up) on the render canvas:
    /// image px → base-local px (y down, scaled to `base`) → `M` (§11.6, canvas px, y down) → render
    /// px (× [renderScale], y up over a render canvas [canvasHeight] canvas px high).
    static func placementTransform(_ m: CGAffineTransform, base: PlanSize, imageExtent e: CGRect, canvasHeight: Double,
                                   renderScale rs: Double) -> CGAffineTransform {
        let sx = base.w / e.width
        let sy = base.h / e.height
        let toLocal = CGAffineTransform(a: sx, b: 0, c: 0, d: -sy, tx: -e.minX * sx, ty: (e.minY + e.height) * sy)
        let toRender = CGAffineTransform(a: rs, b: 0, c: 0, d: -rs, tx: 0, ty: rs * canvasHeight)
        return toLocal.concatenating(m).concatenating(toRender)
    }

    /// Places a layer: `CIImage.transformed(by:)` with [placementTransform] and `alpha *= opacity`.
    func place(_ image: CIImage, m: CGAffineTransform, base: PlanSize, opacity: Double, canvasHeight: Double,
               renderScale: Double) -> CIImage {
        let t = Self.placementTransform(m, base: base, imageExtent: image.extent, canvasHeight: canvasHeight, renderScale: renderScale)
        var out = image.transformed(by: t)
        if opacity < 1 {
            out = Self.scaleAlpha(out, max(0, opacity))
        }
        return out
    }

    /// Premultiplied `c *= k` (opacity): CIColorMatrix works on un-premultiplied colour, so scaling
    /// only its alpha scales every premultiplied channel.
    static func scaleAlpha(_ image: CIImage, _ k: Double) -> CIImage {
        image.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: k),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            ])
    }

    /// Premultiplied source-over (`CISourceOverCompositing`).
    static func composite(_ top: CIImage, over bottom: CIImage) -> CIImage {
        top.composited(over: bottom)
    }

    // MARK: Pre-warm

    /// Renders a 16×16 image through every kernel once (the first blur pipeline compile took 1–3 s in
    /// IOS-01) and returns the ms spent per kernel.
    @discardableResult
    func prewarm(context: CIContext) -> [String: Double] {
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let src = CIImage(color: CIColor(red: 0.5, green: 0.4, blue: 0.3)).cropped(to: rect)
        let lut = try? LutTexture.make(n: 2, rgb: [0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0, 0, 0, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1])
        let cases: [(String, CIImage)] = [
            ("dv_look", look(src, LookParams(chroma: PlanChroma(key: 0x00B140), adjust: [0.1, 0, 0, 0, 0, 0, 0, 0], lut: lut), forceKernel: true)),
            ("dv_blur", blur(src, sigma: 1)),
            ("dv_sharpen", sharpen(src, amount: 0.5)),
            ("dv_vignette_mask", vignetteMask(src, vignette: 0.5, aspect: 1, mask: PlanMask(shape: .ellipse), base: PlanSize(w: 16, h: 16))),
            ("dv_cmask", canvasMask(src, CanvasMask(cx: 8, cy: 8, w: 8, h: 8), canvasHeight: 16, renderScale: 1)),
            ("dv_reveal", reveal(src, glyphs: src, shown: 1)),
            ("dv_matte", matte(src)),
        ]
        var ms: [String: Double] = [:]
        var px = [UInt8](repeating: 0, count: 16 * 16 * 4)
        for (name, image) in cases {
            let t0 = CFAbsoluteTimeGetCurrent()
            context.render(image, toBitmap: &px, rowBytes: 64, bounds: rect, format: .RGBA8, colorSpace: nil)
            ms[name] = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        }
        return ms
    }
}
