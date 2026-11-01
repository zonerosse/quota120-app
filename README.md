# Quota 120 · app per iPhone, iPad e Android

È la Quota 120 di sempre (https://app.quota120.com) dentro un'app da installare, più una cosa che il sito non può fare:
**su iPhone e iPad l'app legge da sola i voli di DJI Fly** da una cartella scelta una volta.

- L'app apre direttamente `https://app.quota120.com`: quando migliora Quota 120, l'app si aggiorna da sola,
  senza passare da App Store o Google Play. Serve una nuova versione nei negozi solo se cambia questa parte (il «guscio»).
- Fatta con [Capacitor](https://capacitorjs.com) 8. Nome «Quota 120», identificativo `it.puntowebferrara.quota120`.
- Dentro l'app si aprono solo gli indirizzi di Quota 120 (`app.`, `prova.`, `quota120.com`, `www.`).
  Tutto il resto (WhatsApp, Gmail, email, telefono, ENAC, D-Flight…) si apre fuori, nel browser o nell'app giusta.
- Senza internet compare la pagina «Quota 120 non si apre» con il tasto «Riprova» (`www/errore.html`).

## Cosa c'è in questo repository (è PUBBLICO)

| Cartella | Cosa |
|---|---|
| `capacitor.config.json` | indirizzo di Quota 120, indirizzi ammessi, colori, barra di stato |
| `ios/` | progetto Xcode (iPhone e iPad) |
| `android/` | progetto Android (Android 7.0 e successivi, `minSdk` 24) |
| `plugins/cartella-voli/` | il pezzo nativo «Collega i voli di DJI Fly» (Swift per iPhone/iPad; su Android risponde «non disponibile») |
| `www/` | solo la pagina «senza internet» e l'icona |
| `assets/`, `strumenti/icone.mjs` | icona e schermata d'avvio (`npm run icone` le rigenera dall'icona di Quota 120) |
| `.github/workflows/` | le costruzioni automatiche |

Il repository è pubblico perché così GitHub Actions è gratis (anche i Mac). Per questo qui **non ci sono e non devono mai
esserci**: chiavi, password, certificati, dati delle persone, il codice del server di Quota 120 (che resta nel suo
repository privato). Le chiavi di Apple e Google vanno SOLO nei «Secrets» di GitHub di questo repository.
I flussi partono solo con un push su `main` o a mano (mai dalle proposte di modifica di altri) e non stampano mai i segreti.

## La cartella dei voli (iPhone e iPad)

1. In Home del pilota compare il riquadro **«Collega i voli di DJI Fly»** (solo nell'app su iPhone/iPad).
2. «Scegli la cartella» › **Sul mio iPhone › DJI Fly › FlightRecords** › Apri. Si fa una volta sola.
   L'app ricorda la cartella con un «segnalibro di sicurezza» di iOS (resta valido anche dopo il riavvio).
3. Da lì «Carica i voli di oggi» legge la cartella e manda **solo i voli nuovi** (riconosciuti da nome, dimensione e data;
   l'elenco dei già mandati resta nell'app) dalla stessa strada di sempre (`/api/arrivi`), poi Quota 120 li legge e salva.
4. Si cambia in Account › «Il mio telefono» › «Cartella dei voli».

Metodi del plugin (`window.Capacitor.Plugins.CartellaVoli`): `statoCartella()`, `scegliCartella()`,
`leggiNuovi({dopo, max, maxByte})` → `{file:[{nome, base64, dimensione, data, chiave}], altri}`, `segnaInviati({chiavi})`, `scollega()`.
Al massimo 10 file e 20 MB per volta (la pagina richiama finché ce ne sono); file oltre 30 MB saltati (limite del server).

**Android:** DJI Fly tiene i voli in `Android/data`, che Android non lascia leggere alle altre app. Lì il plugin risponde
`{disponibile:false}` e tutto resta come oggi (scelta dei file o «Condividi › Quota 120»).

## Le costruzioni (GitHub Actions)

- **Android** (`android.yml`, a ogni push): `app-debug.apk` e `app-release.apk` (firmato con la chiave di prova:
  si installa sul telefono, ma non va su Google Play). Artefatto «quota120-android-apk».
- **iPhone e iPad** (`ios.yml`, a ogni push): costruzione per il simulatore e per l'iPhone vero senza firma, poi l'app
  si apre nel simulatore di iPhone e di iPad e si fotografa lo schermo (artefatto «quota120-ios-schermate»).
  L'app per il simulatore è nell'artefatto «quota120-ios-simulatore-app».
- **TestFlight**: Actions › «iPhone e iPad» › Run workflow › spunta «testflight». Parte solo se ci sono i 4 segreti di Apple.

## Cosa deve fare il titolare, più avanti

### App Store (TestFlight)
1. In App Store Connect: App › «+» › Nuova app › nome **Quota 120**, Bundle ID **it.puntowebferrara.quota120**
   (se non compare, lancia una volta il flusso con «testflight»: registra il Bundle ID da solo con la chiave API).
2. Chiave API: App Store Connect › Utenti e accessi › Integrazioni › Chiavi dell'API (ruolo «App Manager»): scarica il file `.p8`.
3. In GitHub, in QUESTO repository: Settings › Secrets and variables › Actions › New repository secret:
   `APPLE_TEAM_ID` (Team ID), `ASC_KEY_ID` (ID della chiave), `ASC_ISSUER_ID` (Issuer ID), `ASC_KEY_P8` (tutto il testo del file `.p8`).
4. Actions › «iPhone e iPad» › Run workflow › spunta «testflight».

### Google Play
1. Account sviluppatore Google Play (25 $ una volta). Gli account personali nuovi devono fare un **test chiuso con almeno
   12 tester per 14 giorni** di fila prima di poter pubblicare.
2. Chiave di firma dell'app (keystore): si crea una volta e si conserva per sempre. In GitHub, segreti di questo repository:
   `ANDROID_KEYSTORE_B64` (il file .jks in base64), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`.
   Da lì il flusso Android produce anche il pacchetto `.aab` firmato (artefatto «quota120-android-aab») da caricare in Play Console.

### Avvisi sul telefono (notifiche) – DA FARE
Il plugin `@capacitor/push-notifications` è già nell'app, ma il tasto «Attiva gli avvisi» NON c'è ancora: servono
- iPhone/iPad: chiave APNs (Apple Developer › Keys) e la capacità «Push Notifications» sull'identificativo dell'app;
- Android: progetto Firebase con il file `google-services.json` (mai in questo repository: va messo dal flusso dai segreti);
- server di Quota 120: salvare i «token» dei telefoni e mandare gli avvisi (scadenze, lavori nuovi, piloti da approvare).
Finché manca, Apple può mandare un'email di avviso «Missing Push Notification Entitlement» quando arriva una build: non blocca niente.

## Rischi da sapere

- **Regola 4.2 di Apple** (app che sono solo un sito «impacchettato»): Apple può rifiutarla. Per questo conta il pezzo nativo:
  la cartella dei voli di DJI Fly letta da sola (il sito non può farlo), e poi gli avvisi sul telefono. Nella scheda per la
  revisione di Apple va spiegato e va dato un account di prova (prova.quota120.com, codice Admin di prova).
- Su iPhone dentro l'app non c'è il service worker (WKWebView non lo permette alle app normali): Quota 120 senza rete
  funziona solo finché l'app resta aperta.
- Documenti, stampe ed etichette QR che il sito apre in una «finestra nuova» vuota (`window.open('')`): nell'app su iPhone
  la finestra nuova non c'è. Da sistemare nel sito prima della revisione di Apple (vedi il resoconto).
