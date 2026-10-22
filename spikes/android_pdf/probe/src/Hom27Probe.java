// HOM-27 spike probe: Android PDF write path, route (a) platform APIs only.
//
// Runs on a device or emulator through app_process (no APK, no Gradle, no
// third-party code):
//   adb shell CLASSPATH=/data/local/tmp/hom27/probe.dex app_process /system/bin Hom27Probe <cmd> <in> <out>
// Commands: caps | run <fixtures dir> <out dir> | verify <dir> <out dir>
// Every result is one line "HOM27 {json}" on stdout.

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Matrix;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.pdf.PdfDocument;
import android.graphics.pdf.PdfRenderer;
import android.os.Build;
import android.os.ParcelFileDescriptor;
import android.os.ext.SdkExtensions;

import java.io.File;
import java.io.FileOutputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public final class Hom27Probe {
    static final Pattern TOKEN = Pattern.compile("HOM27[TMA]-P\\d{4}");

    public static void main(String[] args) throws Exception {
        String cmd = args.length > 0 ? args[0] : "caps";
        caps();
        if (cmd.equals("run")) {
            run(new File(args[1]), new File(args[2]));
        } else if (cmd.equals("png")) {
            // Visual evidence: the first three pages of every PDF in <in> as PNG at 60 dpi.
            File[] files = new File(args[1]).listFiles();
            File out = new File(args[2]);
            out.mkdirs();
            Arrays.sort(files);
            for (File f : files) {
                if (!f.getName().endsWith(".pdf")) continue;
                PdfRenderer r = new PdfRenderer(ro(f));
                for (int i = 0; i < Math.min(3, r.getPageCount()); i++) {
                    PdfRenderer.Page p = r.openPage(i);
                    Bitmap b = Bitmap.createBitmap(p.getWidth() * 60 / 72, p.getHeight() * 60 / 72, Bitmap.Config.ARGB_8888);
                    b.eraseColor(Color.WHITE);
                    p.render(b, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY);
                    p.close();
                    FileOutputStream fos = new FileOutputStream(new File(out, f.getName().replace(".pdf", "") + "_p" + (i + 1) + ".png"));
                    b.compress(Bitmap.CompressFormat.PNG, 100, fos);
                    fos.close();
                    b.recycle();
                }
                r.close();
            }
        } else if (cmd.equals("verify")) {
            verifyDir(new File(args[1]), new File(args[2]));
        }
    }

    // ---------------------------------------------------------------- output

    static void emit(String json) {
        System.out.println("HOM27 " + json);
        System.out.flush();
    }

    static String q(String s) {
        return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\"";
    }

    static String ms(long t0) {
        return String.format(Locale.US, "%.1f", (System.nanoTime() - t0) / 1e6);
    }

    // ---------------------------------------------------------------- caps

    static int extS() {
        if (Build.VERSION.SDK_INT < 30) return -1;
        return Caps30.extS();
    }

    /** PdfRenderer text + write(): API 35+. PdfRendererPreV: API 31-34 with S-ext 13. */
    static boolean hasTextApi() {
        return Build.VERSION.SDK_INT >= 35 || (Build.VERSION.SDK_INT >= 31 && extS() >= 13);
    }

    /** Page objects and annotations (android.graphics.pdf.component): 36.1, or S-ext 18. */
    static boolean hasEditApi() {
        // Every 36.1 device reports S-ext >= 18, so the extension level alone decides.
        return extS() >= 18;
    }

    static void caps() {
        emit("{\"kind\":\"caps\",\"sdk\":" + Build.VERSION.SDK_INT
                + ",\"release\":" + q(Build.VERSION.RELEASE)
                + ",\"fingerprint\":" + q(Build.FINGERPRINT)
                + ",\"abi\":" + q(Build.SUPPORTED_ABIS[0])
                + ",\"ext_s\":" + extS()
                + ",\"text_api\":" + hasTextApi()
                + ",\"write_api\":" + hasTextApi()
                + ",\"edit_api\":" + hasEditApi() + "}");
    }

    // ---------------------------------------------------------------- run

    static void run(File in, File out) throws Exception {
        out.mkdirs();
        File text200 = new File(in, "text_200p.pdf");
        File partner = new File(in, "merge_partner_3p.pdf");
        File images = new File(in, "image_only_2p.pdf");
        File annotated = new File(in, "annotated_2p.pdf");

        // Baseline: what the platform can read back from the untouched fixtures.
        for (File f : new File[] {text200, partner, images, annotated}) verify(f, "baseline");

        // Route (a) everywhere: page operations by rasterising into android.graphics.pdf.PdfDocument
        // (the only platform writer that can create pages, API 19+).
        raster("merge", new File(out, "raster_merge.pdf"), 144,
                new Src(text200, range(0, 200), 0), new Src(partner, range(0, 3), 0));
        raster("split", new File(out, "raster_split_1-100.pdf"), 144, new Src(text200, range(0, 100), 0));
        raster("reorder", new File(out, "raster_reorder.pdf"), 144, new Src(partner, new int[] {2, 0, 1}, 0));
        raster("rotate", new File(out, "raster_rotate.pdf"), 144, new Src(partner, new int[] {0}, 90),
                new Src(partner, new int[] {1, 2}, 0));
        raster("delete", new File(out, "raster_delete.pdf"), 144, new Src(partner, new int[] {0, 2}, 0));
        raster("annotate_burn", new File(out, "raster_annotated.pdf"), 144, new Src(annotated, range(0, 2), 0));
        raster("compress_72dpi", new File(out, "raster_compress_72.pdf"), 72, new Src(images, range(0, 2), 0));
        raster("compress_50dpi", new File(out, "raster_compress_50.pdf"), 50, new Src(images, range(0, 2), 0));

        if (hasTextApi()) {
            for (File f : new File[] {text200, annotated}) {
                File o = new File(out, "write_roundtrip_" + f.getName());
                long t0 = System.nanoTime();
                Api35.roundTrip(f, o);
                emit("{\"kind\":\"op\",\"route\":\"a-write\",\"op\":\"roundtrip\",\"in\":" + q(f.getName())
                        + ",\"ms\":" + ms(t0) + ",\"bytes\":" + o.length() + "}");
                verify(o, "write_roundtrip");
            }
        }
        if (hasEditApi()) {
            Api361.annotate(annotated, new File(out, "edit_annotate_annotated_2p.pdf"));
            Api361.annotate(text200, new File(out, "edit_annotate_text_200p.pdf"));
            Api361.stampAll(text200, new File(out, "edit_stamp_all_200p.pdf"));
            Api361.compress(images, new File(out, "edit_compress_50.pdf"), 0.5f);
            Api361.compress(images, new File(out, "edit_compress_25.pdf"), 0.25f);
            Api361.rebuild("merge", new File(out, "edit_rebuild_merge.pdf"),
                    new Src(text200, range(0, 200), 0), new Src(partner, range(0, 3), 0));
            Api361.rebuild("split", new File(out, "edit_rebuild_split_1-100.pdf"), new Src(text200, range(0, 100), 0));
            Api361.rebuild("reorder", new File(out, "edit_rebuild_reorder.pdf"), new Src(partner, new int[] {2, 0, 1}, 0));
            Api361.rebuild("rotate", new File(out, "edit_rebuild_rotate.pdf"), new Src(partner, new int[] {0}, 90),
                    new Src(partner, new int[] {1, 2}, 0));
            Api361.rebuild("delete", new File(out, "edit_rebuild_delete.pdf"), new Src(partner, new int[] {0, 2}, 0));
            Api361.rebuild("annotated_copy", new File(out, "edit_rebuild_annotated.pdf"), new Src(annotated, range(0, 2), 0));
            Api361.rebuild("images_copy", new File(out, "edit_rebuild_images.pdf"), new Src(images, range(0, 2), 0));
        }
        emit("{\"kind\":\"done\"}");
    }

    static int[] range(int from, int to) {
        int[] r = new int[to - from];
        for (int i = 0; i < r.length; i++) r[i] = from + i;
        return r;
    }

    static final class Src {
        final File file;
        final int[] pages;
        final int rotate;

        Src(File file, int[] pages, int rotate) {
            this.file = file;
            this.pages = pages;
            this.rotate = rotate;
        }
    }

    static ParcelFileDescriptor ro(File f) throws Exception {
        return ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY);
    }

    // ---------------------------------------------------------------- raster fallback (any API)

    static void raster(String op, File outFile, int dpi, Src... srcs) throws Exception {
        long t0 = System.nanoTime();
        PdfDocument doc = new PdfDocument();
        int pageNo = 0;
        long peakBitmap = 0;
        for (Src s : srcs) {
            PdfRenderer r = new PdfRenderer(ro(s.file));
            for (int idx : s.pages) {
                PdfRenderer.Page p = r.openPage(idx);
                int wPt = p.getWidth(), hPt = p.getHeight();
                int wPx = Math.max(1, wPt * dpi / 72), hPx = Math.max(1, hPt * dpi / 72);
                Bitmap bmp = Bitmap.createBitmap(wPx, hPx, Bitmap.Config.ARGB_8888);
                bmp.eraseColor(Color.WHITE);
                p.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_PRINT);
                p.close();
                peakBitmap = Math.max(peakBitmap, bmp.getByteCount());
                boolean swap = s.rotate == 90 || s.rotate == 270;
                PdfDocument.PageInfo info = new PdfDocument.PageInfo.Builder(swap ? hPt : wPt, swap ? wPt : hPt, ++pageNo).create();
                PdfDocument.Page page = doc.startPage(info);
                Canvas c = page.getCanvas();
                Matrix m = new Matrix();
                m.postScale(72f / dpi, 72f / dpi);
                if (s.rotate == 90) {
                    m.postRotate(90);
                    m.postTranslate(hPt, 0);
                }
                c.drawBitmap(bmp, m, null);
                doc.finishPage(page);
                bmp.recycle();
            }
            r.close();
        }
        FileOutputStream fos = new FileOutputStream(outFile);
        doc.writeTo(fos);
        fos.close();
        doc.close();
        emit("{\"kind\":\"op\",\"route\":\"a-raster\",\"op\":" + q(op) + ",\"dpi\":" + dpi + ",\"pages\":" + pageNo
                + ",\"ms\":" + ms(t0) + ",\"bytes\":" + outFile.length() + ",\"peak_bitmap_bytes\":" + peakBitmap + "}");
        verify(outFile, "raster_" + op);
    }

    // ---------------------------------------------------------------- verify

    static void verifyDir(File dir, File unused) throws Exception {
        File[] files = dir.listFiles();
        if (files == null) return;
        Arrays.sort(files);
        for (File f : files) if (f.getName().endsWith(".pdf")) verify(f, "verify");
    }

    /** Page count, rotation-less size of page 1, and (when the platform can) the tokens found. */
    static void verify(File f, String tag) throws Exception {
        long t0 = System.nanoTime();
        PdfRenderer r = new PdfRenderer(ro(f));
        int n = r.getPageCount();
        PdfRenderer.Page p0 = r.openPage(0);
        String size = p0.getWidth() + "x" + p0.getHeight();
        p0.close();
        r.close();
        StringBuilder sb = new StringBuilder();
        sb.append("{\"kind\":\"verify\",\"tag\":").append(q(tag)).append(",\"file\":").append(q(f.getName()))
                .append(",\"bytes\":").append(f.length()).append(",\"pages\":").append(n)
                .append(",\"page1_pt\":").append(q(size));
        if (hasTextApi()) {
            String[] perPage = Build.VERSION.SDK_INT >= 35 ? Api35.pageTexts(f) : Api31.pageTexts(f);
            TreeSet<String> all = new TreeSet<>();
            int pagesWithToken = 0;
            StringBuilder order = new StringBuilder();
            for (int i = 0; i < perPage.length; i++) {
                Matcher m = TOKEN.matcher(perPage[i]);
                boolean any = false;
                while (m.find()) {
                    all.add(m.group());
                    if (!any && i < 6) order.append(order.length() > 0 ? "," : "").append(m.group());
                    any = true;
                }
                if (any) pagesWithToken++;
            }
            sb.append(",\"tokens\":").append(all.size()).append(",\"pages_with_token\":").append(pagesWithToken)
                    .append(",\"first_tokens\":").append(q(order.toString()));
            if (hasEditApi()) sb.append(",\"annotations\":").append(q(Api361.annotationSummary(f)));
        }
        sb.append(",\"verify_ms\":").append(ms(t0)).append("}");
        emit(sb.toString());
    }

    // ---------------------------------------------------------------- API 30+

    static final class Caps30 {
        static int extS() {
            return SdkExtensions.getExtensionVersion(Build.VERSION_CODES.S);
        }
    }

    // ---------------------------------------------------------------- API 31-34, S-ext 13

    static final class Api31 {
        static String[] pageTexts(File f) throws Exception {
            android.graphics.pdf.PdfRendererPreV r = new android.graphics.pdf.PdfRendererPreV(ro(f));
            String[] out = new String[r.getPageCount()];
            for (int i = 0; i < out.length; i++) {
                android.graphics.pdf.PdfRendererPreV.Page p = r.openPage(i);
                StringBuilder sb = new StringBuilder();
                for (android.graphics.pdf.content.PdfPageTextContent t : p.getTextContents()) sb.append(t.getText()).append('\n');
                out[i] = sb.toString();
                p.close();
            }
            r.close();
            return out;
        }
    }

    // ---------------------------------------------------------------- API 35+

    static final class Api35 {
        static String[] pageTexts(File f) throws Exception {
            PdfRenderer r = new PdfRenderer(ro(f));
            String[] out = new String[r.getPageCount()];
            for (int i = 0; i < out.length; i++) {
                PdfRenderer.Page p = r.openPage(i);
                StringBuilder sb = new StringBuilder();
                for (android.graphics.pdf.content.PdfPageTextContent t : p.getTextContents()) sb.append(t.getText()).append('\n');
                out[i] = sb.toString();
                p.close();
            }
            r.close();
            return out;
        }

        static void roundTrip(File in, File out) throws Exception {
            PdfRenderer r = new PdfRenderer(ro(in));
            ParcelFileDescriptor w = ParcelFileDescriptor.open(out,
                    ParcelFileDescriptor.MODE_CREATE | ParcelFileDescriptor.MODE_TRUNCATE | ParcelFileDescriptor.MODE_READ_WRITE);
            r.write(w, false);
            w.close();
            r.close();
        }
    }

    // ---------------------------------------------------------------- 36.1 / S-ext 18: page objects + annotations

    static final class Api361 {
        static ParcelFileDescriptor rw(File out) throws Exception {
            return ParcelFileDescriptor.open(out,
                    ParcelFileDescriptor.MODE_CREATE | ParcelFileDescriptor.MODE_TRUNCATE | ParcelFileDescriptor.MODE_READ_WRITE);
        }

        static String annotationSummary(File f) throws Exception {
            PdfRenderer r = new PdfRenderer(ro(f));
            StringBuilder sb = new StringBuilder();
            int n = Math.min(r.getPageCount(), 3);
            for (int i = 0; i < n; i++) {
                PdfRenderer.Page p = r.openPage(i);
                List<android.util.Pair<Integer, android.graphics.pdf.component.PdfAnnotation>> a;
                try {
                    a = p.getPageAnnotations();
                } catch (Throwable t) {
                    sb.append(sb.length() > 0 ? " | " : "").append("p").append(i + 1).append(": getPageAnnotations threw ")
                            .append(t.getClass().getSimpleName()).append(" (").append(t.getMessage()).append(")");
                    p.close();
                    continue;
                }
                int[] counts = new int[4];
                for (android.util.Pair<Integer, android.graphics.pdf.component.PdfAnnotation> e : a) {
                    int t = e.second.getPdfAnnotationType();
                    if (t == android.graphics.pdf.component.PdfAnnotationType.HIGHLIGHT) counts[0]++;
                    else if (t == android.graphics.pdf.component.PdfAnnotationType.FREETEXT) counts[1]++;
                    else if (t == android.graphics.pdf.component.PdfAnnotationType.STAMP) counts[2]++;
                    else counts[3]++;
                }
                int objs = p.getPageObjects().size();
                sb.append(sb.length() > 0 ? " | " : "").append("p").append(i + 1).append(": hl=").append(counts[0])
                        .append(" ft=").append(counts[1]).append(" st=").append(counts[2]).append(" other=").append(counts[3])
                        .append(" objs=").append(objs);
                p.close();
            }
            r.close();
            return sb.toString();
        }

        static android.graphics.pdf.component.StampAnnotation signatureStamp(float x, float y) {
            RectF box = new RectF(x, y, x + 180, y + 60);
            android.graphics.pdf.component.StampAnnotation st = new android.graphics.pdf.component.StampAnnotation(box);
            Path ink = new Path();
            ink.moveTo(x + 10, y + 40);
            ink.cubicTo(x + 40, y + 5, x + 70, y + 55, x + 100, y + 20);
            ink.cubicTo(x + 120, y + 5, x + 150, y + 50, x + 170, y + 30);
            android.graphics.pdf.component.PdfPagePathObject path = new android.graphics.pdf.component.PdfPagePathObject(ink);
            path.setRenderMode(android.graphics.pdf.component.PdfPagePathObject.RENDER_MODE_STROKE);
            path.setStrokeColor(Color.BLUE);
            path.setStrokeWidth(2f);
            st.addObject(path);
            return st;
        }

        /** Highlight, FreeText, Stamp annotations and a burned-in ink path + image (signature) on page 1. */
        static void annotate(File in, File out) throws Exception {
            long t0 = System.nanoTime();
            PdfRenderer r = new PdfRenderer(ro(in));
            PdfRenderer.Page p = r.openPage(0);
            StringBuilder ids = new StringBuilder();
            android.graphics.pdf.component.HighlightAnnotation hl =
                    new android.graphics.pdf.component.HighlightAnnotation(Arrays.asList(new RectF(60, 60, 260, 80)));
            hl.setColor(Color.YELLOW);
            ids.append("hl=").append(p.addPageAnnotation(hl));
            android.graphics.pdf.component.FreeTextAnnotation ft =
                    new android.graphics.pdf.component.FreeTextAnnotation(new RectF(300, 100, 520, 140), "HOM-27 note");
            ft.setTextColor(Color.RED);
            ids.append(" ft=").append(p.addPageAnnotation(ft));
            ids.append(" st=").append(p.addPageAnnotation(signatureStamp(320, 600)));
            // Burned-in signature: an ink path and a small image as page content.
            Path ink = new Path();
            ink.moveTo(80, 700);
            ink.lineTo(200, 740);
            ink.lineTo(260, 690);
            android.graphics.pdf.component.PdfPagePathObject po = new android.graphics.pdf.component.PdfPagePathObject(ink);
            po.setRenderMode(android.graphics.pdf.component.PdfPagePathObject.RENDER_MODE_STROKE);
            po.setStrokeColor(Color.BLACK);
            po.setStrokeWidth(3f);
            ids.append(" path=").append(p.addPageObject(po));
            Bitmap sig = Bitmap.createBitmap(120, 40, Bitmap.Config.ARGB_8888);
            sig.eraseColor(Color.argb(255, 30, 60, 200));
            android.graphics.pdf.component.PdfPageImageObject io = new android.graphics.pdf.component.PdfPageImageObject(sig);
            Matrix m = new Matrix();
            m.setScale(120, 40);
            m.postTranslate(80, 760);
            io.setMatrix(m);
            ids.append(" img=").append(p.addPageObject(io));
            p.close();
            ParcelFileDescriptor w = rw(out);
            r.write(w, false);
            w.close();
            r.close();
            emit("{\"kind\":\"op\",\"route\":\"a-edit\",\"op\":\"annotate\",\"in\":" + q(in.getName()) + ",\"ids\":" + q(ids.toString())
                    + ",\"ms\":" + ms(t0) + ",\"bytes\":" + out.length() + "}");
            verify(out, "edit_annotate");
        }

        /** A signature stamp on every page (worst case for "sign") then write. */
        static void stampAll(File in, File out) throws Exception {
            long t0 = System.nanoTime();
            PdfRenderer r = new PdfRenderer(ro(in));
            for (int i = 0; i < r.getPageCount(); i++) {
                PdfRenderer.Page p = r.openPage(i);
                p.addPageAnnotation(signatureStamp(320, 600));
                p.close();
            }
            ParcelFileDescriptor w = rw(out);
            r.write(w, false);
            w.close();
            r.close();
            emit("{\"kind\":\"op\",\"route\":\"a-edit\",\"op\":\"stamp_every_page\",\"in\":" + q(in.getName())
                    + ",\"ms\":" + ms(t0) + ",\"bytes\":" + out.length() + "}");
            verify(out, "edit_stamp_all");
        }

        /** Downscale every image object in place (compress) and write. */
        static void compress(File in, File out, float scale) throws Exception {
            long t0 = System.nanoTime();
            PdfRenderer r = new PdfRenderer(ro(in));
            int replaced = 0;
            StringBuilder err = new StringBuilder();
            for (int i = 0; i < r.getPageCount(); i++) {
                PdfRenderer.Page p = r.openPage(i);
                for (android.util.Pair<Integer, android.graphics.pdf.component.PdfPageObject> e : p.getPageObjects()) {
                    if (e.second instanceof android.graphics.pdf.component.PdfPageImageObject) {
                        android.graphics.pdf.component.PdfPageImageObject img = (android.graphics.pdf.component.PdfPageImageObject) e.second;
                        Bitmap b = img.getBitmap();
                        Bitmap s = Bitmap.createScaledBitmap(b, Math.max(1, (int) (b.getWidth() * scale)),
                                Math.max(1, (int) (b.getHeight() * scale)), true);
                        img.setBitmap(s);
                        try {
                            if (p.updatePageObject(e.first, img)) replaced++;
                        } catch (Throwable t) {
                            err.append(t.getClass().getSimpleName()).append(": ").append(t.getMessage()).append("; ");
                        }
                    }
                }
                p.close();
            }
            ParcelFileDescriptor w = rw(out);
            r.write(w, false);
            w.close();
            r.close();
            emit("{\"kind\":\"op\",\"route\":\"a-edit\",\"op\":\"compress\",\"scale\":" + scale + ",\"replaced\":" + replaced
                    + ",\"err\":" + q(err.toString()) + ",\"ms\":" + ms(t0) + ",\"bytes\":" + out.length() + "}");
            verify(out, "edit_compress");
        }

        /**
         * Page operations without rasterising: make a blank document with the target page sizes
         * (android.graphics.pdf.PdfDocument), then copy every page object of the source pages onto it
         * with addPageObject and write. Only text, image and path objects are exposed by the API.
         */
        static void rebuild(String op, File out, Src... srcs) throws Exception {
            long t0 = System.nanoTime();
            // 1. Blank pages with the target sizes.
            List<int[]> sizes = new ArrayList<>();
            for (Src s : srcs) {
                PdfRenderer r = new PdfRenderer(ro(s.file));
                for (int idx : s.pages) {
                    PdfRenderer.Page p = r.openPage(idx);
                    boolean swap = s.rotate == 90 || s.rotate == 270;
                    sizes.add(swap ? new int[] {p.getHeight(), p.getWidth()} : new int[] {p.getWidth(), p.getHeight()});
                    p.close();
                }
                r.close();
            }
            File blank = new File(out.getParentFile(), "blank_" + out.getName());
            PdfDocument doc = new PdfDocument();
            for (int i = 0; i < sizes.size(); i++) {
                PdfDocument.Page page = doc.startPage(new PdfDocument.PageInfo.Builder(sizes.get(i)[0], sizes.get(i)[1], i + 1).create());
                doc.finishPage(page);
            }
            FileOutputStream fos = new FileOutputStream(blank);
            doc.writeTo(fos);
            fos.close();
            doc.close();
            // 2. Copy objects.
            PdfRenderer dst = new PdfRenderer(ro(blank));
            int di = 0, copied = 0, failed = 0, annSeen = 0, annCopied = 0, annFailedPages = 0;
            int[] typeCounts = new int[8];
            StringBuilder err = new StringBuilder();
            for (Src s : srcs) {
                PdfRenderer src = new PdfRenderer(ro(s.file));
                for (int idx : s.pages) {
                    PdfRenderer.Page sp = src.openPage(idx);
                    PdfRenderer.Page dp = dst.openPage(di);
                    int hPt = sp.getHeight();
                    for (android.util.Pair<Integer, android.graphics.pdf.component.PdfPageObject> e : sp.getPageObjects()) {
                        android.graphics.pdf.component.PdfPageObject o = e.second;
                        int t = o.getPdfObjectType();
                        if (t >= 0 && t < typeCounts.length) typeCounts[t]++;
                        if (s.rotate == 90) {
                            // Page space: rotate 90 deg clockwise into the swapped page.
                            o.transform(0, -1, 1, 0, 0, sp.getWidth());
                        }
                        try {
                            dp.addPageObject(o);
                            copied++;
                        } catch (Throwable th) {
                            failed++;
                            if (err.length() < 300) err.append(th.getClass().getSimpleName()).append(": ").append(th.getMessage()).append("; ");
                        }
                    }
                    List<android.util.Pair<Integer, android.graphics.pdf.component.PdfAnnotation>> anns;
                    try {
                        anns = sp.getPageAnnotations();
                    } catch (Throwable th) {
                        anns = new ArrayList<>();
                        annFailedPages++;
                        if (err.length() < 300) err.append("getPageAnnotations p").append(idx + 1).append(" ").append(th.getClass().getSimpleName()).append(": ").append(th.getMessage()).append("; ");
                    }
                    for (android.util.Pair<Integer, android.graphics.pdf.component.PdfAnnotation> e : anns) {
                        annSeen++;
                        try {
                            dp.addPageAnnotation(e.second);
                            annCopied++;
                        } catch (Throwable th) {
                            if (err.length() < 300) err.append("ann ").append(th.getClass().getSimpleName()).append(": ").append(th.getMessage()).append("; ");
                        }
                    }
                    dp.close();
                    sp.close();
                    di++;
                }
                src.close();
            }
            ParcelFileDescriptor w = rw(out);
            dst.write(w, false);
            w.close();
            dst.close();
            blank.delete();
            emit("{\"kind\":\"op\",\"route\":\"a-edit-rebuild\",\"op\":" + q(op) + ",\"pages\":" + di + ",\"objects_copied\":" + copied
                    + ",\"objects_failed\":" + failed + ",\"object_types\":" + q(Arrays.toString(typeCounts))
                    + ",\"annotation_read_failed_pages\":" + annFailedPages + ",\"annotations_seen\":" + annSeen + ",\"annotations_copied\":" + annCopied
                    + ",\"err\":" + q(err.toString()) + ",\"ms\":" + ms(t0) + ",\"bytes\":" + out.length() + "}");
            verify(out, "edit_rebuild_" + op);
        }
    }
}
