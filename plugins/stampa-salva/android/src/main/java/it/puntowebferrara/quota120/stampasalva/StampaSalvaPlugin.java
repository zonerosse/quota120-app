package it.puntowebferrara.quota120.stampasalva;

import android.content.ClipData;
import android.content.Intent;
import android.content.pm.LabeledIntent;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.pdf.PdfRenderer;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.print.PrintAttributes;
import android.print.PrintDocumentAdapter;
import android.print.Q120PdfDaStampa;
import android.util.Base64;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.WebResourceRequest;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import androidx.core.content.FileProvider;
import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Quota 120 · «Stampa o salva» dentro l'app (Android).
 *
 * Sul sito documenti, stampe ed etichette si aprono in una finestra nuova; nell'app la pagina li mostra in un visore
 * e «Stampa o salva» apre la scelta di Android (WhatsApp, Gmail, Drive, File…) con in più la voce «Stampa».
 *
 *   disponibile()                           -> { disponibile: true, stampa: true }
 *   condividiFile({ nome, mime, base64 })   -> { aperto: true }
 *   htmlInPdf({ html, nome? })              -> { base64 }     PDF A4 dalla stampa HTML (se non riesce: errore, la pagina fa il PDF da sola)
 *   pdfPagine({ base64, larghezza?, max? }) -> { pagine: [{ base64, w, h }], totale }
 */
@CapacitorPlugin(name = "StampaSalva")
public class StampaSalvaPlugin extends Plugin {

    static final String CARTELLA = "condivisi";
    private final ExecutorService lavoro = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    private WebView webPdf;
    private PluginCall chiamataPdf;
    private Runnable scadenzaPdf;

    @PluginMethod
    public void disponibile(PluginCall call) {
        JSObject r = new JSObject();
        r.put("disponibile", true);
        r.put("stampa", true);
        call.resolve(r);
    }

    // ---------- scelta di Android con il file ----------

    @PluginMethod
    public void condividiFile(PluginCall call) {
        String b64 = call.getString("base64");
        String mime = call.getString("mime", "application/pdf");
        if (b64 == null || b64.isEmpty()) {
            call.reject("Il file è vuoto", "VUOTO");
            return;
        }
        final File f;
        try {
            byte[] dati = Base64.decode(b64, Base64.DEFAULT);
            File cartella = new File(getContext().getCacheDir(), CARTELLA);
            pulisci(cartella);
            if (!cartella.isDirectory() && !cartella.mkdirs()) throw new IOException("cartella");
            f = new File(cartella, nomeFile(call.getString("nome"), mime));
            try (FileOutputStream o = new FileOutputStream(f)) {
                o.write(dati);
            }
        } catch (Exception e) {
            call.reject("Non riesco a preparare il file", "SCRITTURA", e);
            return;
        }
        getActivity().runOnUiThread(() -> {
            try {
                Uri uri = FileProvider.getUriForFile(getContext(), getContext().getPackageName() + ".fileprovider", f);
                Intent manda = new Intent(Intent.ACTION_SEND);
                manda.setType(mime);
                manda.putExtra(Intent.EXTRA_STREAM, uri);
                manda.putExtra(Intent.EXTRA_SUBJECT, f.getName());
                manda.setClipData(ClipData.newRawUri(f.getName(), uri));
                manda.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                Intent scelta = Intent.createChooser(manda, "Stampa o salva");
                if ("application/pdf".equals(mime)) {
                    Intent stampa = new Intent(getContext(), StampaActivity.class);
                    stampa.putExtra(StampaActivity.FILE, f.getName());
                    LabeledIntent voce = new LabeledIntent(stampa, getContext().getPackageName(), "Stampa", R.drawable.q120_stampa);
                    scelta.putExtra(Intent.EXTRA_INITIAL_INTENTS, new Intent[] { voce });
                }
                getActivity().startActivity(scelta);
                JSObject r = new JSObject();
                r.put("aperto", true);
                call.resolve(r);
            } catch (Exception e) {
                call.reject("La scelta non si apre", "SCELTA", e);
            }
        });
    }

