import Foundation
import Capacitor
import UIKit
import AVFoundation

/// Quota 120 · «Leggi QR»
///
/// Fotocamera a tutto schermo con «← Indietro», il titolo e una riga di aiuto. Ogni QR letto va alla pagina
/// (evento «letto»): la pagina decide se è un'etichetta dei suoi droni (allora chiude e apre la scheda)
/// oppure scrive un avviso e la fotocamera resta aperta. Usa il lettore di QR di iOS (AVFoundation): nessuna libreria in più.
///
/// Metodi (window.Capacitor.Plugins.LeggiQR):
///   disponibile()                                -> { disponibile }
///   apri({ titolo?, indietro?, suggerimento? })  -> { aperto: true }    (permesso negato: errore «PERMESSO»)
///   avviso({ testo })                            -> {}                  messaggio sopra la fotocamera, per 3 secondi
///   chiudi()                                     -> {}
/// Eventi: «letto» { testo }, «chiuso» {} (quando si tocca «Indietro»)
@objc(LeggiQRPlugin)
public class LeggiQRPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "LeggiQRPlugin"
    public let jsName = "LeggiQR"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "disponibile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "apri", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "avviso", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "chiudi", returnType: CAPPluginReturnPromise)
    ]

    private var schermo: LeggiQRSchermo?
    private let msgPermesso = "Serve il permesso della fotocamera: Impostazioni › Quota 120 › Fotocamera"

    @objc func disponibile(_ call: CAPPluginCall) {
        call.resolve(["disponibile": AVCaptureDevice.default(for: .video) != nil])
    }

    @objc func apri(_ call: CAPPluginCall) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async { self.mostra(call) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    if ok { self.mostra(call) } else { call.reject(self.msgPermesso, "PERMESSO") }
                }
            }
        default:
            call.reject(msgPermesso, "PERMESSO")
        }
    }

    private func mostra(_ call: CAPPluginCall) {
        if schermo != nil {
            call.resolve(["aperto": true])
            return
        }
        guard AVCaptureDevice.default(for: .video) != nil else {
            call.reject("Su questo dispositivo la fotocamera non c’è", "NO_CAMERA")
            return
        }
        guard let vc = bridge?.viewController else {
            call.reject("La fotocamera non si apre", "NO_VIEW")
            return
        }
        let s = LeggiQRSchermo()
        s.titolo = call.getString("titolo") ?? "Leggi QR"
        s.indietro = call.getString("indietro") ?? "← Indietro"
        s.suggerimento = call.getString("suggerimento") ?? "Inquadra il QR dell’etichetta: si apre da solo."
        s.modalPresentationStyle = .fullScreen
        s.onLetto = { [weak self] t in self?.notifyListeners("letto", data: ["testo": t]) }
        s.onIndietro = { [weak self] in
            guard let self = self, let x = self.schermo else { return }
            self.schermo = nil
            x.dismiss(animated: true) { self.notifyListeners("chiuso", data: [:]) }
        }
        schermo = s
        var sopra: UIViewController = vc
        while let p = sopra.presentedViewController { sopra = p }
        sopra.present(s, animated: true) { call.resolve(["aperto": true]) }
    }

    @objc func avviso(_ call: CAPPluginCall) {
        let t = call.getString("testo") ?? ""
        DispatchQueue.main.async {
            self.schermo?.mostraAvviso(t)
            call.resolve()
        }
    }

    @objc func chiudi(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let s = self.schermo else {
                call.resolve()
                return
            }
            self.schermo = nil
            s.dismiss(animated: true) { call.resolve() }
        }
    }
}

