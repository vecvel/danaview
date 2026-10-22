// HOM-27 spike, route (b): PdfBox-Android 2.0.27.0 on the same fixtures as route (a).
//
// An Instrumentation (PdfBox-Android needs a Context for its assets), run with
//   adb shell am instrument -w dev.danaview.spike.hom27b/.Hom27PdfBox
// Input PDFs: <filesDir>/in, outputs and results.log (HOM27 json lines): <filesDir>/out.

package dev.danaview.spike.hom27b;

import android.app.Instrumentation;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;

import com.tom_roush.pdfbox.android.PDFBoxResourceLoader;
import com.tom_roush.pdfbox.cos.COSName;
import com.tom_roush.pdfbox.multipdf.PDFMergerUtility;
import com.tom_roush.pdfbox.multipdf.PageExtractor;
import com.tom_roush.pdfbox.pdmodel.PDDocument;
import com.tom_roush.pdfbox.pdmodel.PDPage;
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream;
import com.tom_roush.pdfbox.pdmodel.PDPageTree;
import com.tom_roush.pdfbox.pdmodel.PDResources;
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle;
import com.tom_roush.pdfbox.pdmodel.graphics.PDXObject;
import com.tom_roush.pdfbox.pdmodel.graphics.color.PDColor;
import com.tom_roush.pdfbox.pdmodel.graphics.color.PDDeviceRGB;
import com.tom_roush.pdfbox.pdmodel.graphics.image.JPEGFactory;
import com.tom_roush.pdfbox.pdmodel.graphics.image.LosslessFactory;
import com.tom_roush.pdfbox.pdmodel.graphics.image.PDImageXObject;
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotation;
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationMarkup;
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationRubberStamp;
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationText;
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationTextMarkup;
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAppearanceDictionary;
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAppearanceStream;
import com.tom_roush.pdfbox.text.PDFTextStripper;

