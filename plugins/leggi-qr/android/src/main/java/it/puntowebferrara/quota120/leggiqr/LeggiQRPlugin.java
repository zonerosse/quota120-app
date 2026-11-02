package it.puntowebferrara.quota120.leggiqr;

import android.Manifest;
import android.app.Dialog;
import android.content.pm.PackageManager;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Handler;
import android.os.Looper;
import android.util.Size;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import androidx.camera.core.CameraSelector;
import androidx.camera.core.ImageAnalysis;
import androidx.camera.core.ImageProxy;
import androidx.camera.core.Preview;
import androidx.camera.core.resolutionselector.ResolutionSelector;
import androidx.camera.core.resolutionselector.ResolutionStrategy;
import androidx.camera.lifecycle.ProcessCameraProvider;
import androidx.camera.view.PreviewView;
import androidx.core.content.ContextCompat;
import androidx.lifecycle.LifecycleOwner;
import com.getcapacitor.JSObject;
import com.getcapacitor.PermissionState;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;
import com.google.common.util.concurrent.ListenableFuture;
import com.google.zxing.BarcodeFormat;
import com.google.zxing.BinaryBitmap;
import com.google.zxing.DecodeHintType;
import com.google.zxing.MultiFormatReader;
import com.google.zxing.PlanarYUVLuminanceSource;
import com.google.zxing.Result;
import com.google.zxing.common.HybridBinarizer;
import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.Collections;
import java.util.EnumMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Quota 120 · «Leggi QR» (Android).
 *
 * Fotocamera a tutto schermo (CameraX) con «← Indietro», il titolo e una riga di aiuto; il QR si legge con ZXing,
 * tutto dentro l'app (niente servizi Google Play). Ogni QR letto va alla pagina (evento «letto»): la pagina decide
 * se è un'etichetta dei suoi droni (chiude e apre la scheda) oppure manda un avviso e la fotocamera resta aperta.
 *
 *   disponibile()                                -> { disponibile }
 *   apri({ titolo?, indietro?, suggerimento?, formati? })  -> { aperto: true }    (permesso negato: errore «PERMESSO»)
 *     formati: «qr» (di serie, solo QR) oppure «tutti» (anche DataMatrix e codici a barre: Code 128, Code 39, EAN, UPC)
 *   avviso({ testo })                            -> {}
 *   chiudi()                                     -> {}
 * Eventi: «letto» { testo }, «chiuso» {} (tasto «Indietro» o «indietro» del telefono)
 */
@CapacitorPlugin(name = "LeggiQR", permissions = { @Permission(strings = { Manifest.permission.CAMERA }, alias = "camera") })
public class LeggiQRPlugin extends Plugin {

    private static final String MSG_PERMESSO = "Serve il permesso della fotocamera: Impostazioni › App › Quota 120 › Autorizzazioni";
    private final Handler main = new Handler(Looper.getMainLooper());
    private Dialog dialogo;
    private ExecutorService analisi;
    private ProcessCameraProvider camera;
    private TextView avvisoTv;
    private Runnable nascondi;
    private boolean chiusoDallaPagina = false;
    private String ultimo = "";
    private long ultimoT = 0, pausaFino = 0;
    private boolean tutti = false;   // «formati: tutti» = anche DataMatrix e codici a barre (etichetta del drone)