    // ---------- PDF A4 da una stampa HTML ----------

    @PluginMethod
    public void htmlInPdf(PluginCall call) {
        final String html = call.getString("html");
        if (html == null || html.isEmpty()) {
            call.reject("Niente da stampare", "VUOTO");
            return;
        }
        getActivity().runOnUiThread(() -> {
            if (chiamataPdf != null) {
                call.reject("Sto già preparando un PDF", "OCCUPATO");
                return;
            }
            try {
                chiamataPdf = call;
                WebView w = new WebView(getActivity());
                webPdf = w;
                w.getSettings().setJavaScriptEnabled(false);
                w.setVisibility(View.INVISIBLE);
                ViewGroup radice = getActivity().findViewById(android.R.id.content);
                radice.addView(w, new FrameLayout.LayoutParams(794, 1123));
                w.setWebViewClient(new WebViewClient() {
                    private boolean fatto = false;

                    @Override
                    public void onPageFinished(WebView view, String url) {
                        if (fatto || view != webPdf) return;
                        fatto = true;
                        main.postDelayed(() -> creaPdf(view), 400);
                    }

                    @Override
                    public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                        return true;   // niente collegamenti esterni nel foglio
                    }
                });
                scadenzaPdf = () -> fine(null, "Il PDF ci mette troppo: riprova");
                main.postDelayed(scadenzaPdf, 25000);
                w.loadDataWithBaseURL("https://app.quota120.com/", html, "text/html", "UTF-8", null);
            } catch (Throwable e) {
                fine(null, "Il PDF non si prepara");
            }
        });
    }

    private void creaPdf(WebView w) {
        if (w != webPdf || chiamataPdf == null) return;
        try {
            final File f = new File(getContext().getCacheDir(), "stampa-" + System.currentTimeMillis() + ".pdf");
            PrintDocumentAdapter ad = w.createPrintDocumentAdapter("Quota 120");
            PrintAttributes attr = new PrintAttributes.Builder()
                .setMediaSize(PrintAttributes.MediaSize.ISO_A4)
                .setResolution(new PrintAttributes.Resolution("pdf", "pdf", 600, 600))
                .setMinMargins(new PrintAttributes.Margins(394, 394, 394, 394))   // 10 mm (in millesimi di pollice)
                .setColorMode(PrintAttributes.COLOR_MODE_COLOR)
                .build();
            Q120PdfDaStampa.scrivi(ad, attr, f, new Q120PdfDaStampa.Fatto() {
                @Override
                public void ok() {
                    lavoro.execute(() -> {
                        String b64 = null;
                        try {
                            b64 = Base64.encodeToString(leggi(f), Base64.NO_WRAP);
                        } catch (Exception ignored) {
                        }
                        //noinspection ResultOfMethodCallIgnored
                        f.delete();
                        final String b = b64;
                        main.post(() -> fine(b, "Il PDF non si prepara"));
                    });
                }

                @Override
                public void errore(String m) {
                    //noinspection ResultOfMethodCallIgnored
                    f.delete();
                    main.post(() -> fine(null, m));
                }
            });
        } catch (Throwable e) {
            // su alcune versioni di Android la stampa in PDF non si può usare così: la pagina fa il PDF da sola
            fine(null, "Il PDF non si prepara");
        }
    }

    private void fine(String base64, String errore) {
        if (scadenzaPdf != null) main.removeCallbacks(scadenzaPdf);
        scadenzaPdf = null;
        PluginCall c = chiamataPdf;
        chiamataPdf = null;
        WebView w = webPdf;
        webPdf = null;
        if (w != null) {
            try {
                ViewGroup p = (ViewGroup) w.getParent();
                if (p != null) p.removeView(w);
                w.destroy();
            } catch (Exception ignored) {
            }
        }
        if (c == null) return;
        if (base64 != null && !base64.isEmpty()) {
            JSObject r = new JSObject();
            r.put("base64", base64);
            c.resolve(r);
        } else {
            c.reject(errore == null ? "Il PDF non si prepara" : errore, "PDF");
        }
    }

    // ---------- pagine di un PDF come immagini (per il visore) ----------

    @PluginMethod
    public void pdfPagine(PluginCall call) {
        final String b64 = call.getString("base64");
        final int larghezza = Math.max(300, Math.min(call.getInt("larghezza", 1200), 2000));
        final int max = Math.max(1, Math.min(call.getInt("max", 20), 60));
        if (b64 == null || b64.isEmpty()) {
            call.reject("Il PDF non si apre", "PDF");
            return;
        }
        lavoro.execute(() -> {
            File f = new File(getContext().getCacheDir(), "vedi-" + System.currentTimeMillis() + ".pdf");
            try {
                try (FileOutputStream o = new FileOutputStream(f)) {
                    o.write(Base64.decode(b64, Base64.DEFAULT));
                }
                JSArray pagine = new JSArray();
                int totale;
                try (ParcelFileDescriptor pfd = ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY);
                     PdfRenderer pdf = new PdfRenderer(pfd)) {
                    totale = pdf.getPageCount();
                    for (int i = 0; i < Math.min(totale, max); i++) {
                        try (PdfRenderer.Page p = pdf.openPage(i)) {
                            int w = larghezza;
                            int h = Math.max(1, Math.round((float) larghezza * p.getHeight() / Math.max(1, p.getWidth())));
                            Bitmap bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
                            bmp.eraseColor(Color.WHITE);
                            p.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY);
                            ByteArrayOutputStream out = new ByteArrayOutputStream();
                            bmp.compress(Bitmap.CompressFormat.JPEG, 80, out);
                            bmp.recycle();
                            JSObject x = new JSObject();
                            x.put("base64", Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP));
                            x.put("w", w);
                            x.put("h", h);
                            pagine.put(x);
                        }
                    }
                }
                JSObject r = new JSObject();
                r.put("pagine", pagine);
                r.put("totale", totale);
                call.resolve(r);
            } catch (SecurityException e) {
                call.reject("Il PDF è protetto da una password", "PROTETTO", e);
            } catch (Throwable e) {
                call.reject("Il PDF non si apre", "PDF");
            } finally {
                //noinspection ResultOfMethodCallIgnored
                f.delete();
            }
        });
    }

    // ---------- aiuti ----------

    static byte[] leggi(File f) throws IOException {
        try (FileInputStream i = new FileInputStream(f); ByteArrayOutputStream o = new ByteArrayOutputStream()) {
            byte[] b = new byte[65536];
            int n;
            while ((n = i.read(b)) > 0) o.write(b, 0, n);
            return o.toByteArray();
        }
    }

    private static void pulisci(File cartella) {
        File[] L = cartella.listFiles();
        if (L == null) return;
        for (File x : L) {
            //noinspection ResultOfMethodCallIgnored
            x.delete();
        }
    }

    static String nomeFile(String n, String mime) {
        String nome = n == null ? "" : n.replaceAll("[/\\\\:?*\"<>|\\r\\n\\t]+", " ").trim();
        if (nome.isEmpty()) nome = "Quota 120";
        if (nome.length() > 90) nome = nome.substring(0, 90);
        String est;
        switch (mime == null ? "" : mime.toLowerCase(Locale.ROOT)) {
            case "application/pdf": est = "pdf"; break;
            case "image/jpeg": est = "jpg"; break;
            case "image/png": est = "png"; break;
            case "image/webp": est = "webp"; break;
            case "image/heic": case "image/heif": est = "heic"; break;
            case "text/plain": est = "txt"; break;
            default: est = "";
        }
        String e = nome.contains(".") ? nome.substring(nome.lastIndexOf('.') + 1).toLowerCase(Locale.ROOT) : "";
        if (!est.isEmpty() && !e.equals(est) && !(est.equals("jpg") && e.equals("jpeg"))) nome = nome + "." + est;
        return nome;
    }
}