import java.io.File;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.TreeMap;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public final class Hom27PdfBox extends Instrumentation {
    static final Pattern TOKEN = Pattern.compile("HOM27[TMA]-P\\d{4}");
    private PrintWriter log;
    private File in, out;

    @Override
    public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        start();
    }

    @Override
    public void onStart() {
        Bundle result = new Bundle();
        try {
            File base = getTargetContext().getFilesDir();
            in = new File(base, "in");
            out = new File(base, "out");
            out.mkdirs();
            log = new PrintWriter(new FileWriter(new File(out, "results.log")));
            long t0 = System.nanoTime();
            PDFBoxResourceLoader.init(getTargetContext());
            emit("{\"kind\":\"caps\",\"route\":\"b-pdfbox\",\"sdk\":" + Build.VERSION.SDK_INT + ",\"release\":" + q(Build.VERSION.RELEASE)
                    + ",\"abi\":" + q(Build.SUPPORTED_ABIS[0]) + ",\"init_ms\":" + ms(t0)
                    + ",\"max_heap_mb\":" + (Runtime.getRuntime().maxMemory() >> 20) + "}");
            runAll();
            emit("{\"kind\":\"done\"}");
            result.putString("hom27", "done");
        } catch (Throwable t) {
            emit("{\"kind\":\"error\",\"err\":" + q(Log.getStackTraceString(t)) + "}");
            result.putString("hom27", "error " + t);
        } finally {
            if (log != null) log.close();
        }
        finish(0, result);
    }

    // ---------------------------------------------------------------- helpers

    void emit(String json) {
        Log.i("HOM27", json);
        if (log != null) {
            log.println("HOM27 " + json);
            log.flush();
        }
    }

    static String q(String s) {
        return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\t", " ") + "\"";
    }

    static String ms(long t0) {
        return String.format(Locale.US, "%.1f", (System.nanoTime() - t0) / 1e6);
    }

    File fx(String name) {
        return new File(in, name);
    }

    void op(String op, File o, long t0, String extra) throws Exception {
        String took = ms(t0);
        emit("{\"kind\":\"op\",\"route\":\"b-pdfbox\",\"op\":" + q(op) + ",\"ms\":" + took + ",\"bytes\":" + o.length()
                + (extra == null ? "" : "," + extra) + "}");
        verify(o, op);
    }

    /** PDFBox's own text extraction per page, the page order of tokens, rotations and annotation subtypes. */
    void verify(File f, String tag) throws Exception {
        long t0 = System.nanoTime();
        PDDocument d = PDDocument.load(f);
        int n = d.getNumberOfPages();
        PDFTextStripper st = new PDFTextStripper();
        TreeSet<String> all = new TreeSet<>();
        int pagesWithToken = 0;
        StringBuilder order = new StringBuilder();
        StringBuilder rot = new StringBuilder();
        TreeMap<String, Integer> subtypes = new TreeMap<>();
        for (int i = 1; i <= n; i++) {
            st.setStartPage(i);
            st.setEndPage(i);
            Matcher m = TOKEN.matcher(st.getText(d));
            boolean any = false;
            while (m.find()) {
                all.add(m.group());
                if (!any && i <= 6) order.append(order.length() > 0 ? "," : "").append(m.group());
                any = true;
            }
            if (any) pagesWithToken++;
            PDPage p = d.getPage(i - 1);
            if (i <= 6) rot.append(rot.length() > 0 ? "," : "").append(p.getRotation());
            for (PDAnnotation a : p.getAnnotations()) {
                String s = a.getSubtype();
                subtypes.put(s, subtypes.getOrDefault(s, 0) + 1);
            }
        }
        d.close();
        emit("{\"kind\":\"verify\",\"tag\":" + q(tag) + ",\"file\":" + q(f.getName()) + ",\"bytes\":" + f.length() + ",\"pages\":" + n
                + ",\"tokens\":" + all.size() + ",\"pages_with_token\":" + pagesWithToken + ",\"first_tokens\":" + q(order.toString())
                + ",\"rotations\":" + q(rot.toString()) + ",\"annotations\":" + q(subtypes.toString()) + ",\"verify_ms\":" + ms(t0) + "}");
    }

    // ---------------------------------------------------------------- operations

    void runAll() throws Exception {
        String text200 = "text_200p.pdf", partner = "merge_partner_3p.pdf", images = "image_only_2p.pdf", annotated = "annotated_2p.pdf";
        for (String f : new String[] {text200, partner, images, annotated}) verify(fx(f), "baseline");

        // Load + save without changes (the cost floor of every tool).
        {
            long t0 = System.nanoTime();
            PDDocument d = PDDocument.load(fx(text200));
            File o = new File(out, "b_roundtrip_200p.pdf");
            d.save(o);
            d.close();
            op("roundtrip_200p", o, t0, null);
        }
        // Merge 200 + 3 pages.
        {
            long t0 = System.nanoTime();
            PDDocument dst = PDDocument.load(fx(text200));
            PDDocument src = PDDocument.load(fx(partner));
            new PDFMergerUtility().appendDocument(dst, src);
            File o = new File(out, "b_merge_203p.pdf");
            dst.save(o);
            src.close();
            dst.close();
            op("merge_200+3", o, t0, null);
        }
        // Merge text + rotated partner + scanned pages (PDFs and images in one result).
        {
            long t0 = System.nanoTime();
            PDDocument dst = PDDocument.load(fx(partner));
            PDDocument a = PDDocument.load(fx(images));
            PDDocument b = PDDocument.load(fx(annotated));
            PDFMergerUtility mu = new PDFMergerUtility();
            mu.appendDocument(dst, a);
            mu.appendDocument(dst, b);
            File o = new File(out, "b_merge_mixed_7p.pdf");
            dst.save(o);
            a.close();
            b.close();
            dst.close();
            op("merge_3+2scans+2annotated", o, t0, null);
        }
        // Split: pages 1-100 and 101-200.
        {
            long t0 = System.nanoTime();
            PDDocument d = PDDocument.load(fx(text200));
            PDDocument first = new PageExtractor(d, 1, 100).extract();
            PDDocument second = new PageExtractor(d, 101, 200).extract();
            File o1 = new File(out, "b_split_1-100.pdf");
            File o2 = new File(out, "b_split_101-200.pdf");
            first.save(o1);
            second.save(o2);
            first.close();
            second.close();
            d.close();
            op("split_1-100", o1, t0, "\"second_bytes\":" + o2.length());
            verify(o2, "split_101-200");
        }
        // Reorder: 3,1,2.
        {
            long t0 = System.nanoTime();
            PDDocument d = PDDocument.load(fx(partner));
            PDPageTree pages = d.getPages();
            PDPage third = pages.get(2);
            pages.remove(2);
            pages.insertBefore(third, pages.get(0));
            File o = new File(out, "b_reorder_312.pdf");
            d.save(o);
            d.close();
            op("reorder_3,1,2", o, t0, null);
        }
        // Reorder 200 pages (reverse) - the 200-page timing for a page-tree rewrite.
        {
            long t0 = System.nanoTime();
            PDDocument d = PDDocument.load(fx(text200));
            PDPageTree pages = d.getPages();
            List<PDPage> all = new ArrayList<>();
            for (PDPage p : pages) all.add(p);
            for (int i = all.size() - 1; i >= 0; i--) pages.remove(all.get(i));
            for (int i = all.size() - 1; i >= 0; i--) pages.add(all.get(i));
            File o = new File(out, "b_reverse_200p.pdf");
            d.save(o);
            d.close();
            op("reorder_reverse_200p", o, t0, null);
        }
        // Rotate page 1 by 90 (page 3 already has /Rotate 90 and must keep it).
        {
            long t0 = System.nanoTime();
            PDDocument d = PDDocument.load(fx(partner));
            PDPage p = d.getPage(0);
            p.setRotation((p.getRotation() + 90) % 360);
            File o = new File(out, "b_rotate_p1.pdf");
            d.save(o);
            d.close();
            op("rotate_p1_90", o, t0, null);
        }
        // Rotate all 200 pages.
        {
            long t0 = System.nanoTime();
            PDDocument d = PDDocument.load(fx(text200));
            for (PDPage p : d.getPages()) p.setRotation((p.getRotation() + 90) % 360);
            File o = new File(out, "b_rotate_200p.pdf");
            d.save(o);
            d.close();
            op("rotate_all_200p", o, t0, null);
        }
        // Delete page 2 of 3, and every second page of 200.
        {
            long t0 = System.nanoTime();
            PDDocument d = PDDocument.load(fx(partner));
            d.removePage(1);
            File o = new File(out, "b_delete_p2.pdf");
            d.save(o);
            d.close();
            op("delete_p2", o, t0, null);
        }
        {
            long t0 = System.nanoTime();
            PDDocument d = PDDocument.load(fx(text200));
            for (int i = 199; i >= 0; i -= 2) d.removePage(i);
            File o = new File(out, "b_delete_even_200p.pdf");
            d.save(o);
            d.close();
            op("delete_even_pages_200p", o, t0, null);
        }
        // Insert / import: page 2 of the partner (landscape) after page 1 of the 200-page file.
        {
            long t0 = System.nanoTime();
            PDDocument d = PDDocument.load(fx(text200));
            PDDocument src = PDDocument.load(fx(partner));
            PDPage imported = d.importPage(src.getPage(1));
            d.getPages().remove(imported);
            d.getPages().insertAfter(imported, d.getPage(0));
            File o = new File(out, "b_insert_after_p1.pdf");
            d.save(o);
            src.close();
            d.close();
            op("insert_partner_p2_after_p1", o, t0, null);
        }
        // Annotate: the seven tool annotations on page 1 with generated appearances.
        annotate(annotated, "b_annotate_annotated_2p.pdf");
        annotate(text200, "b_annotate_200p.pdf");
        // Sign: a transparent signature image burned into the page content + a stamp annotation.
        sign(annotated, "b_sign_annotated_2p.pdf", false);
        sign(text200, "b_sign_every_page_200p.pdf", true);
        // Compress presets on the scanned pages, and on the text file (no images: must not grow or lose text).
        compress(images, "b_compress_high.pdf", 0.85f, 1.0f, "High");
        compress(images, "b_compress_medium.pdf", 0.6f, 0.75f, "Medium");
        compress(images, "b_compress_small.pdf", 0.4f, 0.5f, "Small");
        compress(text200, "b_compress_small_200p.pdf", 0.4f, 0.5f, "Small_text");
    }

    static float[] quad(float x1, float y1, float x2, float y2) {
        // QuadPoints order used by most viewers: x1,y2 x2,y2 x1,y1 x2,y1 (top-left, top-right, bottom-left, bottom-right).
        return new float[] {x1, y2, x2, y2, x1, y1, x2, y1};
    }

    void annotate(String in, String outName) throws Exception {
        long t0 = System.nanoTime();
        PDDocument d = PDDocument.load(fx(in));
        PDPage p = d.getPage(0);
        float h = p.getMediaBox().getHeight();
        List<PDAnnotation> anns = p.getAnnotations();
        String[] markups = {PDAnnotationTextMarkup.SUB_TYPE_HIGHLIGHT, PDAnnotationTextMarkup.SUB_TYPE_UNDERLINE,
                PDAnnotationTextMarkup.SUB_TYPE_STRIKEOUT};
        float[][] colors = {{1, 1, 0}, {0, 0, 1}, {1, 0, 0}};
        for (int i = 0; i < markups.length; i++) {
            PDAnnotationTextMarkup m = new PDAnnotationTextMarkup(markups[i]);
            float y1 = h - 200 - i * 14, y2 = y1 + 12;
            m.setRectangle(new PDRectangle(56, y1, 300, 12));
            m.setQuadPoints(quad(56, y1, 356, y2));
            m.setColor(new PDColor(colors[i], PDDeviceRGB.INSTANCE));
            m.constructAppearances(d);
            anns.add(m);
        }
        PDAnnotationMarkup ink = new PDAnnotationMarkup();
        ink.getCOSObject().setName(COSName.SUBTYPE, PDAnnotationMarkup.SUB_TYPE_INK);
        ink.setRectangle(new PDRectangle(60, 80, 220, 80));
        ink.setInkList(new float[][] {{70, 100, 120, 150, 170, 95, 270, 140}});
        ink.setColor(new PDColor(new float[] {0, 0, 0}, PDDeviceRGB.INSTANCE));
        ink.constructAppearances(d);
        anns.add(ink);
        PDAnnotationMarkup ft = new PDAnnotationMarkup();
        ft.getCOSObject().setName(COSName.SUBTYPE, PDAnnotationMarkup.SUB_TYPE_FREETEXT);
        ft.setRectangle(new PDRectangle(320, 90, 220, 40));
        ft.setContents("HOM-27 note (route b)");
        ft.setDefaultAppearance("/Helv 12 Tf 1 0 0 rg");
        ft.constructAppearances(d);
        anns.add(ft);
        PDAnnotationText note = new PDAnnotationText();
        note.setRectangle(new PDRectangle(540, h - 120, 20, 20));
        note.setContents("Sticky note");
        note.constructAppearances(d);
        anns.add(note);
        File o = new File(out, outName);
        d.save(o);
        d.close();
        op("annotate_" + in, o, t0, "\"added\":\"Highlight,Underline,StrikeOut,Ink,FreeText,Text\"");
    }

    static Bitmap signatureBitmap() {
        Bitmap b = Bitmap.createBitmap(360, 120, Bitmap.Config.ARGB_8888);
        b.eraseColor(Color.TRANSPARENT);
        Canvas c = new Canvas(b);
        Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        paint.setColor(Color.rgb(20, 40, 160));
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(6);
        android.graphics.Path path = new android.graphics.Path();
        path.moveTo(20, 80);
        path.cubicTo(80, 10, 140, 110, 200, 40);
        path.cubicTo(240, 10, 300, 100, 340, 60);
        c.drawPath(path, paint);
        return b;
    }

    void sign(String in, String outName, boolean everyPage) throws Exception {
        long t0 = System.nanoTime();
        PDDocument d = PDDocument.load(fx(in));
        PDImageXObject img = LosslessFactory.createFromImage(d, signatureBitmap());
        int n = everyPage ? d.getNumberOfPages() : 1;
        for (int i = 0; i < n; i++) {
            PDPage p = d.getPage(i);
            // Burned in: appended to the page content, original content untouched (compressed, graphics state reset).
            PDPageContentStream cs = new PDPageContentStream(d, p, PDPageContentStream.AppendMode.APPEND, true, true);
            cs.drawImage(img, 330, 60, 180, 60);
            cs.close();
        }
        if (!everyPage) {
            // Also as a stamp annotation that carries the same image (movable until burned in).
            PDPage p = d.getPage(0);
            PDAnnotationRubberStamp stamp = new PDAnnotationRubberStamp();
            PDRectangle r = new PDRectangle(330, 140, 180, 60);
            stamp.setRectangle(r);
            stamp.setName("Approved");
            PDAppearanceStream ap = new PDAppearanceStream(d);
            ap.setBBox(new PDRectangle(180, 60));
            ap.setResources(new PDResources());
            PDPageContentStream as = new PDPageContentStream(d, ap);
            as.drawImage(img, 0, 0, 180, 60);
            as.close();
            PDAppearanceDictionary dict = new PDAppearanceDictionary();
            dict.setNormalAppearance(ap);
            stamp.setAppearance(dict);
            p.getAnnotations().add(stamp);
        }
        File o = new File(out, outName);
        d.save(o);
        d.close();
        op(everyPage ? "sign_burn_in_every_page_200p" : "sign_burn_in_plus_stamp", o, t0, "\"pages_signed\":" + n);
    }

    void compress(String in, String outName, float quality, float scale, String preset) throws Exception {
        long t0 = System.nanoTime();
        PDDocument d = PDDocument.load(fx(in));
        int replaced = 0;
        long before = 0, after = 0;
        for (PDPage p : d.getPages()) {
            PDResources res = p.getResources();
            if (res == null) continue;
            for (COSName name : res.getXObjectNames()) {
                PDXObject x = res.getXObject(name);
                if (!(x instanceof PDImageXObject)) continue;
                PDImageXObject im = (PDImageXObject) x;
                before += im.getCOSObject().getLength();
                Bitmap b = im.getImage();
                Bitmap s = scale < 1f
                        ? Bitmap.createScaledBitmap(b, Math.max(1, Math.round(b.getWidth() * scale)), Math.max(1, Math.round(b.getHeight() * scale)), true)
                        : b;
                // getImage() is ARGB; without this JPEGFactory also writes a lossless alpha SMask.
                Bitmap opaque = s.copy(Bitmap.Config.ARGB_8888, true);
                opaque.setHasAlpha(false);
                PDImageXObject j = JPEGFactory.createFromImage(d, opaque, quality);
                after += j.getCOSObject().getLength();
                res.put(name, j);
                replaced++;
            }
        }
        File o = new File(out, outName);
        d.save(o);
        d.close();
        op("compress_" + preset, o, t0, "\"quality\":" + quality + ",\"scale\":" + scale + ",\"images_replaced\":" + replaced
                + ",\"image_stream_bytes_before\":" + before + ",\"image_stream_bytes_after\":" + after);
    }
}
