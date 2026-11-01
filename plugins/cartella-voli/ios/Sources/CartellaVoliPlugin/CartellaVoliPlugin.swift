import Foundation
import Capacitor
import UIKit
import UniformTypeIdentifiers

/// Quota 120 · «Collega i voli di DJI Fly»
///
/// Il pilota sceglie UNA volta la cartella dove DJI Fly salva i voli (di solito Sul mio iPhone › DJI Fly › FlightRecords).
/// L'app tiene un «segnalibro» di sicurezza della cartella e, quando la pagina lo chiede, legge solo i file dei voli
/// non ancora mandati (riconosciuti da nome + dimensione + data di modifica, ricordati nell'app).
///
/// Metodi (window.Capacitor.Plugins.CartellaVoli):
///   disponibile()                       -> { disponibile: true }
///   statoCartella()                     -> { disponibile, collegata, nome?, voli?, accessibile? }
///   scegliCartella()                    -> { collegata, nome?, voli?, annullata? }
///   leggiNuovi({ dopo?, max?, maxByte? }) -> { collegata, nome?, file: [{ nome, base64, dimensione, data, chiave }], altri }
///   segnaInviati({ chiavi: [String] })  -> { ok: true }
///   scollega()                          -> { collegata: false }
@objc(CartellaVoliPlugin)
public class CartellaVoliPlugin: CAPPlugin, CAPBridgedPlugin, UIDocumentPickerDelegate {
    public let identifier = "CartellaVoliPlugin"
    public let jsName = "CartellaVoli"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "disponibile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "statoCartella", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "scegliCartella", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "leggiNuovi", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "segnaInviati", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "scollega", returnType: CAPPluginReturnPromise)
    ]

    private let kSegnalibro = "q120.cartella.segnalibro"
    private let kNome = "q120.cartella.nome"
    private let kInviati = "q120.cartella.inviati"
    /// il server accetta file fino a 30 MB: quelli più grandi non si leggono nemmeno
    private let maxFile = 30 * 1024 * 1024
    private let maxInviati = 3000
    private var chiamataScelta: CAPPluginCall?
    private let coda = DispatchQueue(label: "it.puntowebferrara.quota120.cartellavoli", qos: .userInitiated)

    // MARK: - metodi per la pagina

    @objc func disponibile(_ call: CAPPluginCall) {
        call.resolve(["disponibile": true])
    }

    @objc func statoCartella(_ call: CAPPluginCall) {
        coda.async {
            guard let url = self.risolvi() else {
                call.resolve(["disponibile": true, "collegata": false])
                return
            }
            var r: [String: Any] = ["disponibile": true, "collegata": true, "nome": self.nomeSalvato(url)]
            let aperta = url.startAccessingSecurityScopedResource()
            defer { if aperta { url.stopAccessingSecurityScopedResource() } }
            if let voli = try? self.elencaVoli(url) {
                r["voli"] = voli.count
                r["accessibile"] = true
            } else {
                r["accessibile"] = false
            }
            call.resolve(r)
        }
    }

    @objc func scegliCartella(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let vc = self.bridge?.viewController else {
                call.reject("La finestra di scelta non si apre", "NO_VIEW")
                return
            }
            if self.chiamataScelta != nil {
                call.reject("La scelta della cartella è già aperta", "OCCUPATO")
                return
            }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
            picker.delegate = self
            picker.allowsMultipleSelection = false
            picker.modalPresentationStyle = .formSheet
            if let vecchia = self.risolvi() {
                picker.directoryURL = vecchia
            }
            self.chiamataScelta = call
            vc.present(picker, animated: true)
        }
    }

    @objc func leggiNuovi(_ call: CAPPluginCall) {
        let dopo = call.getDouble("dopo") ?? 0            // millisecondi: solo file modificati da qui in poi
        let max = Swift.max(1, Swift.min(call.getInt("max") ?? 10, 50))
        let maxByte = Swift.max(1_000_000, Swift.min(call.getInt("maxByte") ?? 20_000_000, 40_000_000))
        coda.async {
            guard let url = self.risolvi() else {
                call.resolve(["collegata": false, "file": [], "altri": 0])
                return
            }
            let aperta = url.startAccessingSecurityScopedResource()
            defer { if aperta { url.stopAccessingSecurityScopedResource() } }
            let tutti: [Voce]
            do { tutti = try self.elencaVoli(url) } catch {
                call.reject("La cartella dei voli non si apre più: sceglila di nuovo", "NON_SI_APRE", error)
                return
            }
            let gia = Set(UserDefaults.standard.stringArray(forKey: self.kInviati) ?? [])
            let nuovi = tutti
                .filter { !gia.contains($0.chiave) && $0.data.timeIntervalSince1970 * 1000 >= dopo && $0.dimensione > 0 && $0.dimensione <= self.maxFile }
                .sorted { $0.data < $1.data }
            var file: [[String: Any]] = []
            var byte = 0
            var letti = 0
            for v in nuovi {
                if file.count >= max { break }
                if !file.isEmpty && byte + v.dimensione > maxByte { break }
                letti += 1
                guard let dati = self.leggi(v.url) else { continue }
                byte += dati.count
                file.append([
                    "nome": v.url.lastPathComponent,
                    "base64": dati.base64EncodedString(),
                    "dimensione": dati.count,
                    "data": v.data.timeIntervalSince1970 * 1000,
                    "chiave": v.chiave
                ])
            }
            call.resolve(["collegata": true, "nome": self.nomeSalvato(url), "file": file, "altri": Swift.max(0, nuovi.count - letti)])
        }
    }

    @objc func segnaInviati(_ call: CAPPluginCall) {
        let chiavi = (call.getArray("chiavi") ?? []).compactMap { $0 as? String }
        coda.async {
            var L = UserDefaults.standard.stringArray(forKey: self.kInviati) ?? []
            for c in chiavi where !L.contains(c) { L.append(c) }
            if L.count > self.maxInviati { L = Array(L.suffix(self.maxInviati)) }
            UserDefaults.standard.set(L, forKey: self.kInviati)
            call.resolve(["ok": true])
        }
    }

    @objc func scollega(_ call: CAPPluginCall) {
        UserDefaults.standard.removeObject(forKey: kSegnalibro)
        UserDefaults.standard.removeObject(forKey: kNome)
        call.resolve(["collegata": false])
    }

    // MARK: - scelta della cartella

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let call = chiamataScelta else { return }
        chiamataScelta = nil
        guard let url = urls.first else {
            call.resolve(["collegata": risolvi() != nil, "annullata": true])
            return
        }
        coda.async {
            let aperta = url.startAccessingSecurityScopedResource()
            defer { if aperta { url.stopAccessingSecurityScopedResource() } }
            do {
                let dati = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                let nome = self.nomeLeggibile(url)
                UserDefaults.standard.set(dati, forKey: self.kSegnalibro)
                UserDefaults.standard.set(nome, forKey: self.kNome)
                let n = (try? self.elencaVoli(url).count) ?? 0
                call.resolve(["collegata": true, "nome": nome, "voli": n])
            } catch {
                call.reject("Non riesco a ricordare questa cartella: riprova", "SEGNALIBRO", error)
            }
        }
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard let call = chiamataScelta else { return }
        chiamataScelta = nil
        call.resolve(["collegata": risolvi() != nil, "annullata": true])
    }

    // MARK: - aiuti

    private struct Voce {
        let url: URL
        let dimensione: Int
        let data: Date
        var chiave: String { "\(url.lastPathComponent)|\(dimensione)|\(Int(data.timeIntervalSince1970))" }
    }

    /// la cartella salvata (rinnova il segnalibro se iOS lo segna come vecchio)
    private func risolvi() -> URL? {
        guard let d = UserDefaults.standard.data(forKey: kSegnalibro) else { return nil }
        var vecchio = false
        guard let url = try? URL(resolvingBookmarkData: d, options: [], relativeTo: nil, bookmarkDataIsStale: &vecchio) else { return nil }
        if vecchio {
            let aperta = url.startAccessingSecurityScopedResource()
            if let nuovo = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(nuovo, forKey: kSegnalibro)
            }
            if aperta { url.stopAccessingSecurityScopedResource() }
        }
        return url
    }

    private func nomeSalvato(_ url: URL) -> String {
        UserDefaults.standard.string(forKey: kNome) ?? url.lastPathComponent
    }

    /// «DJI Fly › FlightRecords»: il nome della cartella con quello della cartella sopra (il nome dell'app, se iOS lo dà)
    private func nomeLeggibile(_ url: URL) -> String {
        let su = url.deletingLastPathComponent()
        let nomeSu = (try? su.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? su.lastPathComponent
        let nome = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? url.lastPathComponent
        if nomeSu.isEmpty || nomeSu == "/" || nomeSu == "Documents" { return nome }
        return nomeSu + " › " + nome
    }

    /// i file .txt dei voli nella cartella; se il pilota ha scelto «DJI Fly», guarda anche dentro «FlightRecords»
    private func elencaVoli(_ cartella: URL) throws -> [Voce] {
        let fm = FileManager.default
        let chiavi: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        var errore: NSError?
        var risultato: [Voce] = []
        var erroreLettura: Error?
        NSFileCoordinator().coordinate(readingItemAt: cartella, options: [.withoutChanges], error: &errore) { dir in
            do {
                var dove = [dir]
                let dentro = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: chiavi, options: [.skipsHiddenFiles])
                if let fr = dentro.first(where: { $0.lastPathComponent.lowercased() == "flightrecords" && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }) {
                    dove.append(fr)
                }
                for d in dove {
                    let elenco = d == dir ? dentro : try fm.contentsOfDirectory(at: d, includingPropertiesForKeys: chiavi, options: [.skipsHiddenFiles])
                    for f in elenco where f.pathExtension.lowercased() == "txt" {
                        let v = try? f.resourceValues(forKeys: Set(chiavi))
                        guard v?.isRegularFile == true else { continue }
                        risultato.append(Voce(url: f, dimensione: v?.fileSize ?? 0, data: v?.contentModificationDate ?? Date.distantPast))
                    }
                }
            } catch {
                erroreLettura = error
            }
        }
        if let e = errore { throw e }
        if let e = erroreLettura { throw e }
        return risultato
    }

    private func leggi(_ url: URL) -> Data? {
        var errore: NSError?
        var dati: Data?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &errore) { u in
            dati = try? Data(contentsOf: u, options: [.mappedIfSafe])
        }
        return dati
    }
}
