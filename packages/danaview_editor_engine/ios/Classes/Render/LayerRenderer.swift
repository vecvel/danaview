// OWNER: IOS-10
//
// LayerRenderer (ARCH §11.6, §13.2 'Compositor'): builds the Core Image graph of one output frame
// from a ParamSnapshot. Used by DVCompositor for every request (playback, seek, export) and by
// RedrawCache for paused redraws and stills, so every path renders the same pixels.
//
// Per active layer, bottom → top in plan order (z, t0, id), evaluated at `timeOfFrame(k)` of the
// OUTPUT rate (D-35; ParamSnapshot.evaluate):
//
//   1. raster: the layer in base-local orientation at `round(base·|s|·renderScale)` px (each side
//      capped at 4096), exactly like the Dart reference renderer (API-03): media and images sample
//      their cropped, display-oriented source; sprites their premultiplied raster after `dv_reveal`;
//      solids are a flat colour;
//   2. media and images only: dv_look (chroma key + spill → grade → LUT) → blur (σ in raster px =
//      blur·0.03·min(W, H)·renderScale) → sharpen → vignette + item mask (D-08 order);
//   3. place: `CIImage.transformed(by:)` with the §11.6 matrix M (raster → base-local px → canvas px →
//      render px, y flipped into Core Image's y-up space), `alpha *= xf.op`, then the canvas masks;
//   4. premultiplied source-over (`CISourceOverCompositing`) onto the opaque `canvas.bg`.
//
// Editing modes (native.md §4.8): `cropSource(item)` draws only the item's uncropped, untransformed
// source fitted to the canvas with its looks applied; `matte(item)` draws only the item's alpha after
// the mask stage as opaque grey.
//
// Media layers get their source picture from the caller (the compositor's source buffers, the redraw
// cache, a still) already rotated to display orientation with its extent at the origin; LUT, sprite
// and image assets come from a `LayerAssetSource` (stores by default). Missing content skips the
// layer (never a crash); nothing here logs paths or user content.

import CoreImage
import Foundation

/// Preview editing modes (ARCH §12.2 `setEditingMode`).
enum DVEditingMode: Equatable {
    case normal
    /// The item's uncropped, untransformed source fitted to the canvas, looks applied (crop tool).
    case cropSource(item: String)
    /// The item's alpha after the mask stage as opaque grey; other items hidden (chroma "Show matte").
    case matte(item: String)

    /// The item the mode isolates, nil in `normal`.
    var item: String? {
        switch self {
        case .normal: return nil
        case .cropSource(let item), .matte(let item): return item
        }
    }

    /// The item id of a layer id (`<itemId>#v`, `#bd`, `#tx<n>`, `#c`).
    static func itemId(ofLayer id: String) -> String {
        guard let hash = id.firstIndex(of: "#") else { return id }
        return String(id[..<hash])
    }
}

/// LUT, sprite and image content of plan assets.
protocol LayerAssetSource: AnyObject {
    /// The LUT texture of a `lut` asset, nil when unavailable.
    func lut(id: String, asset: PlanAsset) -> LutTexture?
    /// The decoded sprite of a `sprite` asset, nil when unavailable.
    func sprite(id: String, asset: PlanAsset) -> SpriteImage?
    /// The display-oriented picture of an `image` asset with its long side ≤ [maxLongSide] px (0 = full
    /// size), extent at the origin, nil when unavailable.
    func image(id: String, asset: PlanAsset, maxLongSide: Int) -> CIImage?
}

/// `LayerAssetSource` over the IOS-09 stores, resolving asset URIs/bookmarks like the composition.
final class StoreAssetSource: LayerAssetSource {
    let luts: LutStore
    let sprites: SpriteStore
    let images: ImageLayerCache

    init(luts: LutStore = LutStore(), sprites: SpriteStore = SpriteStore(), images: ImageLayerCache = ImageLayerCache()) {
        self.luts = luts
        self.sprites = sprites
        self.images = images
    }

    private func url(_ asset: PlanAsset) -> URL? {
        try? MediaURLResolver.resolve(asset, useProxies: false).url
    }

    func lut(id: String, asset: PlanAsset) -> LutTexture? {
        guard let url = url(asset) else { return nil }
        return try? luts.texture(for: url)
    }

    func sprite(id: String, asset: PlanAsset) -> SpriteImage? {
        guard let url = url(asset) else { return nil }
        return try? sprites.sprite(for: url)
    }

    func image(id: String, asset: PlanAsset, maxLongSide: Int) -> CIImage? {
        guard let url = url(asset) else { return nil }
        return try? images.image(for: url, maxLongSide: maxLongSide)
    }

