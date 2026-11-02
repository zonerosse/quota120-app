package it.puntowebferrara.quota120.stampasalva;

import android.app.Activity;
import android.content.Context;
import android.os.Bundle;
import android.os.CancellationSignal;
import android.os.ParcelFileDescriptor;
import android.print.PageRange;
import android.print.PrintAttributes;
import android.print.PrintDocumentAdapter;
import android.print.PrintDocumentInfo;
import android.print.PrintManager;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * Voce «Stampa» nella scelta di «Stampa o salva»: apre la stampa di Android con il PDF appena preparato.
 * Accetta solo il NOME di un PDF della cartella «condivisi» dell'app (mai percorsi o indirizzi da fuori).
 */
public class StampaActivity extends Activity {

    static final String FILE = "file";
    private boolean ripresa = false;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        String nome = getIntent() == null ? null : getIntent().getStringExtra(FILE);
        File cartella = new File(getCacheDir(), StampaSalvaPlugin.CARTELLA);
        File f = nome == null ? null : new File(cartella, nome);
        try {
            if (f == null || nome.contains("/") || !nome.toLowerCase().endsWith(".pdf") || !f.isFile()
                || !f.getCanonicalFile().getParentFile().equals(cartella.getCanonicalFile())) {
                finish();
                return;
            }
            PrintManager pm = (PrintManager) getSystemService(Context.PRINT_SERVICE);
            pm.print(nome.replaceAll("\\.pdf$", ""), new DaFile(f, nome), new PrintAttributes.Builder()
                .setMediaSize(PrintAttributes.MediaSize.ISO_A4).build());
        } catch (Exception e) {
            finish();
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        // la prima volta è l'avvio; la seconda è il ritorno dalla stampa di Android
        if (ripresa) finish();
        ripresa = true;
    }

    /** il PDF già pronto, passato così com'è alla stampa */
    private static class DaFile extends PrintDocumentAdapter {
        private final File f;
        private final String nome;

        DaFile(File f, String nome) {
            this.f = f;
            this.nome = nome;
        }

        @Override
        public void onLayout(PrintAttributes vecchi, PrintAttributes nuovi, CancellationSignal stop, LayoutResultCallback cb, Bundle extra) {
            if (stop != null && stop.isCanceled()) {
                cb.onLayoutCancelled();
                return;
            }
            cb.onLayoutFinished(new PrintDocumentInfo.Builder(nome)
                .setContentType(PrintDocumentInfo.CONTENT_TYPE_DOCUMENT)
                .setPageCount(PrintDocumentInfo.PAGE_COUNT_UNKNOWN)
                .build(), true);
        }

        @Override
        public void onWrite(PageRange[] pagine, ParcelFileDescriptor dest, CancellationSignal stop, WriteResultCallback cb) {
            try (InputStream i = new FileInputStream(f); OutputStream o = new FileOutputStream(dest.getFileDescriptor())) {
                byte[] b = new byte[65536];
                int n;
                while ((n = i.read(b)) > 0) {
                    if (stop != null && stop.isCanceled()) {
                        cb.onWriteCancelled();
                        return;
                    }
                    o.write(b, 0, n);
                }
                cb.onWriteFinished(new PageRange[] { PageRange.ALL_PAGES });
            } catch (Exception e) {
                cb.onWriteFailed(e.getMessage());
            }
        }
    }
}
