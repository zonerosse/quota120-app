package android.print;

import android.os.Bundle;
import android.os.CancellationSignal;
import android.os.ParcelFileDescriptor;
import java.io.File;

/**
 * Quota 120: scrive in un file PDF quello che la WebView manderebbe alla stampante (A4, pagine vere).
 * Sta nel pacchetto android.print perché le risposte di onLayout/onWrite non si possono creare da fuori.
 * Se una versione di Android non lo permette, l'errore arriva al plugin e la pagina fa il PDF da sola.
 */
public class Q120PdfDaStampa {

    public interface Fatto {
        void ok();

        void errore(String m);
    }

    public static void scrivi(final PrintDocumentAdapter ad, final PrintAttributes attr, final File f, final Fatto fatto) {
        ad.onStart();
        ad.onLayout(null, attr, new CancellationSignal(), new PrintDocumentAdapter.LayoutResultCallback() {
            @Override
            public void onLayoutFinished(PrintDocumentInfo info, boolean cambiato) {
                final ParcelFileDescriptor pfd;
                try {
                    pfd = ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_CREATE | ParcelFileDescriptor.MODE_TRUNCATE | ParcelFileDescriptor.MODE_READ_WRITE);
                } catch (Exception e) {
                    ad.onFinish();
                    fatto.errore("Il PDF non si prepara");
                    return;
                }
                ad.onWrite(new PageRange[] { PageRange.ALL_PAGES }, pfd, new CancellationSignal(), new PrintDocumentAdapter.WriteResultCallback() {
                    @Override
                    public void onWriteFinished(PageRange[] pagine) {
                        chiudi(pfd);
                        ad.onFinish();
                        fatto.ok();
                    }

                    @Override
                    public void onWriteFailed(CharSequence errore) {
                        chiudi(pfd);
                        ad.onFinish();
                        fatto.errore("Il PDF non si prepara");
                    }

                    @Override
                    public void onWriteCancelled() {
                        chiudi(pfd);
                        ad.onFinish();
                        fatto.errore("Il PDF non si prepara");
                    }
                });
            }

            @Override
            public void onLayoutFailed(CharSequence errore) {
                ad.onFinish();
                fatto.errore("Il PDF non si prepara");
            }

            @Override
            public void onLayoutCancelled() {
                ad.onFinish();
                fatto.errore("Il PDF non si prepara");
            }
        }, new Bundle());
    }

    private static void chiudi(ParcelFileDescriptor p) {
        try {
            p.close();
        } catch (Exception ignored) {
        }
    }
}