    /// Trims every store to [fraction] of its budget (memory warning: 0.25).
    func trim(to fraction: Double) {
        luts.trim(to: fraction)
        sprites.trim(to: fraction)
        images.trim(to: fraction)
    }
}

/// Builds the Core Image graph of one output frame (ARCH §11.6).
final class LayerRenderer {
    /// Cap of each side of a layer raster (as the reference renderer).
    static let maxRasterSide = 4096

    /// The composed frame.
    struct Output {
        /// Opaque premultiplied image with extent `(0, 0, renderSize)`.
        let image: CIImage
        /// Output frame index and its plan time `timeOfFrame(k)`.
        let k: Int64
        let tUs: Int64
        /// Layers that drew, bottom → top.
        let drawn: [String]
        /// Active layers skipped because their content was missing (media source, sprite, image).
        let missing: [String]
    }

    /// A media layer's display-oriented source picture (extent at the origin), nil when unavailable.
    typealias MediaSource = (EvaluatedLayer) -> CIImage?

    let kernels: Kernels
    let assets: LayerAssetSource

    init(kernels: Kernels, assets: LayerAssetSource) {
        self.kernels = kernels
        self.assets = assets
    }

    // MARK: Frame

    /// Composes output frame [k] of [snapshot] at [renderSize] in [mode].
    func compose(snapshot: ParamSnapshot, frame k: Int64, renderSize: CGSize, mode: DVEditingMode = .normal,
                 media: MediaSource) -> Output {
        let plan = snapshot.plan
        let canvas = plan.canvas
        let w = max(1, renderSize.width.rounded())
        let h = max(1, renderSize.height.rounded())
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let geo = Geometry(canvasW: Double(canvas.w), canvasH: Double(canvas.h), renderW: Double(w), renderH: Double(h))
        let t = snapshot.timeOfFrame(k)

        var out = Self.opaque(argb: canvas.bg, rect: rect)
        var drawn: [String] = []
        var missing: [String] = []
        let layers = snapshot.evaluate(atFrame: k)
        let target = mode.item.flatMap { Self.targetLayer(item: $0, in: layers) }
        for layer in layers {
            if mode != .normal && layer.id != target { continue }
            let base = Self.effectiveBase(layer, plan: plan, own: snapshot.layer(layer.id)?.base)
            let result: LayerResult
            switch mode {
            case .normal: result = renderLayer(layer, base: base, plan: plan, geo: geo, media: media)
            case .cropSource: result = renderCropSource(layer, base: base, plan: plan, geo: geo, media: media)
            case .matte: result = renderLayer(layer, base: base, plan: plan, geo: geo, media: media, matte: true)
            }
            switch result {
            case .drawn(let image):
                out = image.composited(over: out)
                drawn.append(layer.id)
            case .missing: missing.append(layer.id)
            case .invisible: break
            }
        }
        return Output(image: out.cropped(to: rect), k: k, tUs: t, drawn: drawn, missing: missing)
    }

    /// The layer an editing mode isolates: `<item>#v` when active, else the first active layer of the item.
    static func targetLayer(item: String, in layers: [EvaluatedLayer]) -> String? {
        if let v = layers.first(where: { $0.id == item + "#v" }) { return v.id }
        return layers.first { DVEditingMode.itemId(ofLayer: $0.id) == item }?.id
    }

    // MARK: Layers

    enum LayerResult {
        case drawn(CIImage)
        case missing
        case invisible
    }

    /// Canvas and render sizes; `kx`, `ky` render px per canvas px.
    struct Geometry {
        let canvasW: Double
        let canvasH: Double
        let renderW: Double
        let renderH: Double
        var kx: Double { renderW / canvasW }
        var ky: Double { renderH / canvasH }

        /// Raster side for a base-local length [px] canvas px drawn at render scale [k].
        static func rasterSide(_ px: Double) -> Int {
            guard px.isFinite else { return LayerRenderer.maxRasterSide }
            return max(1, min(LayerRenderer.maxRasterSide, Int(px.rounded())))
        }
    }

    /// The layer's `base` ([own]: the plan's, transients merged), defaulting to `sw/sscale × sh/sscale`
    /// for sprites and to the canvas otherwise.
    static func effectiveBase(_ layer: EvaluatedLayer, plan: RenderPlan, own: PlanSize?) -> PlanSize {
        if let own { return own }
        if layer.kind == .sprite, let id = layer.asset, let a = plan.assets[id], let sw = a.sw, let sh = a.sh,
           let ss = a.sscale, ss > 0 {
            return PlanSize(w: Double(sw) / ss, h: Double(sh) / ss)
        }
        return layer.base
    }

