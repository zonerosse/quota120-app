package it.puntowebferrara.quota120.cartellavoli;

import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

/**
 * Quota 120 · cartella dei voli di DJI Fly.
 * Su Android DJI Fly tiene i voli in Android/data, che le altre app non possono leggere:
 * qui ogni metodo risponde «non disponibile» e la pagina continua come oggi (scelta dei file o Condividi › Quota 120).
 */
@CapacitorPlugin(name = "CartellaVoli")
public class CartellaVoliPlugin extends Plugin {

    private JSObject no() {
        JSObject r = new JSObject();
        r.put("disponibile", false);
        r.put("collegata", false);
        r.put("motivo", "android");
        return r;
    }

    @PluginMethod
    public void disponibile(PluginCall call) { call.resolve(no()); }

    @PluginMethod
    public void statoCartella(PluginCall call) { call.resolve(no()); }

    @PluginMethod
    public void scegliCartella(PluginCall call) { call.resolve(no()); }

    @PluginMethod
    public void leggiNuovi(PluginCall call) {
        JSObject r = no();
        r.put("file", new JSArray());
        r.put("altri", 0);
        call.resolve(r);
    }

    @PluginMethod
    public void segnaInviati(PluginCall call) {
        JSObject r = no();
        r.put("ok", true);
        call.resolve(r);
    }

    @PluginMethod
    public void scollega(PluginCall call) { call.resolve(no()); }
}