    @PluginMethod
    public void disponibile(PluginCall call) {
        JSObject r = new JSObject();
        r.put("disponibile", getContext().getPackageManager().hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY));
        call.resolve(r);
    }

    @PluginMethod
    public void apri(PluginCall call) {
        if (getPermissionState("camera") != PermissionState.GRANTED) {
            requestPermissionForAlias("camera", call, "permesso");
        } else {
            mostra(call);
        }
    }

    @PermissionCallback
    private void permesso(PluginCall call) {
        if (getPermissionState("camera") == PermissionState.GRANTED) mostra(call);
        else call.reject(MSG_PERMESSO, "PERMESSO");
    }

    @PluginMethod
    public void avviso(PluginCall call) {
        final String t = call.getString("testo", "");
        main.post(() -> {
            if (avvisoTv != null) {
                if (nascondi != null) main.removeCallbacks(nascondi);
                avvisoTv.setText(t);
                avvisoTv.setVisibility(View.VISIBLE);
                nascondi = () -> { if (avvisoTv != null) avvisoTv.setVisibility(View.GONE); };
                main.postDelayed(nascondi, 3000);
            }
            call.resolve();
        });
    }

    @PluginMethod
    public void chiudi(PluginCall call) {
        main.post(() -> {
            if (dialogo != null) {
                chiusoDallaPagina = true;
                dialogo.dismiss();
            }
            call.resolve();
        });
    }

    // ---------- lo schermo della fotocamera ----------

    private int dp(float v) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, getContext().getResources().getDisplayMetrics()));
    }

    private void mostra(final PluginCall call) {
        main.post(() -> {
            if (dialogo != null) {
                JSObject r = new JSObject();
                r.put("aperto", true);
                call.resolve(r);
                return;
            }
            if (!getContext().getPackageManager().hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)) {
                call.reject("Su questo dispositivo la fotocamera non c’è", "NO_CAMERA");
                return;
            }
            final String titolo = call.getString("titolo", "Leggi QR");
            final String indietro = call.getString("indietro", "← Indietro");
            final String suggerimento = call.getString("suggerimento", "Inquadra il QR dell’etichetta: si apre da solo.");
            tutti = "tutti".equals(call.getString("formati", "qr"));
            ultimo = "";

            FrameLayout radice = new FrameLayout(getActivity());
            radice.setBackgroundColor(Color.rgb(0x20, 0x26, 0x2b));
            radice.setFitsSystemWindows(true);

            PreviewView vista = new PreviewView(getActivity());
            vista.setImplementationMode(PreviewView.ImplementationMode.COMPATIBLE);
            vista.setScaleType(PreviewView.ScaleType.FILL_CENTER);
            radice.addView(vista, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
            radice.addView(new Mirino(getActivity()), new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

            // in alto: «← Indietro» e il titolo
            LinearLayout barra = new LinearLayout(getActivity());
            barra.setOrientation(LinearLayout.HORIZONTAL);
            barra.setGravity(Gravity.CENTER_VERTICAL);
            barra.setBackgroundColor(Color.argb(90, 0, 0, 0));
            barra.setPadding(dp(12), dp(12), dp(12), dp(10));
            TextView b = new TextView(getActivity());
            b.setText(indietro);
            b.setTextColor(Color.WHITE);
            b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
            b.setTypeface(Typeface.DEFAULT_BOLD);
            b.setMinHeight(dp(44));
            b.setGravity(Gravity.CENTER);
            b.setPadding(dp(12), 0, dp(12), 0);
            GradientDrawable bordo = new GradientDrawable();
            bordo.setCornerRadius(dp(9));
            bordo.setStroke(dp(1), Color.argb(102, 255, 255, 255));
            bordo.setColor(Color.TRANSPARENT);
            b.setBackground(bordo);
            b.setClickable(true);
            b.setFocusable(true);
            b.setContentDescription("Indietro");
            b.setOnClickListener(v -> { if (dialogo != null) dialogo.dismiss(); });
            barra.addView(b);
            TextView t = new TextView(getActivity());
            t.setText(titolo);
            t.setTextColor(Color.WHITE);
            t.setTextSize(TypedValue.COMPLEX_UNIT_SP, 17);
            t.setTypeface(Typeface.DEFAULT_BOLD);
            t.setPadding(dp(12), 0, 0, 0);
            barra.addView(t);
            radice.addView(barra, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP));

            // in basso: avviso (nascosto) e riga di aiuto
            LinearLayout fondo = new LinearLayout(getActivity());
            fondo.setOrientation(LinearLayout.VERTICAL);
            fondo.setGravity(Gravity.CENTER_HORIZONTAL);
            avvisoTv = new TextView(getActivity());
            avvisoTv.setTextColor(Color.rgb(0x0F, 0x1C, 0x26));
            avvisoTv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
            avvisoTv.setTypeface(Typeface.DEFAULT_BOLD);
            avvisoTv.setGravity(Gravity.CENTER);
            avvisoTv.setPadding(dp(14), dp(12), dp(14), dp(12));
            GradientDrawable pill = new GradientDrawable();
            pill.setCornerRadius(dp(10));
            pill.setColor(Color.WHITE);
            avvisoTv.setBackground(pill);
            avvisoTv.setVisibility(View.GONE);
            LinearLayout.LayoutParams lpA = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            lpA.setMargins(dp(20), 0, dp(20), dp(14));
            fondo.addView(avvisoTv, lpA);
            TextView piede = new TextView(getActivity());
            piede.setText(suggerimento);
            piede.setTextColor(Color.WHITE);
            piede.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
            piede.setGravity(Gravity.CENTER);
            piede.setBackgroundColor(Color.argb(90, 0, 0, 0));
            piede.setPadding(dp(16), dp(14), dp(16), dp(22));
            fondo.addView(piede, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
            radice.addView(fondo, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM));

            Dialog d = new Dialog(getActivity(), android.R.style.Theme_Black_NoTitleBar_Fullscreen);
            d.requestWindowFeature(Window.FEATURE_NO_TITLE);
            d.setContentView(radice);
            d.setCancelable(true);          // «indietro» del telefono = «← Indietro»
            Window w = d.getWindow();
            if (w != null) {
                w.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                w.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT);
            }
            d.setOnDismissListener(x -> {
                fermaCamera();
                dialogo = null;
                avvisoTv = null;
                if (!chiusoDallaPagina) notifyListeners("chiuso", new JSObject());
                chiusoDallaPagina = false;
            });
            dialogo = d;
            chiusoDallaPagina = false;
            d.show();
            avviaCamera(vista);
            JSObject r = new JSObject();
            r.put("aperto", true);
            call.resolve(r);
        });
    }

    private void avviaCamera(final PreviewView vista) {
        final ListenableFuture<ProcessCameraProvider> f = ProcessCameraProvider.getInstance(getContext());
        f.addListener(() -> {
            try {
                if (dialogo == null) return;
                camera = f.get();
                Preview anteprima = new Preview.Builder().build();
                anteprima.setSurfaceProvider(vista.getSurfaceProvider());
                ImageAnalysis a = new ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .setResolutionSelector(new ResolutionSelector.Builder()
                        .setResolutionStrategy(new ResolutionStrategy(new Size(1280, 720), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER))
                        .build())
                    .build();
                analisi = Executors.newSingleThreadExecutor();
                final MultiFormatReader lettore = new MultiFormatReader();
                Map<DecodeHintType, Object> h = new EnumMap<>(DecodeHintType.class);
                if (tutti) {
                    h.put(DecodeHintType.POSSIBLE_FORMATS, Arrays.asList(BarcodeFormat.QR_CODE, BarcodeFormat.DATA_MATRIX,
                        BarcodeFormat.CODE_128, BarcodeFormat.CODE_39, BarcodeFormat.EAN_13, BarcodeFormat.EAN_8,
                        BarcodeFormat.UPC_A, BarcodeFormat.UPC_E));
                    h.put(DecodeHintType.TRY_HARDER, Boolean.TRUE);
                } else {
                    h.put(DecodeHintType.POSSIBLE_FORMATS, Collections.singletonList(BarcodeFormat.QR_CODE));
                }
                lettore.setHints(h);
                a.setAnalyzer(analisi, img -> leggi(lettore, img));
                camera.unbindAll();
                camera.bindToLifecycle((LifecycleOwner) getActivity(), CameraSelector.DEFAULT_BACK_CAMERA, anteprima, a);
            } catch (Exception e) {
                main.post(() -> {
                    if (avvisoTv != null) {
                        avvisoTv.setText("La fotocamera non si apre: tocca «Indietro» e riprova");
                        avvisoTv.setVisibility(View.VISIBLE);
                    }
                });
            }
        }, ContextCompat.getMainExecutor(getContext()));
    }

    private void leggi(MultiFormatReader lettore, ImageProxy img) {
        try {
            ImageProxy.PlaneProxy p = img.getPlanes()[0];
            ByteBuffer buf = p.getBuffer();
            int w = img.getWidth(), h = img.getHeight(), rs = p.getRowStride();
            byte[] dati = new byte[rs * h];
            buf.rewind();
            buf.get(dati, 0, Math.min(buf.remaining(), dati.length));
            PlanarYUVLuminanceSource src = new PlanarYUVLuminanceSource(dati, rs, h, 0, 0, w, h, false);
            Result r = null;
            try {
                r = lettore.decodeWithState(new BinaryBitmap(new HybridBinarizer(src)));
            } catch (Exception nonTrovato) {
                try {
                    // anche le etichette chiare su fondo scuro
                    r = lettore.decodeWithState(new BinaryBitmap(new HybridBinarizer(src.invert())));
                } catch (Exception ancoraNo) {
                    if (!tutti) throw ancoraNo;
                    // codici a barre: col telefono dritto le barre arrivano in verticale nell'immagine della fotocamera
                    byte[] g = ruota(dati, rs, w, h);
                    r = lettore.decodeWithState(new BinaryBitmap(new HybridBinarizer(new PlanarYUVLuminanceSource(g, h, w, 0, 0, h, w, false))));
                }
            }
            final String t = r == null ? null : r.getText();
            if (t != null && !t.isEmpty()) main.post(() -> letto(t));
        } catch (Exception ignorato) {
            // niente QR in questa immagine
        } finally {
            lettore.reset();
            img.close();
        }
    }

    /** la luminanza girata di 90° (larghezza w, altezza h, riga lunga rs) -> immagine h x w */
    private static byte[] ruota(byte[] y, int rs, int w, int h) {
        byte[] o = new byte[w * h];
        for (int r = 0; r < h; r++) {
            int base = r * rs;
            for (int c = 0; c < w; c++) o[c * h + (h - 1 - r)] = y[base + c];
        }
        return o;
    }

    private void letto(String t) {
        if (dialogo == null) return;
        long ora = System.currentTimeMillis();
        if (ora < pausaFino) return;
        if (t.equals(ultimo) && ora - ultimoT < 2500) return;   // lo stesso QR ancora inquadrato
        ultimo = t;
        ultimoT = ora;
        pausaFino = ora + 1000;
        JSObject r = new JSObject();
        r.put("testo", t);
        notifyListeners("letto", r);
    }

    private void fermaCamera() {
        try {
            if (camera != null) camera.unbindAll();
        } catch (Exception ignorato) {
        }
        camera = null;
        if (analisi != null) analisi.shutdown();
        analisi = null;
    }

    @Override
    protected void handleOnDestroy() {
        if (dialogo != null) {
            chiusoDallaPagina = true;
            dialogo.dismiss();
        }
        super.handleOnDestroy();
    }

    /** quattro angoli bianchi al centro, come nell'anteprima */
    private static class Mirino extends View {
        private final Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Path path = new Path();

        Mirino(android.content.Context c) {
            super(c);
            p.setColor(Color.WHITE);
            p.setStyle(Paint.Style.STROKE);
            p.setStrokeCap(Paint.Cap.ROUND);
            p.setStrokeWidth(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 4, c.getResources().getDisplayMetrics()));
        }

        @Override
        protected void onDraw(Canvas c) {
            super.onDraw(c);
            float lato = Math.min(Math.min(getWidth(), getHeight()) * 0.62f,
                TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, 240, getResources().getDisplayMetrics()));
            float x0 = (getWidth() - lato) / 2f, y0 = (getHeight() - lato) / 2f, x1 = x0 + lato, y1 = y0 + lato, a = lato * 0.22f;
            path.reset();
            path.moveTo(x0, y0 + a); path.lineTo(x0, y0); path.lineTo(x0 + a, y0);
            path.moveTo(x1 - a, y0); path.lineTo(x1, y0); path.lineTo(x1, y0 + a);
            path.moveTo(x1, y1 - a); path.lineTo(x1, y1); path.lineTo(x1 - a, y1);
            path.moveTo(x0 + a, y1); path.lineTo(x0, y1); path.lineTo(x0, y1 - a);
            c.drawPath(path, p);
        }
    }
}