    private func renderLayer(_ layer: EvaluatedLayer, base: PlanSize, plan: RenderPlan, geo: Geometry, media: MediaSource,
                             matte: Bool = false) -> LayerResult {
        guard layer.opacity > 0 || matte else { return .invisible }
        let s = abs(layer.scale)
        guard s > 0, base.w > 0, base.h > 0, base.w.isFinite, base.h.isFinite else { return .invisible }
        let rw = Geometry.rasterSide(base.w * s * geo.kx)
        let rh = Geometry.rasterSide(base.h * s * geo.ky)

        var raster: CIImage
        switch layer.kind {
        case .solid:
            raster = ImageLayerCache.solid(argb: layer.color ?? 0xFF00_0000, width: Double(rw), height: Double(rh))
        case .sprite:
            guard let id = layer.asset, let asset = plan.assets[id], let sprite = assets.sprite(id: id, asset: asset) else {
                return .missing
            }
            raster = Self.resample(spriteImage(sprite, asset: asset, shown: layer.reveal), width: rw, height: rh)
        case .media, .image:
            guard let source = picture(layer, plan: plan, rasterW: rw, rasterH: rh, media: media) else { return .missing }
            let crop = Kernels.cropRect(layer.crop, in: source.extent)
            guard crop.width > 0, crop.height > 0 else { return .invisible }
            raster = Self.resample(source.cropped(to: crop), width: rw, height: rh)
            raster = effects(raster, layer: layer, plan: plan, base: base, geo: geo)
        }
        if matte {
            raster = kernels.matte(raster)
            return .drawn(place(raster, layer: layer, base: base, opacity: 1, cmasks: [], geo: geo))
        }
        return .drawn(place(raster, layer: layer, base: base, opacity: layer.opacity, cmasks: layer.cmasks, geo: geo))
    }

    /// cropSource: the item's whole source, fitted to the canvas, looks applied, no transform or masks.
    private func renderCropSource(_ layer: EvaluatedLayer, base own: PlanSize, plan: RenderPlan, geo: Geometry,
                                  media: MediaSource) -> LayerResult {
        guard layer.kind == .media || layer.kind == .image else {
            return renderLayer(layer, base: own, plan: plan, geo: geo, media: media)
        }
        let longSide = Geometry.rasterSide(max(geo.renderW, geo.renderH))
        guard let source = picture(layer, plan: plan, rasterW: longSide, rasterH: longSide, media: media),
              source.extent.width > 0, source.extent.height > 0 else { return .missing }
        let fit = min(geo.canvasW / source.extent.width, geo.canvasH / source.extent.height)
        let base = PlanSize(w: source.extent.width * fit, h: source.extent.height * fit)
        let fitted = EvaluatedLayer(
            id: layer.id, kind: layer.kind, asset: layer.asset, seq: layer.seq, sourceUs: layer.sourceUs, color: layer.color,
            base: base, crop: .full, cx: geo.canvasW / 2, cy: geo.canvasH / 2, scale: 1, rotation: 0, flipX: false,
            flipY: false, opacity: 1, adjust: layer.adjust, detail: layer.detail, lut: layer.lut, chroma: layer.chroma,
            mask: nil, cmasks: [], reveal: nil)
        let rw = Geometry.rasterSide(base.w * geo.kx)
        let rh = Geometry.rasterSide(base.h * geo.ky)
        var raster = Self.resample(source, width: rw, height: rh)
        raster = effects(raster, layer: fitted, plan: plan, base: base, geo: geo)
        return .drawn(place(raster, layer: fitted, base: base, opacity: 1, cmasks: [], geo: geo))
    }

    /// The source picture of a media or image layer (display-oriented, extent at the origin).
    private func picture(_ layer: EvaluatedLayer, plan: RenderPlan, rasterW: Int, rasterH: Int, media: MediaSource) -> CIImage? {
        let image: CIImage?
        if layer.kind == .media {
            image = media(layer)
        } else {
            guard let id = layer.asset, let asset = plan.assets[id] else { return nil }
            // Decode at the size it is drawn at (cropped share of the source), bucketed so animated
            // scales do not thrash the cache.
            let cw = max(0.01, layer.crop.r - layer.crop.l)
            let ch = max(0.01, layer.crop.b - layer.crop.t)
            let need = max(Double(rasterW) / cw, Double(rasterH) / ch)
            image = assets.image(id: id, asset: asset, maxLongSide: Self.decodeBucket(need))
        }
        guard let image, !image.extent.isEmpty, !image.extent.isInfinite else { return nil }
        let e = image.extent
        if e.minX == 0 && e.minY == 0 { return image }
        return image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }

    /// Decode long side for a needed size: the next power of two ≥ 256 (0 = full size above 8192).
    static func decodeBucket(_ need: Double) -> Int {
        guard need.isFinite, need > 0 else { return 0 }
        var side = 256
        while Double(side) < need {
            side *= 2
            if side > 8192 { return 0 }
        }
        return side
    }

