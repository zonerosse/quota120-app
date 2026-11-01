// Prepara le immagini di partenza per icone e schermata d'avvio (assets/*.png) dall'icona di Quota 120.
// Poi: npx capacitor-assets generate  (crea tutte le misure per iPhone, iPad e Android)
import sharp from 'sharp';
import { readFileSync } from 'node:fs';

const NOTTE = '#132A3A';
const src = readFileSync(new URL('../assets/icona-sorgente.svg', import.meta.url), 'utf8');
// il disegno senza lo sfondo arrotondato (iOS e Android arrotondano da soli)
const disegno = src.replace(/<rect width="120" height="120" rx="26" fill="#132A3A"\/>/, '');
if (disegno === src) throw new Error('icona-sorgente.svg: sfondo non trovato');
const svg = (lato, scala, sfondo) => Buffer.from(
  `<svg xmlns="http://www.w3.org/2000/svg" width="${lato}" height="${lato}" viewBox="0 0 120 120">` +
  (sfondo ? `<rect width="120" height="120" fill="${sfondo}"/>` : '') +
  `<g transform="translate(60 60) scale(${scala}) translate(-60 -60)">${disegno.replace(/^<svg[^>]*>|<\/svg>$/g, '')}</g></svg>`);

const out = new URL('../assets/', import.meta.url).pathname;
await sharp(svg(1024, 1, NOTTE)).flatten({ background: NOTTE }).png().toFile(out + 'icon-only.png');
await sharp(svg(1024, 0.62, null)).png().toFile(out + 'icon-foreground.png');
await sharp({ create: { width: 1024, height: 1024, channels: 3, background: NOTTE } }).png().toFile(out + 'icon-background.png');
// schermata d'avvio: fondo scuro e il segno al centro, piccolo
const segno = await sharp(svg(560, 1, NOTTE)).png().toBuffer();
for (const n of ['splash.png', 'splash-dark.png'])
  await sharp({ create: { width: 2732, height: 2732, channels: 3, background: NOTTE } })
    .composite([{ input: segno, gravity: 'center' }]).png().toFile(out + n);
console.log('immagini pronte in assets/');