/// lo schermo della fotocamera (stessi testi e colori dell'anteprima 128)
class LeggiQRSchermo: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var titolo = "Leggi QR"
    var indietro = "← Indietro"
    var suggerimento = ""
    var onLetto: ((String) -> Void)?
    var onIndietro: (() -> Void)?

    private let sessione = AVCaptureSession()
    private let codaCamera = DispatchQueue(label: "it.puntowebferrara.quota120.leggiqr")
    private var anteprima: AVCaptureVideoPreviewLayer?
    private let mirino = CAShapeLayer()
    private let avvisoL = UILabel()
    private var ultimo = ""
    private var ultimoT = Date.distantPast
    private var pausaFino = Date.distantPast
    private var nascondi: DispatchWorkItem?

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0x20 / 255.0, green: 0x26 / 255.0, blue: 0x2b / 255.0, alpha: 1)

        let lay = AVCaptureVideoPreviewLayer(session: sessione)
        lay.videoGravity = .resizeAspectFill
        view.layer.addSublayer(lay)
        anteprima = lay

        mirino.strokeColor = UIColor.white.cgColor
        mirino.fillColor = UIColor.clear.cgColor
        mirino.lineWidth = 4
        mirino.lineCap = .round
        view.layer.addSublayer(mirino)

        // in alto: «← Indietro» e il titolo
        let barra = UIView()
        barra.backgroundColor = UIColor(white: 0, alpha: 0.35)
        barra.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(barra)
        let b = UIButton(type: .system)
        b.setTitle(indietro, for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        b.layer.borderColor = UIColor(white: 1, alpha: 0.4).cgColor
        b.layer.borderWidth = 1
        b.layer.cornerRadius = 9
        b.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        b.accessibilityLabel = "Indietro"
        b.addTarget(self, action: #selector(tornaIndietro), for: .touchUpInside)
        b.translatesAutoresizingMaskIntoConstraints = false
        barra.addSubview(b)
        let t = UILabel()
        t.text = titolo
        t.textColor = .white
        t.font = .systemFont(ofSize: 17, weight: .bold)
        t.translatesAutoresizingMaskIntoConstraints = false
        barra.addSubview(t)

        // in basso: la riga di aiuto
        let piede = UILabel()
        piede.text = suggerimento
        piede.textColor = .white
        piede.font = .systemFont(ofSize: 16)
        piede.numberOfLines = 0
        piede.textAlignment = .center
        piede.translatesAutoresizingMaskIntoConstraints = false
        let fondo = UIView()
        fondo.backgroundColor = UIColor(white: 0, alpha: 0.35)
        fondo.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(fondo)
        fondo.addSubview(piede)

        // avviso (QR che non è un'etichetta dei tuoi droni)
        avvisoL.textColor = UIColor(red: 0x0F / 255.0, green: 0x1C / 255.0, blue: 0x26 / 255.0, alpha: 1)
        avvisoL.backgroundColor = .white
        avvisoL.font = .systemFont(ofSize: 16, weight: .semibold)
        avvisoL.numberOfLines = 0
        avvisoL.textAlignment = .center
        avvisoL.layer.cornerRadius = 10
        avvisoL.clipsToBounds = true
        avvisoL.alpha = 0
        avvisoL.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(avvisoL)

        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            barra.topAnchor.constraint(equalTo: view.topAnchor),
            barra.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            barra.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            b.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
            b.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 12),
            b.bottomAnchor.constraint(equalTo: barra.bottomAnchor, constant: -10),
            b.heightAnchor.constraint(greaterThanOrEqualToConstant: 42),
            t.leadingAnchor.constraint(equalTo: b.trailingAnchor, constant: 12),
            t.centerYAnchor.constraint(equalTo: b.centerYAnchor),
            t.trailingAnchor.constraint(lessThanOrEqualTo: g.trailingAnchor, constant: -12),
            fondo.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fondo.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fondo.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            piede.topAnchor.constraint(equalTo: fondo.topAnchor, constant: 14),
            piede.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            piede.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            piede.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -16),
            avvisoL.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 20),
            avvisoL.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -20),
            avvisoL.bottomAnchor.constraint(equalTo: fondo.topAnchor, constant: -16),
            avvisoL.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])

        codaCamera.async { self.preparaCamera() }
    }

    private func preparaCamera() {
        guard let dev = AVCaptureDevice.default(for: .video), let ingresso = try? AVCaptureDeviceInput(device: dev) else { return }
        sessione.beginConfiguration()
        if sessione.canSetSessionPreset(.high) { sessione.sessionPreset = .high }
        if sessione.canAddInput(ingresso) { sessione.addInput(ingresso) }
        let uscita = AVCaptureMetadataOutput()
        if sessione.canAddOutput(uscita) {
            sessione.addOutput(uscita)
            uscita.setMetadataObjectsDelegate(self, queue: .main)
            if uscita.availableMetadataObjectTypes.contains(.qr) { uscita.metadataObjectTypes = [.qr] }
        }
        sessione.commitConfiguration()
        if dev.isFocusModeSupported(.continuousAutoFocus), (try? dev.lockForConfiguration()) != nil {
            dev.focusMode = .continuousAutoFocus
            dev.unlockForConfiguration()
        }
        sessione.startRunning()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        anteprima?.frame = view.bounds
        orienta()
        // mirino: quattro angoli al centro
        let lato = min(240, min(view.bounds.width, view.bounds.height) * 0.62)
        let r = CGRect(x: view.bounds.midX - lato / 2, y: view.bounds.midY - lato / 2, width: lato, height: lato)
        let a = lato * 0.22
        let p = UIBezierPath()
        p.move(to: CGPoint(x: r.minX, y: r.minY + a)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + a, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - a, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + a))
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - a)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - a, y: r.maxY))
        p.move(to: CGPoint(x: r.minX + a, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - a))
        mirino.path = p.cgPath
    }

    /// iPad girato: l'immagine della fotocamera segue lo schermo
    private func orienta() {
        guard let c = anteprima?.connection else { return }
        let o = view.window?.windowScene?.interfaceOrientation ?? .portrait
        if #available(iOS 17.0, *) {
            let gradi: CGFloat
            switch o {
            case .landscapeLeft: gradi = 180
            case .landscapeRight: gradi = 0
            case .portraitUpsideDown: gradi = 270
            default: gradi = 90
            }
            if c.isVideoRotationAngleSupported(gradi) { c.videoRotationAngle = gradi }
        } else if c.isVideoOrientationSupported {
            switch o {
            case .landscapeLeft: c.videoOrientation = .landscapeLeft
            case .landscapeRight: c.videoOrientation = .landscapeRight
            case .portraitUpsideDown: c.videoOrientation = .portraitUpsideDown
            default: c.videoOrientation = .portrait
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        codaCamera.async { if self.sessione.isRunning { self.sessione.stopRunning() } }
    }

    @objc private func tornaIndietro() {
        onIndietro?()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let o = metadataObjects.first as? AVMetadataMachineReadableCodeObject, let t = o.stringValue, !t.isEmpty else { return }
        let ora = Date()
        if ora < pausaFino { return }
        if t == ultimo && ora.timeIntervalSince(ultimoT) < 2.5 { return }   // lo stesso QR ancora inquadrato
        ultimo = t
        ultimoT = ora
        pausaFino = ora.addingTimeInterval(1.0)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onLetto?(t)
    }

    func mostraAvviso(_ t: String) {
        nascondi?.cancel()
        avvisoL.text = "  " + t + "  "
        UIView.animate(withDuration: 0.2) { self.avvisoL.alpha = 1 }
        let n = DispatchWorkItem { [weak self] in UIView.animate(withDuration: 0.3) { self?.avvisoL.alpha = 0 } }
        nascondi = n
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: n)
    }
}