    private static let spriteLock = NSLock()

    /// The sprite's premultiplied picture with `dv_reveal` applied when its asset has a reveal map.
    private func spriteImage(_ sprite: SpriteImage, asset: PlanAsset, shown: Int?) -> CIImage {
        // SpriteImage builds its CIImages lazily; the compositor and redraws may race on first use.
        Self.spriteLock.lock()
        let image = sprite.image
        let glyphs = (asset.reveal == true && shown != nil) ? sprite.glyphImage : nil
        Self.spriteLock.unlock()
        guard let glyphs, let shown else { return image }
        return kernels.reveal(image, glyphs: glyphs, shown: shown)
    }

    /// Look → blur → sharpen → vignette + mask on a layer raster (extent at the origin).
    private func effects(_ raster: CIImage, layer: EvaluatedLayer, plan: RenderPlan, base: PlanSize, geo: Geometry) -> CIImage {
        var img = raster
        var lut: LutTexture?
        var lutIntensity = 0.0
        if let ref = layer.lut, ref.i != 0, let a = plan.assets[ref.asset] {
            lut = assets.lut(id: ref.asset, asset: a)
            lutIntensity = ref.i
        }
        let look = Kernels.LookParams(crop: nil, chroma: layer.chroma, adjust: layer.adjust, lut: lut, lutIntensity: lutIntensity)
        if !look.isIdentityLook { img = kernels.look(img, look) }
        let d = layer.detail
        if d.blur > 0 {
            let sigma = Kernels.blurSigmaRenderPx(
                sigmaCanvasPx: Kernels.blurSigmaCanvasPx(blur: d.blur, canvasW: plan.canvas.w, canvasH: plan.canvas.h),
                renderScale: geo.kx)
            img = kernels.blur(img, sigma: sigma)
        }
        if d.sharpen > 0 { img = kernels.sharpen(img, amount: d.sharpen) }
        if d.vignette > 0 || layer.mask != nil {
            img = kernels.vignetteMask(img, vignette: d.vignette, aspect: base.w / base.h, mask: layer.mask, base: base)
        }
        return img
    }

    /// Places a raster (covering `base` in base-local orientation) on the render canvas.
    private func place(_ raster: CIImage, layer: EvaluatedLayer, base: PlanSize, opacity: Double, cmasks: [CanvasMask],
                       geo: Geometry) -> CIImage {
        let t = Self.placementTransform(layer.placement, base: base, rasterExtent: raster.extent, geo: geo)
        var out = raster.transformed(by: t)
        if opacity < 1 { out = Kernels.scaleAlpha(out, max(0, opacity)) }
        for m in cmasks {
            out = kernels.canvasMask(out, m, canvasHeight: geo.renderH, renderScale: geo.kx)
        }
        return out
    }

    // MARK: Helpers

    /// raster px (y up) → base-local px (y down) → M (canvas px, y down) → render px (y up).
    static func placementTransform(_ m: CGAffineTransform, base: PlanSize, rasterExtent e: CGRect, geo: Geometry) -> CGAffineTransform {
        let sx = base.w / e.width
        let sy = base.h / e.height
        let toLocal = CGAffineTransform(a: sx, b: 0, c: 0, d: -sy, tx: -e.minX * sx, ty: e.maxY * sy)
        let toRender = CGAffineTransform(a: geo.kx, b: 0, c: 0, d: -geo.ky, tx: 0, ty: geo.renderH)
        return toLocal.concatenating(m).concatenating(toRender)
    }

    /// [image] (extent at any origin) resampled to `(0, 0, width, height)`: Lanczos for large
    /// minification, then bilinear with clamped edges (no transparent fringe inside the raster).
    static func resample(_ image: CIImage, width: Int, height: Int) -> CIImage {
        let e = image.extent
        var src = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        var sx = Double(width) / e.width
        var sy = Double(height) / e.height
        if sx == 1 && sy == 1 && e.minX.rounded() == e.minX && e.minY.rounded() == e.minY { return src }
        if sx < 0.5 && sy < 0.5 {
            // Bring the source to about twice the target first (antialiased), then bilinear.
            let scale = min(1, sy * 2)
            let aspect = (sx * 2) / scale
            src = src.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: aspect])
            let e2 = src.extent
            src = src.cropped(to: e2.integral.intersection(e2))
            src = src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY))
            sx = Double(width) / src.extent.width
            sy = Double(height) / src.extent.height
        }
        return src.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// An opaque colour (plan ARGB, alpha ignored) covering [rect].
    static func opaque(argb: UInt32, rect: CGRect) -> CIImage {
        ImageLayerCache.solid(argb: argb | 0xFF00_0000, width: rect.width, height: rect.height)
    }
}
