import Foundation
import Capacitor
import UIKit
import WebKit
import PDFKit

/// Quota 120 · «Stampa o salva» dentro l'app
///
/// Sul sito documenti, stampe ed etichette si aprono in una finestra nuova; nell'app la finestra nuova non c'è,
/// quindi la pagina li mostra in un visore e da lì «Stampa o salva» apre la scelta di iOS (Stampa, Salva su File, Mail, WhatsApp…).
///
/// Metodi (window.Capacitor.Plugins.StampaSalva):
///   disponibile()                              -> { disponibile: true, stampa }
///   condividiFile({ nome, mime, base64 })      -> { completato, attivita }      scelta di iOS con il file
///   htmlInPdf({ html, nome? })                 -> { base64, pagine }            PDF A4 (pagine vere) da una stampa HTML
///   pdfPagine({ base64, larghezza?, max? })    -> { pagine: [{ base64, w, h }], totale }   pagine del PDF come JPEG
@objc(StampaSalvaPlugin)
public class StampaSalvaPlugin: CAPPlugin, CAPBridgedPlugin, WKNavigationDelegate {
    public let identifier = "StampaSalvaPlugin"
    public let jsName = "StampaSalva"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "disponibile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "condividiFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "htmlInPdf", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pdfPagine", returnType: CAPPluginReturnPromise)
    ]

    /// A4 in punti (72 per pollice) e margine di 10 mm
    private let carta = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
    private let margine: CGFloat = 28.35
    private var webPdf: WKWebView?
    private var chiamataPdf: CAPPluginCall?
    private var scadenzaPdf: DispatchWorkItem?

    @objc func disponibile(_ call: CAPPluginCall) {
        call.resolve(["disponibile": true, "stampa": UIPrintInteractionController.isPrintingAvailable])
    }

    // MARK: - scelta di iOS con il file

    @objc func condividiFile(_ call: CAPPluginCall) {
        guard let b64 = call.getString("base64"),
              let dati = Data(base64Encoded: b64, options: .ignoreUnknownCharacters), !dati.isEmpty else {
            call.reject("Il file è vuoto", "VUOTO")
            return
        }
        let mime = call.getString("mime") ?? "application/pdf"
        let nome = StampaSalvaPlugin.nomeFile(call.getString("nome"), mime: mime)
        let cartella = FileManager.default.temporaryDirectory.appendingPathComponent("Quota120-condivisi", isDirectory: true)
        let url = cartella.appendingPathComponent(nome)
        do {
            try? FileManager.default.removeItem(at: cartella)      // i file mandati prima non servono più
            try FileManager.default.createDirectory(at: cartella, withIntermediateDirectories: true)
            try dati.write(to: url, options: .atomic)
        } catch {
            call.reject("Non riesco a preparare il file", "SCRITTURA", error)
            return
        }
        DispatchQueue.main.async {
            guard let vc = self.bridge?.viewController else {
                call.reject("La scelta non si apre", "NO_VIEW")
                return
            }
            let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let pop = av.popoverPresentationController {         // iPad: la scelta parte dal fondo dello schermo
                pop.sourceView = vc.view
                pop.sourceRect = CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.maxY - 60, width: 1, height: 1)
                pop.permittedArrowDirections = [.down]
            }
            var finita = false
            av.completionWithItemsHandler = { tipo, fatto, _, _ in
                if finita { return }
                finita = true
                call.resolve(["completato": fatto, "attivita": tipo?.rawValue ?? ""])
            }
            var sopra = vc
            while let p = sopra.presentedViewController { sopra = p }
            sopra.present(av, animated: true)
        }
    }

    // MARK: - PDF A4 da una stampa HTML

    @objc func htmlInPdf(_ call: CAPPluginCall) {
        guard let html = call.getString("html"), !html.isEmpty else {
            call.reject("Niente da stampare", "VUOTO")
            return
        }
        DispatchQueue.main.async {
            if self.chiamataPdf != nil {
                call.reject("Sto già preparando un PDF", "OCCUPATO")
                return
            }
            guard let vista = self.bridge?.viewController?.view else {
                call.reject("Il PDF non si prepara", "NO_VIEW")
                return
            }
            let conf = WKWebViewConfiguration()
            conf.preferences.javaScriptCanOpenWindowsAutomatically = false
            // larghezza di un A4 a 96 punti per pollice, fuori dallo schermo
            let w = WKWebView(frame: CGRect(x: -3000, y: 0, width: 794, height: 1123), configuration: conf)
            w.navigationDelegate = self
            w.isUserInteractionEnabled = false
            vista.addSubview(w)
            self.webPdf = w
            self.chiamataPdf = call
            let scade = DispatchWorkItem { [weak self] in self?.fine(nil, "Il PDF ci mette troppo: riprova") }
            self.scadenzaPdf = scade
            DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: scade)
            w.loadHTMLString(html, baseURL: URL(string: "https://app.quota120.com/"))
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === webPdf else { return }
        // un attimo per le immagini e i QR disegnati
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.creaPdf(webView) }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === webPdf else { return }
        fine(nil, "La stampa non si prepara")
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === webPdf else { return }
        fine(nil, "La stampa non si prepara")
    }

    /// la stampa HTML resta dentro la pagina: niente collegamenti esterni nel foglio
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if webView === webPdf && navigationAction.navigationType == .linkActivated {
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    private func creaPdf(_ w: WKWebView) {
        guard w === webPdf, chiamataPdf != nil else { return }
        let r = UIPrintPageRenderer()
        r.addPrintFormatter(w.viewPrintFormatter(), startingAtPageAt: 0)
        r.setValue(NSValue(cgRect: carta), forKey: "paperRect")
        r.setValue(NSValue(cgRect: carta.insetBy(dx: margine, dy: margine)), forKey: "printableRect")
        let n = r.numberOfPages
        if n < 1 {
            fine(nil, "La stampa è vuota")
            return
        }
        let dati = NSMutableData()
        UIGraphicsBeginPDFContextToData(dati, carta, ["Creator": "Quota 120"])
        r.prepare(forDrawingPages: NSRange(location: 0, length: n))
        let bordi = UIGraphicsGetPDFContextBounds()
        for i in 0..<n {
            UIGraphicsBeginPDFPage()
            r.drawPage(at: i, in: bordi)
        }
        UIGraphicsEndPDFContext()
        fine((dati as Data).base64EncodedString(), nil, pagine: n)
    }

    private func fine(_ base64: String?, _ errore: String?, pagine: Int = 0) {
        scadenzaPdf?.cancel()
        scadenzaPdf = nil
        let call = chiamataPdf
        chiamataPdf = nil
        if let w = webPdf {
            w.navigationDelegate = nil
            w.stopLoading()
            w.removeFromSuperview()
        }
        webPdf = nil
        guard let c = call else { return }
        if let b = base64 {
            c.resolve(["base64": b, "pagine": pagine])
        } else {
            c.reject(errore ?? "Il PDF non si prepara", "PDF")
        }
    }

    // MARK: - pagine di un PDF come immagini (per il visore)

    @objc func pdfPagine(_ call: CAPPluginCall) {
        guard let b64 = call.getString("base64"),
              let dati = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
              let doc = PDFDocument(data: dati) else {
            call.reject("Il PDF non si apre", "PDF")
            return
        }
        let larghezza = CGFloat(Swift.max(300, Swift.min(call.getInt("larghezza") ?? 1200, 2000)))
        let max = Swift.max(1, Swift.min(call.getInt("max") ?? 20, 60))
        DispatchQueue.global(qos: .userInitiated).async {
            if doc.isLocked {
                call.reject("Il PDF è protetto da una password", "PROTETTO")
                return
            }
            var pagine: [[String: Any]] = []
            for i in 0..<Swift.min(doc.pageCount, max) {
                guard let p = doc.page(at: i) else { continue }
                var b = p.bounds(for: .mediaBox).size
                if p.rotation % 180 != 0 { b = CGSize(width: b.height, height: b.width) }
                if b.width < 1 || b.height < 1 { continue }
                let misura = CGSize(width: larghezza, height: (larghezza * b.height / b.width).rounded())
                let img = p.thumbnail(of: misura, for: .mediaBox)
                if let j = img.jpegData(compressionQuality: 0.8) {
                    pagine.append(["base64": j.base64EncodedString(), "w": Int(img.size.width), "h": Int(img.size.height)])
                }
            }
            call.resolve(["pagine": pagine, "totale": doc.pageCount])
        }
    }

    // MARK: - aiuti

    static func nomeFile(_ n: String?, mime: String) -> String {
        let vietati = CharacterSet(charactersIn: "/\\:?*\"<>|\n\r\t")
        var nome = (n ?? "").components(separatedBy: vietati).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if nome.isEmpty { nome = "Quota 120" }
        if nome.count > 90 { nome = String(nome.prefix(90)) }
        let est: String
        switch mime.lowercased() {
        case "application/pdf": est = "pdf"
        case "image/jpeg": est = "jpg"
        case "image/png": est = "png"
        case "image/webp": est = "webp"
        case "image/heic", "image/heif": est = "heic"
        case "text/plain": est = "txt"
        default: est = ""
        }
        let e = (nome as NSString).pathExtension.lowercased()
        if !est.isEmpty && e != est && !(est == "jpg" && e == "jpeg") {
            nome += "." + est
        }
        return nome
    }
}
