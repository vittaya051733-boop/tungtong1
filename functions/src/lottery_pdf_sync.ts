import crypto from 'crypto';

import { getFirestore, Timestamp } from 'firebase-admin/firestore';
import { getStorage } from 'firebase-admin/storage';
import { logger } from 'firebase-functions';
import { onSchedule } from 'firebase-functions/v2/scheduler';
import { onRequest } from 'firebase-functions/v2/https';
import type { protos } from '@google-cloud/vision';

const REGION = 'asia-southeast1';
const COLLECTION = 'lottery_draws';
const LOTTERY_CO_PDF_BASE = 'https://cdn.lottery.co.th/lotto/pdf';
const OCR_OUTPUT_PREFIX = 'lottery_ocr_output';

type LotteryResultByPageResponse = {
  response?: {
    total?: number;
    lottery?: Array<{
      date?: string;
      data?: unknown;
    }>;
  };
};

type LatestLotteryResponse = {
  response?: {
    date?: string;
    youtube_url?: string;
    pdf_url?: string;
    data?: unknown;
  };
};

type LotteryResultResponse = {
  response?: {
    date?: string;
    pdf_url?: string;
    data?: unknown;
  };
};

type PrizeBlock = {
  price?: string;
  number?: Array<{ value?: string }>;
};

type LatestLotteryData = {
  first?: PrizeBlock;
  near1?: PrizeBlock;
  second?: PrizeBlock;
  third?: PrizeBlock;
  fourth?: PrizeBlock;
  fifth?: PrizeBlock;
  last2?: PrizeBlock;
  last3f?: PrizeBlock;
  last3b?: PrizeBlock;
};

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function asLatestLotteryData(value: unknown): LatestLotteryData | null {
  if (!isObject(value)) return null;
  return value as LatestLotteryData;
}

function toBahtInt(price: string | undefined): number | null {
  if (!price) return null;
  const normalized = String(price).replace(/,/g, '').trim();
  if (!normalized) return null;
  const n = Number.parseFloat(normalized);
  if (!Number.isFinite(n)) return null;
  return Math.round(n);
}

function prizeValues(block?: PrizeBlock): string[] {
  if (!block?.number || !Array.isArray(block.number)) return [];
  return block.number
    .map((n) => (typeof n?.value === 'string' ? n.value.trim() : ''))
    .filter((s) => s.length > 0);
}

function ensureIsoDate(value: unknown): string {
  if (typeof value !== 'string') throw new Error('Missing date');
  const trimmed = value.trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(trimmed)) {
    throw new Error(`Unexpected date format: ${trimmed}`);
  }
  return trimmed;
}

function isoDateFromDate(d: Date): string {
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, '0');
  const day = String(d.getUTCDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

function isoDateWithinOrAfter(dateIso: string, cutoffIso: string): boolean {
  // ISO dates compare lexicographically.
  return dateIso >= cutoffIso;
}

function extractStatPreviousData(data: unknown): {
  firstPrize: string | null;
  last3f: string[];
  last3b: string[];
  last2: string | null;
} {
  if (!isObject(data)) {
    return { firstPrize: null, last3f: [], last3b: [], last2: null };
  }
  const first = (data['first'] as unknown) ?? null;
  const last3f = (data['last3f'] as unknown) ?? null;
  const last3b = (data['last3b'] as unknown) ?? null;
  const last2 = (data['last2'] as unknown) ?? null;

  const firstPrize = Array.isArray(first) && typeof first[0] === 'string' ? String(first[0]).trim() : null;
  const front3 = Array.isArray(last3f)
    ? last3f.filter((x) => typeof x === 'string').map((s) => String(s).trim()).filter(Boolean)
    : [];
  const back3 = Array.isArray(last3b)
    ? last3b.filter((x) => typeof x === 'string').map((s) => String(s).trim()).filter(Boolean)
    : [];
  const last2Value = Array.isArray(last2) && typeof last2[0] === 'string' ? String(last2[0]).trim() : null;

  return {
    firstPrize,
    last3f: front3.slice(0, 2),
    last3b: back3.slice(0, 2),
    last2: last2Value,
  };
}

async function fetchLotteryResultByPage(page: number): Promise<Array<{ date: string; data: unknown }>> {
  const resp = await fetch('https://www.glo.or.th/api/lottery/getLotteryResultByPage', {
    method: 'POST',
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ page }),
  });

  if (!resp.ok) {
    throw new Error(`getLotteryResultByPage HTTP ${resp.status}`);
  }

  const payload = (await resp.json()) as LotteryResultByPageResponse;
  const list = payload.response?.lottery;
  if (!Array.isArray(list)) return [];

  const out: Array<{ date: string; data: unknown }> = [];
  for (const item of list) {
    if (!item) continue;
    try {
      const date = ensureIsoDate(item.date);
      out.push({ date, data: item.data });
    } catch {
      // ignore
    }
  }
  return out;
}

function lastPathSegment(url: string): string {
  const parts = url.split('/').filter(Boolean);
  return parts.length ? parts[parts.length - 1] : '';
}

function toDmyFromIso(dateIso: string): { date: string; month: string; year: string } {
  const iso = ensureIsoDate(dateIso);
  const [y, m, d] = iso.split('-');
  return { date: d, month: m, year: y };
}

function readStringArray(v: unknown): string[] {
  if (!Array.isArray(v)) return [];
  return v
    .map((x) => (typeof x === 'string' ? x.trim() : ''))
    .filter((s) => s.length > 0);
}

function buildApiResults(apiData: LatestLotteryData | null): {
  firstPrize: string | null;
  adjacentFirst: string[];
  prize2: string[];
  prize3: string[];
  prize4: string[];
  prize5: string[];
  last3f: string[];
  last3b: string[];
  last2: string | null;
  amounts: Record<string, number | null>;
} | null {
  if (!apiData) return null;
  return {
    firstPrize: prizeValues(apiData.first)[0] ?? null,
    adjacentFirst: prizeValues(apiData.near1),
    prize2: prizeValues(apiData.second),
    prize3: prizeValues(apiData.third),
    prize4: prizeValues(apiData.fourth),
    prize5: prizeValues(apiData.fifth),
    last3f: prizeValues(apiData.last3f).slice(0, 2),
    last3b: prizeValues(apiData.last3b).slice(0, 2),
    last2: prizeValues(apiData.last2)[0] ?? null,
    amounts: {
      first: toBahtInt(apiData.first?.price),
      near1: toBahtInt(apiData.near1?.price),
      second: toBahtInt(apiData.second?.price),
      third: toBahtInt(apiData.third?.price),
      fourth: toBahtInt(apiData.fourth?.price),
      fifth: toBahtInt(apiData.fifth?.price),
      last3: toBahtInt(apiData.last3b?.price),
      last3f: toBahtInt(apiData.last3f?.price),
      last2: toBahtInt(apiData.last2?.price),
    },
  };
}

function sha256Hex(buf: Buffer): string {
  return crypto.createHash('sha256').update(buf).digest('hex');
}

function hasLikelyPrizeDigits(text: string): boolean {
  const t = String(text ?? '');
  // Heuristic: must contain at least one 6-digit and one Thai prize keyword.
  return /\d{6}/.test(t) && /(รางวัลที่\s*1|เลขหน้า\s*3\s*ตัว|เลขท้าย\s*2\s*ตัว)/.test(t);
}

function gcsUriForBucketObject(bucketName: string, objectPath: string): string {
  const clean = String(objectPath ?? '').replace(/^\/+/, '');
  return `gs://${bucketName}/${clean}`;
}

function ocrOutputPrefixFor(dateIso: string, pdfHash: string): string {
  // Keep output location deterministic to avoid re-OCR for same file.
  return `${OCR_OUTPUT_PREFIX}/${dateIso}/${pdfHash}/`;
}

async function readOcrTextFromOutput(bucketName: string, prefix: string): Promise<string> {
  const bucket = getStorage().bucket(bucketName);
  const [files] = await bucket.getFiles({ prefix });
  const jsonFiles = files.filter((f) => f.name.endsWith('.json'));
  if (!jsonFiles.length) return '';

  // Concatenate pages in order by filename.
  jsonFiles.sort((a, b) => a.name.localeCompare(b.name));
  let out = '';
  for (const file of jsonFiles) {
    const [buf] = await file.download();
    const payload = JSON.parse(buf.toString('utf8')) as {
      responses?: Array<{ fullTextAnnotation?: { text?: string } }>;
    };
    const text = payload?.responses?.[0]?.fullTextAnnotation?.text;
    if (typeof text === 'string' && text.trim()) {
      out += `\n${text.trim()}\n`;
    }
  }
  return out.trim();
}

async function ocrPdfFromGcs(opts: {
  bucketName: string;
  objectPath: string;
  dateIso: string;
  pdfHash: string;
}): Promise<string> {
  const inputUri = gcsUriForBucketObject(opts.bucketName, opts.objectPath);
  const outputPrefix = ocrOutputPrefixFor(opts.dateIso, opts.pdfHash);
  const outputUri = gcsUriForBucketObject(opts.bucketName, outputPrefix);

  // Lazy-load heavy dependency to keep function cold-start / deploy analysis fast.
  const { ImageAnnotatorClient } = await import('@google-cloud/vision');
  const client = new ImageAnnotatorClient();

  const request: protos.google.cloud.vision.v1.IAsyncBatchAnnotateFilesRequest = {
    requests: [
      {
        inputConfig: {
          gcsSource: { uri: inputUri },
          mimeType: 'application/pdf',
        },
        features: [{ type: 'DOCUMENT_TEXT_DETECTION' }],
        outputConfig: {
          gcsDestination: { uri: outputUri },
          batchSize: 5,
        },
      },
    ],
  };

  // This can take tens of seconds depending on PDF size.
  const [operation] = await client.asyncBatchAnnotateFiles(request);
  await operation.promise();

  return await readOcrTextFromOutput(opts.bucketName, outputPrefix);
}

function pickUnique<T>(items: T[]): T[] {
  const seen = new Set<T>();
  const out: T[] = [];
  for (const item of items) {
    if (seen.has(item)) continue;
    seen.add(item);
    out.push(item);
  }
  return out;
}

function normalizePdfText(text: string): string {
  // Make regex parsing more reliable across different PDF encoders.
  const s = String(text ?? '')
    .replace(/\r/g, '\n')
    .replace(/\u00a0/g, ' ')
    .replace(/[ \t]+/g, ' ')
    // OCR sometimes inserts spaces inside digit runs (e.g. "730 209").
    .replace(/(\d)\s+(?=\d)/g, '$1')
    .replace(/\n{3,}/g, '\n\n')
    .trim();

  return s;
}

function clampUnique(items: string[], expected: number): string[] {
  return pickUnique(items).slice(0, expected);
}

function findAfterHeadingNumbers(
  normalizedText: string,
  heading: RegExp,
  digitRe: RegExp,
  expected: number
): string[] {
  const m = heading.exec(normalizedText);
  if (!m || m.index == null) return [];
  const startIndex = m.index + m[0].length;
  const slice = normalizedText.slice(startIndex);
  const nums = slice.match(digitRe) ?? [];
  return clampUnique(nums.map((s) => s.trim()).filter(Boolean), expected);
}

function lotteryCoPageUrl(dateIso: string): string {
  const [yRaw, mRaw, dRaw] = dateIso.split('-');
  const y = Number(yRaw);
  const m = Number(mRaw);
  const d = Number(dRaw);
  const buddhistYear = buddhistYearFromGregorian(y);
  const yy = String(buddhistYear % 100).padStart(2, '0');
  const dd = String(d).padStart(2, '0');
  const mm = String(m).padStart(2, '0');
  return `https://www.lottery.co.th/lotto/${dd}-${mm}-${yy}`;
}

function htmlToText(html: string): string {
  return String(html ?? '')
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<br\s*\/?\s*>/gi, '\n')
    .replace(/<\/p>/gi, '\n')
    .replace(/<\/tr>/gi, '\n')
    .replace(/<\/td>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/[ \t]+/g, ' ')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

async function fetchLotteryCoDrawPageText(dateIso: string): Promise<string> {
  const url = lotteryCoPageUrl(dateIso);
  const resp = await fetch(url, {
    method: 'GET',
    headers: { Accept: 'text/html,*/*' },
  });
  if (!resp.ok) {
    throw new Error(`lottery.co.th draw page HTTP ${resp.status}`);
  }
  const html = await resp.text();
  return normalizePdfText(htmlToText(html));
}

function extract6DigitsInSection(
  normalizedText: string,
  start: RegExp,
  endCandidates: RegExp[]
): string[] {
  const startMatch = start.exec(normalizedText);
  if (!startMatch || startMatch.index == null) return [];

  const startIndex = startMatch.index + startMatch[0].length;
  let endIndex = normalizedText.length;
  for (const endRe of endCandidates) {
    const m = endRe.exec(normalizedText);
    if (!m || m.index == null) continue;
    if (m.index > startIndex && m.index < endIndex) endIndex = m.index;
  }

  const slice = normalizedText.slice(startIndex, endIndex);
  const nums = slice.match(/\d{6}/g) ?? [];
  return pickUnique(nums.map((s) => s.trim()).filter(Boolean));
}

function extractAdjacentFirst(normalizedText: string): string[] {
  // Usually two 6-digit numbers.
  const section = extract6DigitsInSection(
    normalizedText,
    /รางวัลข้างเคียง\s*รางวัลที่\s*1/,
    [
      /รางวัลที่\s*2/,
      /รางวัลที่\s*3/,
      /เลขหน้า\s*3\s*ตัว/,
      /เลขท้าย\s*3\s*ตัว/,
      /เลขท้าย\s*2\s*ตัว/,
    ]
  );
  return section.slice(0, 2);
}

// NOTE: keep parsing intentionally conservative (only fields we need for checking).
function parseResultsFromPdfText(text: string): {
  firstPrize: string | null;
  last3f: string[];
  last3b: string[];
  last2: string | null;
} {
  const normalized = normalizePdfText(text);

  const firstMatch = /รางวัลที่\s*1[\s\S]{0,250}?(\d{6})/.exec(normalized);
  const last3fMatch = /เลขหน้า\s*3\s*ตัว[\s\S]{0,250}?(\d{3})\s+(\d{3})/.exec(
    normalized
  );
  const last3bMatch = /เลขท้าย\s*3\s*ตัว[\s\S]{0,250}?(\d{3})\s+(\d{3})/.exec(
    normalized
  );
  const last2Match = /เลขท้าย\s*2\s*ตัว[\s\S]{0,120}?(\d{2})/.exec(normalized);

  const last3f = last3fMatch ? pickUnique([last3fMatch[1], last3fMatch[2]]) : [];
  const last3b = last3bMatch ? pickUnique([last3bMatch[1], last3bMatch[2]]) : [];

  return {
    firstPrize: firstMatch ? firstMatch[1] : null,
    last3f,
    last3b,
    last2: last2Match ? last2Match[1] : null,
  };
}

function parseFullResultsFromPdfText(text: string): {
  firstPrize: string | null;
  adjacentFirst: string[];
  prize2: string[];
  prize3: string[];
  prize4: string[];
  prize5: string[];
  last3f: string[];
  last3b: string[];
  last2: string | null;
} {
  const normalized = normalizePdfText(text);

  // More tolerant headings for OCR: sometimes Thai diacritics/spaces are lost.
  const rePrize1 = /รางวัล\s*ที่\s*1/;
  const reAdj = /รางวัลข้างเคียง\s*รางวัล\s*ที่\s*1/;
  const reLast2 = /เลขท้าย\s*2\s*ตัว/;
  const reFront3 = /เลขหน้า\s*3\s*ตัว/;
  const reBack3 = /เลขท้าย\s*3\s*ตัว/;
  const rePrize2 = /รางวัล\s*(?:ที่|ที|ท)\s*2/;
  const rePrize3 = /รางวัล\s*(?:ที่|ที|ท)\s*3/;
  const rePrize4 = /รางวัล\s*(?:ที่|ที|ท)\s*4/;
  const rePrize5 = /รางวัล\s*(?:ที่|ที|ท)\s*5/;

  const firstPrize = findAfterHeadingNumbers(normalized, rePrize1, /\d{6}/g, 1)[0] ?? null;
  const adjacentFirst = findAfterHeadingNumbers(normalized, reAdj, /\d{6}/g, 2);
  const last2 = findAfterHeadingNumbers(normalized, reLast2, /\d{2}/g, 1)[0] ?? null;
  const last3f = findAfterHeadingNumbers(normalized, reFront3, /\d{3}/g, 2);
  const last3b = findAfterHeadingNumbers(normalized, reBack3, /\d{3}/g, 2);

  const prize2 = findAfterHeadingNumbers(normalized, rePrize2, /\d{6}/g, 5);
  const prize3 = findAfterHeadingNumbers(normalized, rePrize3, /\d{6}/g, 10);
  const prize4 = findAfterHeadingNumbers(normalized, rePrize4, /\d{6}/g, 50);
  const prize5 = findAfterHeadingNumbers(normalized, rePrize5, /\d{6}/g, 100);

  // If headings are missing (some PDFs), fall back to old conservative core extraction.
  const core = parseResultsFromPdfText(normalized);

  return {
    firstPrize: firstPrize ?? core.firstPrize,
    last3f: last3f.length === 2 ? last3f : core.last3f,
    last3b: last3b.length === 2 ? last3b : core.last3b,
    last2: last2 ?? core.last2,
    adjacentFirst: adjacentFirst.length === 2 ? adjacentFirst : extractAdjacentFirst(normalized),
    prize2,
    prize3,
    prize4,
    prize5,
  };
}

function isLikelyFullPrizeSet(parsed: {
  adjacentFirst: string[];
  prize2: string[];
  prize3: string[];
  prize4: string[];
  prize5: string[];
  last3f: string[];
  last3b: string[];
  firstPrize: string | null;
  last2: string | null;
}): boolean {
  return !!(
    parsed.firstPrize &&
    parsed.last2 &&
    parsed.last3f.length === 2 &&
    parsed.last3b.length === 2 &&
    parsed.adjacentFirst.length === 2 &&
    parsed.prize2.length === 5 &&
    parsed.prize3.length === 10 &&
    parsed.prize4.length === 50 &&
    parsed.prize5.length === 100
  );
}

function isLikelyFullAmounts(amounts: unknown): boolean {
  if (!amounts || typeof amounts !== 'object') return false;
  const obj = amounts as Record<string, unknown>;
  const keys = ['first', 'near1', 'second', 'third', 'fourth', 'fifth', 'last3', 'last3f', 'last2'] as const;
  return keys.every((k) => typeof obj[k] === 'number' && Number.isFinite(obj[k] as number));
}

function pad2(n: number): string {
  return String(n).padStart(2, '0');
}

function extractDrawDateIsoFromThaiText(text: string): string | null {
  const normalized = normalizePdfText(text);
  const months: Record<string, number> = {
    'มกราคม': 1,
    'กุมภาพันธ์': 2,
    'มีนาคม': 3,
    'เมษายน': 4,
    'พฤษภาคม': 5,
    'มิถุนายน': 6,
    'กรกฎาคม': 7,
    'สิงหาคม': 8,
    'กันยายน': 9,
    'ตุลาคม': 10,
    'พฤศจิกายน': 11,
    'ธันวาคม': 12,
  };

  const re = /(งวดวันที่|ประจำงวดวันที่|ประกาศผลวันที่)\s*([0-3]?\d)\s*(มกราคม|กุมภาพันธ์|มีนาคม|เมษายน|พฤษภาคม|มิถุนายน|กรกฎาคม|สิงหาคม|กันยายน|ตุลาคม|พฤศจิกายน|ธันวาคม)\s*(\d{4})/;
  const m = re.exec(normalized);
  if (!m) return null;

  const day = Number(m[2]);
  const month = months[m[3]];
  let year = Number(m[4]);
  if (!Number.isFinite(day) || !Number.isFinite(month) || !Number.isFinite(year)) return null;

  // Thai PDFs typically use Buddhist Era years.
  if (year >= 2400) year -= 543;

  const iso = `${String(year).padStart(4, '0')}-${pad2(month)}-${pad2(day)}`;
  try {
    return ensureIsoDate(iso);
  } catch {
    return null;
  }
}

function buddhistYearFromGregorian(year: number): number {
  return year + 543;
}

function lotteryCoPdfCandidates(dateIso: string): Array<{ url: string; key: string }> {
  const [yRaw, mRaw, dRaw] = dateIso.split('-');
  const y = Number(yRaw);
  const m = Number(mRaw);
  const d = Number(dRaw);
  if (!Number.isFinite(y) || !Number.isFinite(m) || !Number.isFinite(d)) {
    return [];
  }

  const buddhistYear = buddhistYearFromGregorian(y);
  const yy = String(buddhistYear % 100).padStart(2, '0');
  const mm = String(m).padStart(2, '0');
  const dd = String(d).padStart(2, '0');

  // Observed modern pattern: YYMMDD.pdf (YY from Buddhist year)
  const yymmdd = `${yy}${mm}${dd}`;

  // Some older PDFs appear as DD-MM-YYYY(buddhist).pdf in sitemap.
  const ddmmyyyy = `${dd}-${mm}-${buddhistYear}`;

  return [
    { url: `${LOTTERY_CO_PDF_BASE}/${yymmdd}.pdf`, key: yymmdd },
    { url: `${LOTTERY_CO_PDF_BASE}/${ddmmyyyy}.pdf`, key: ddmmyyyy },
  ];
}

async function downloadFirstAvailablePdf(urls: Array<{ url: string; key: string }>): Promise<{
  url: string;
  key: string;
  bytes: Buffer;
}> {
  let lastErr: unknown = null;

  for (const candidate of urls) {
    try {
      const resp = await fetch(candidate.url, {
        method: 'GET',
        headers: { Accept: 'application/pdf,*/*' },
      });
      if (!resp.ok) {
        lastErr = new Error(`HTTP ${resp.status}`);
        continue;
      }

      const arr = new Uint8Array(await resp.arrayBuffer());
      const bytes = Buffer.from(arr);
      if (bytes.length < 10 || bytes.subarray(0, 4).toString('utf8') !== '%PDF') {
        lastErr = new Error('Downloaded content is not a PDF');
        continue;
      }

      return { url: candidate.url, key: candidate.key, bytes };
    } catch (e) {
      lastErr = e;
    }
  }

  throw new Error(`No PDF candidate worked: ${String((lastErr as Error | null)?.message ?? lastErr)}`);
}

async function fetchLatestLottery(): Promise<{
  date: string;
  pdfUrl: string;
  pdfId: string;
  youtubeUrl: string | null;
  data: LatestLotteryData | null;
}> {
  const resp = await fetch('https://www.glo.or.th/api/lottery/getLatestLottery', {
    method: 'POST',
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({}),
  });

  if (!resp.ok) {
    throw new Error(`getLatestLottery HTTP ${resp.status}`);
  }

  const payload = (await resp.json()) as LatestLotteryResponse;
  const date = ensureIsoDate(payload.response?.date);
  const pdfUrl = String(payload.response?.pdf_url ?? '').trim();
  if (!pdfUrl) throw new Error('Missing pdf_url');

  const pdfId = lastPathSegment(pdfUrl);
  if (!pdfId) throw new Error('Missing pdfId');

  const youtubeUrlRaw = payload.response?.youtube_url;
  const youtubeUrl = typeof youtubeUrlRaw === 'string' && youtubeUrlRaw.trim() ? youtubeUrlRaw.trim() : null;

  const data = asLatestLotteryData(payload.response?.data);

  return { date, pdfUrl, pdfId, youtubeUrl, data };
}

async function fetchLotteryResultByDateIso(dateIso: string): Promise<{
  date: string;
  pdfUrl: string | null;
  pdfId: string | null;
  data: LatestLotteryData | null;
}> {
  const dmy = toDmyFromIso(dateIso);
  const resp = await fetch('https://www.glo.or.th/api/lottery/getLotteryResult', {
    method: 'POST',
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(dmy),
  });

  if (!resp.ok) {
    throw new Error(`getLotteryResult HTTP ${resp.status}`);
  }

  const payload = (await resp.json()) as LotteryResultResponse;
  const date = ensureIsoDate(payload.response?.date ?? dateIso);
  const pdfUrlRaw = String(payload.response?.pdf_url ?? '').trim();
  const pdfUrl = pdfUrlRaw ? pdfUrlRaw : null;
  const pdfId = pdfUrl ? lastPathSegment(pdfUrl) || null : null;
  const data = asLatestLotteryData(payload.response?.data);
  return { date, pdfUrl, pdfId, data };
}

async function completeDrawResultsToFullSetOnce(dateIso: string, opts?: { force?: boolean; allowLotteryCoFallback?: boolean }): Promise<'updated' | 'skipped_full'> {
  const db = getFirestore();
  const docRef = db.collection(COLLECTION).doc(dateIso);
  const snap = await docRef.get();
  if (!snap.exists) return 'skipped_full';

  const results = (snap.get('results') ?? {}) as Record<string, unknown>;
  const parsed = {
    firstPrize: (typeof results['firstPrize'] === 'string' ? String(results['firstPrize']).trim() : null) || null,
    last2: (typeof results['last2'] === 'string' ? String(results['last2']).trim() : null) || null,
    last3f: readStringArray(results['last3f']),
    last3b: readStringArray(results['last3b']),
    adjacentFirst: readStringArray(results['adjacentFirst']),
    prize2: readStringArray(results['prize2']),
    prize3: readStringArray(results['prize3']),
    prize4: readStringArray(results['prize4']),
    prize5: readStringArray(results['prize5']),
  };

  const docHasFullPrizes = isLikelyFullPrizeSet(parsed);
  const docHasFullAmounts = isLikelyFullAmounts(snap.get('amounts'));
  // Skip only if BOTH prizes and amounts look complete.
  // Many draws may have full prize lists (from PDFs) but still miss amounts.
  if (docHasFullPrizes && docHasFullAmounts) return 'skipped_full';

  const force = !!opts?.force;
  const allowLotteryCoFallback = opts?.allowLotteryCoFallback !== false;

  try {
    const api = await fetchLotteryResultByDateIso(dateIso);
    const apiResults = buildApiResults(api.data);

    const merged = {
      firstPrize: apiResults?.firstPrize ?? parsed.firstPrize,
      last2: apiResults?.last2 ?? parsed.last2,
      last3f: apiResults?.last3f?.length ? apiResults.last3f : parsed.last3f,
      last3b: apiResults?.last3b?.length ? apiResults.last3b : parsed.last3b,
      adjacentFirst: apiResults?.adjacentFirst?.length ? apiResults.adjacentFirst : parsed.adjacentFirst,
      prize2: apiResults?.prize2?.length ? apiResults.prize2 : parsed.prize2,
      prize3: apiResults?.prize3?.length ? apiResults.prize3 : parsed.prize3,
      prize4: apiResults?.prize4?.length ? apiResults.prize4 : parsed.prize4,
      prize5: apiResults?.prize5?.length ? apiResults.prize5 : parsed.prize5,
    };

    const coreOk = !!(
      merged.firstPrize &&
      merged.last2 &&
      merged.last3f.length === 2 &&
      merged.last3b.length === 2
    );

    const mergedAmounts = apiResults?.amounts ?? (snap.get('amounts') ?? null);

    await docRef.set(
      {
        date: api.date,
        source: 'glo_pdf',
        updatedAt: Timestamp.now(),
        // Do not overwrite existing storagePath here; just attach official pdf_url/pdfId if missing.
        pdf: {
          ...(snap.get('pdf') ?? {}),
          pdfUrl: (snap.get('pdf.pdfUrl') ?? null) ? snap.get('pdf.pdfUrl') : api.pdfUrl,
          pdfId: (snap.get('pdf.pdfId') ?? null) ? snap.get('pdf.pdfId') : api.pdfId,
        },
        results: {
          firstPrize: merged.firstPrize,
          last3f: merged.last3f,
          last3b: merged.last3b,
          last2: merged.last2,
          adjacentFirst: merged.adjacentFirst,
          prize2: merged.prize2,
          prize3: merged.prize3,
          prize4: merged.prize4,
          prize5: merged.prize5,
        },
        amounts: mergedAmounts,
        parse: {
          ok: coreOk,
          warnings: [
            ...(merged.firstPrize ? [] : ['missing_firstPrize']),
            ...(merged.last2 ? [] : ['missing_last2']),
            ...(merged.last3f.length === 2 ? [] : ['missing_last3f']),
            ...(merged.last3b.length === 2 ? [] : ['missing_last3b']),
            ...(merged.adjacentFirst.length === 2 ? [] : ['missing_adjacentFirst']),
            ...(merged.prize2.length === 5 ? [] : ['missing_prize2']),
            ...(merged.prize3.length === 10 ? [] : ['missing_prize3']),
            ...(merged.prize4.length === 50 ? [] : ['missing_prize4']),
            ...(merged.prize5.length === 100 ? [] : ['missing_prize5']),
            ...(isLikelyFullAmounts(mergedAmounts) ? [] : ['missing_amounts']),
          ],
        },
      },
      { merge: true }
    );

    if (isLikelyFullPrizeSet({ ...merged })) {
      return 'updated';
    }

    if (allowLotteryCoFallback) {
      await backfillLastYearPdfFromLotteryCoOnce({ date: api.date, force: true, maxUpserts: 1, days: 2 });
      return 'updated';
    }

    return force ? 'updated' : 'updated';
  } catch (e) {
    if (allowLotteryCoFallback) {
      await backfillLastYearPdfFromLotteryCoOnce({ date: dateIso, force: true, maxUpserts: 1, days: 2 });
      return 'updated';
    }
    throw e;
  }
}

async function fetchPdfBase64(pdfId: string): Promise<string> {
  const resp = await fetch('https://www.glo.or.th/api/lottery/getPdfReader', {
    method: 'POST',
    headers: {
      Accept: 'application/json',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ url: pdfId }),
  });

  if (!resp.ok) {
    throw new Error(`getPdfReader HTTP ${resp.status}`);
  }

  const b64 = (await resp.text()).trim();
  if (!b64) throw new Error('Empty base64 response');
  return b64;
}

export async function syncLatestLotteryPdfOnce(): Promise<void> {
  const db = getFirestore();
  const bucket = getStorage().bucket();

  const latest = await fetchLatestLottery();

  const docRef = db.collection(COLLECTION).doc(latest.date);
  const existing = await docRef.get();
  if (existing.exists) {
    const existingPdfId = existing.get('pdf.pdfId');
    if (existingPdfId === latest.pdfId) {
      logger.info('Lottery PDF already synced', { date: latest.date, pdfId: latest.pdfId });
      return;
    }
  }

  const base64 = await fetchPdfBase64(latest.pdfId);
  const pdfBytes = Buffer.from(base64, 'base64');

  if (pdfBytes.length < 10 || pdfBytes.subarray(0, 4).toString('utf8') !== '%PDF') {
    throw new Error('Downloaded content is not a PDF');
  }

  const pdfHash = sha256Hex(pdfBytes);
  const storagePath = `lottery_pdfs/${latest.date}_${latest.pdfId}.pdf`;

  await bucket.file(storagePath).save(pdfBytes, {
    contentType: 'application/pdf',
    resumable: false,
    metadata: {
      cacheControl: 'private, max-age=0, no-transform',
      metadata: {
        sourcePdfUrl: latest.pdfUrl,
        pdfId: latest.pdfId,
        date: latest.date,
        sha256: pdfHash,
      },
    },
  });

  const { default: pdfParse } = await import('pdf-parse');
  const parsed = await pdfParse(pdfBytes);
  const pdfResults = parseResultsFromPdfText(parsed.text ?? '');

  // Also capture the structured prizes from getLatestLottery response (same source as the PDF).
  const apiData = latest.data;
  const apiResults = apiData
    ? {
        firstPrize: prizeValues(apiData.first)[0] ?? null,
        adjacentFirst: prizeValues(apiData.near1),
        prize2: prizeValues(apiData.second),
        prize3: prizeValues(apiData.third),
        prize4: prizeValues(apiData.fourth),
        prize5: prizeValues(apiData.fifth),
        last3f: prizeValues(apiData.last3f).slice(0, 2),
        last3b: prizeValues(apiData.last3b).slice(0, 2),
        last2: prizeValues(apiData.last2)[0] ?? null,
        amounts: {
          first: toBahtInt(apiData.first?.price),
          near1: toBahtInt(apiData.near1?.price),
          second: toBahtInt(apiData.second?.price),
          third: toBahtInt(apiData.third?.price),
          fourth: toBahtInt(apiData.fourth?.price),
          fifth: toBahtInt(apiData.fifth?.price),
          last3: toBahtInt(apiData.last3b?.price),
          last3f: toBahtInt(apiData.last3f?.price),
          last2: toBahtInt(apiData.last2?.price),
        },
      }
    : null;

  // Prefer structured API fields when present; fallback to PDF text parsing.
  const merged = {
    firstPrize: apiResults?.firstPrize ?? pdfResults.firstPrize,
    last3f: apiResults?.last3f?.length ? apiResults.last3f : pdfResults.last3f,
    last3b: apiResults?.last3b?.length ? apiResults.last3b : pdfResults.last3b,
    last2: apiResults?.last2 ?? pdfResults.last2,
    adjacentFirst: apiResults?.adjacentFirst ?? [],
    prize2: apiResults?.prize2 ?? [],
    prize3: apiResults?.prize3 ?? [],
    prize4: apiResults?.prize4 ?? [],
    prize5: apiResults?.prize5 ?? [],
  };

  await docRef.set(
    {
      date: latest.date,
      source: 'glo_pdf',
      updatedAt: Timestamp.now(),
      youtubeUrl: latest.youtubeUrl,
      pdf: {
        pdfUrl: latest.pdfUrl,
        pdfId: latest.pdfId,
        storagePath,
        sha256: pdfHash,
        size: pdfBytes.length,
      },
      results: {
        firstPrize: merged.firstPrize,
        last3f: merged.last3f,
        last3b: merged.last3b,
        last2: merged.last2,
        adjacentFirst: merged.adjacentFirst,
        prize2: merged.prize2,
        prize3: merged.prize3,
        prize4: merged.prize4,
        prize5: merged.prize5,
      },
      amounts: apiResults?.amounts ?? null,
      parse: {
        ok: !!(
          merged.firstPrize &&
          merged.last2 &&
          merged.last3f.length === 2 &&
          merged.last3b.length === 2
        ),
        warnings: [
          ...(merged.firstPrize ? [] : ['missing_firstPrize']),
          ...(merged.last2 ? [] : ['missing_last2']),
          ...(merged.last3f.length ? [] : ['missing_last3f']),
          ...(merged.last3b.length ? [] : ['missing_last3b']),
          ...(merged.adjacentFirst.length ? [] : ['missing_adjacentFirst']),
          ...(merged.prize2.length ? [] : ['missing_prize2']),
          ...(merged.prize3.length ? [] : ['missing_prize3']),
          ...(merged.prize4.length ? [] : ['missing_prize4']),
          ...(merged.prize5.length ? [] : ['missing_prize5']),
        ],
      },
    },
    { merge: true }
  );

  logger.info('Synced lottery PDF', {
    date: latest.date,
    pdfId: latest.pdfId,
    storagePath,
    sha256: pdfHash,
    parsedOk: !!(
      merged.firstPrize &&
      merged.last2 &&
      merged.last3f.length === 2 &&
      merged.last3b.length === 2
    ),
  });
}

export const syncLatestLotteryPdf = onSchedule(
  {
    region: REGION,
    schedule: 'every 30 minutes',
    timeZone: 'Asia/Bangkok',
  },
  async () => {
    await syncLatestLotteryPdfOnce();
  }
);

export async function backfillLastYearFromApiOnce(opts?: {
  days?: number;
  maxPages?: number;
  maxUpserts?: number;
}): Promise<{ processed: number; upserted: number; cutoffIso: string }> {
  const days = Math.max(1, Math.min(370, opts?.days ?? 366));
  const maxPages = Math.max(1, Math.min(60, opts?.maxPages ?? 6));
  const maxUpserts = Math.max(1, Math.min(500, opts?.maxUpserts ?? 60));

  const cutoff = new Date();
  cutoff.setUTCDate(cutoff.getUTCDate() - days);
  const cutoffIso = isoDateFromDate(cutoff);

  const db = getFirestore();

  let processed = 0;
  let upserted = 0;
  let reachedOlderThanCutoff = false;

  for (let page = 1; page <= maxPages; page++) {
    const items = await fetchLotteryResultByPage(page);
    if (!items.length) break;

    for (const item of items) {
      processed++;
      const dateIso = item.date;

      if (!isoDateWithinOrAfter(dateIso, cutoffIso)) {
        reachedOlderThanCutoff = true;
        continue;
      }

      const docRef = db.collection(COLLECTION).doc(dateIso);
      const existing = await docRef.get();
      const hasFirst = existing.exists && typeof existing.get('results.firstPrize') === 'string' && String(existing.get('results.firstPrize')).trim();
      const hasLast2 = existing.exists && typeof existing.get('results.last2') === 'string' && String(existing.get('results.last2')).trim();
      const hasPdf = existing.exists && !!existing.get('pdf.pdfId');

      const existingLast3f = existing.exists ? existing.get('results.last3f') : null;
      const existingLast3b = existing.exists ? existing.get('results.last3b') : null;
      const hasLast3f = Array.isArray(existingLast3f) && existingLast3f.filter((x) => typeof x === 'string' && String(x).trim()).length === 2;
      const hasLast3b = Array.isArray(existingLast3b) && existingLast3b.filter((x) => typeof x === 'string' && String(x).trim()).length === 2;
      const hasCore = !!(hasFirst && hasLast2 && hasLast3f && hasLast3b);

      // If core results are already present, skip (avoid endless rewrites).
      if (hasCore) {
        continue;
      }

      const extracted = extractStatPreviousData(item.data);
      if (!extracted.firstPrize || !extracted.last2) {
        continue;
      }

      await docRef.set(
        {
          date: dateIso,
          source: (() => {
            const current = existing.exists ? String(existing.get('source') ?? '').trim() : '';
            if (current === 'glo_pdf' || current === 'lottery_co_th_pdf') return current;
            return hasPdf ? 'glo_pdf' : 'glo_stat_previous';
          })(),
          updatedAt: Timestamp.now(),
          results: {
            firstPrize: extracted.firstPrize,
            last3f: extracted.last3f,
            last3b: extracted.last3b,
            last2: extracted.last2,
            // Note: stat-previous API does not include prizes 2–5/adjacent.
          },
          parse: {
            ok: !!(
              extracted.firstPrize &&
              extracted.last2 &&
              extracted.last3f.length === 2 &&
              extracted.last3b.length === 2
            ),
            warnings: [
              ...(extracted.firstPrize ? [] : ['missing_firstPrize']),
              ...(extracted.last2 ? [] : ['missing_last2']),
              ...(extracted.last3f.length ? [] : ['missing_last3f']),
              ...(extracted.last3b.length ? [] : ['missing_last3b']),
              ...(hasPdf ? [] : ['missing_pdf_for_draw']),
            ],
          },
        },
        { merge: true }
      );

      upserted++;
      if (upserted >= maxUpserts) {
        logger.info('Backfill reached maxUpserts', { upserted, processed, cutoffIso });
        return { processed, upserted, cutoffIso };
      }
    }

    if (reachedOlderThanCutoff) break;
  }

  logger.info('Backfill finished', { processed, upserted, cutoffIso });
  return { processed, upserted, cutoffIso };
}

export const backfillLastYearFromApi = onSchedule(
  {
    region: REGION,
    schedule: 'every day 03:30',
    timeZone: 'Asia/Bangkok',
  },
  async () => {
    await backfillLastYearFromApiOnce();
  }
);

export async function completeLastYearToFullResultsOnce(opts?: {
  days?: number;
  limitQuery?: number;
  maxUpserts?: number;
  force?: boolean;
  allowLotteryCoFallback?: boolean;
}): Promise<{ scanned: number; updated: number; skippedFull: number; failed: number; cutoffIso: string }> {
  const days = Math.max(1, Math.min(370, opts?.days ?? 366));
  const limitQuery = Math.max(10, Math.min(800, opts?.limitQuery ?? 400));
  const maxUpserts = Math.max(1, Math.min(800, opts?.maxUpserts ?? 200));
  const force = !!opts?.force;
  const allowLotteryCoFallback = opts?.allowLotteryCoFallback !== false;

  const cutoff = new Date();
  cutoff.setUTCDate(cutoff.getUTCDate() - days);
  const cutoffIso = isoDateFromDate(cutoff);

  const db = getFirestore();
  const snaps = await db
    .collection(COLLECTION)
    .where('date', '>=', cutoffIso)
    .orderBy('date', 'desc')
    .limit(limitQuery)
    .get();

  let scanned = 0;
  let updated = 0;
  let skippedFull = 0;
  let failed = 0;

  for (const doc of snaps.docs) {
    scanned++;
    const dateIso = ensureIsoDate(doc.get('date') ?? doc.id);
    try {
      const result = await completeDrawResultsToFullSetOnce(dateIso, { force, allowLotteryCoFallback });
      if (result === 'skipped_full') {
        skippedFull++;
      } else {
        updated++;
      }
    } catch (e) {
      failed++;
      logger.warn('Complete-to-full failed for draw', { dateIso, error: String((e as Error)?.message ?? e) });
    }

    if (updated >= maxUpserts) break;
  }

  return { scanned, updated, skippedFull, failed, cutoffIso };
}

export const completeLastYearToFullResultsHttp = onRequest(
  {
    region: REGION,
    timeoutSeconds: 3600,
    memory: '2GiB',
  },
  async (req, res) => {
    if (req.method !== 'POST') {
      res.status(405).json({ ok: false, error: 'Method Not Allowed' });
      return;
    }

    const days = Number(req.query.days ?? req.body?.days);
    const limitQuery = Number(req.query.limitQuery ?? req.body?.limitQuery);
    const maxUpserts = Number(req.query.maxUpserts ?? req.body?.maxUpserts);

    const forceRaw = String(req.query.force ?? req.body?.force ?? '').trim().toLowerCase();
    const force = forceRaw === '1' || forceRaw === 'true' || forceRaw === 'yes';
    const allowLotteryCoFallbackRaw = String(req.query.allowLotteryCoFallback ?? req.body?.allowLotteryCoFallback ?? '').trim().toLowerCase();
    const allowLotteryCoFallback = allowLotteryCoFallbackRaw ? !(allowLotteryCoFallbackRaw === '0' || allowLotteryCoFallbackRaw === 'false' || allowLotteryCoFallbackRaw === 'no') : true;

    try {
      const result = await completeLastYearToFullResultsOnce({
        days: Number.isFinite(days) ? days : undefined,
        limitQuery: Number.isFinite(limitQuery) ? limitQuery : undefined,
        maxUpserts: Number.isFinite(maxUpserts) ? maxUpserts : undefined,
        force,
        allowLotteryCoFallback,
      });
      res.json({ ok: true, ...result, force, allowLotteryCoFallback });
    } catch (e) {
      logger.error('completeLastYearToFullResultsHttp failed', e);
      res.status(500).json({ ok: false, error: 'complete_failed' });
    }
  }
);

export const backfillLastYearFromApiHttp = onRequest(
  {
    region: REGION,
  },
  async (req, res) => {
    if (req.method !== 'POST') {
      res.status(405).json({ ok: false, error: 'Method Not Allowed' });
      return;
    }

    const days = Number(req.query.days ?? req.body?.days);
    const maxPages = Number(req.query.maxPages ?? req.body?.maxPages);
    const maxUpserts = Number(req.query.maxUpserts ?? req.body?.maxUpserts);

    try {
      const result = await backfillLastYearFromApiOnce({
        days: Number.isFinite(days) ? days : undefined,
        maxPages: Number.isFinite(maxPages) ? maxPages : undefined,
        maxUpserts: Number.isFinite(maxUpserts) ? maxUpserts : undefined,
      });
      res.json({ ok: true, ...result });
    } catch (e) {
      logger.error('backfillLastYearFromApiHttp failed', e);
      res.status(500).json({ ok: false, error: 'backfill_failed' });
    }
  }
);

export const syncLatestLotteryPdfHttp = onRequest(
  {
    region: REGION,
  },
  async (req, res) => {
    if (req.method !== 'POST') {
      res.status(405).json({ ok: false, error: 'Method Not Allowed' });
      return;
    }

    try {
      await syncLatestLotteryPdfOnce();
      res.json({ ok: true });
    } catch (e) {
      logger.error('syncLatestLotteryPdfHttp failed', e);
      res.status(500).json({ ok: false, error: 'sync_failed' });
    }
  }
);

export async function backfillLastYearPdfFromLotteryCoOnce(opts?: {
  days?: number;
  maxUpserts?: number;
  limitQuery?: number;
  force?: boolean;
  date?: string;
}): Promise<{ scanned: number; upserted: number; cutoffIso: string }> {
  const days = Math.max(1, Math.min(370, opts?.days ?? 366));
  const maxUpserts = Math.max(1, Math.min(200, opts?.maxUpserts ?? 20));
  const limitQuery = Math.max(10, Math.min(500, opts?.limitQuery ?? 200));
  const force = !!opts?.force;
  const targetDateIso = opts?.date ? ensureIsoDate(normalizeDateInputToIso(String(opts.date))) : null;

  const cutoff = new Date();
  cutoff.setUTCDate(cutoff.getUTCDate() - days);
  const cutoffIso = isoDateFromDate(cutoff);

  const db = getFirestore();
  const bucket = getStorage().bucket();

  const docsToProcess = targetDateIso
    ? [await db.collection(COLLECTION).doc(targetDateIso).get()].filter((d) => d.exists)
    : (
        await db
          .collection(COLLECTION)
          .where('date', '>=', cutoffIso)
          .orderBy('date', 'desc')
          .limit(limitQuery)
          .get()
      ).docs;

  let scanned = 0;
  let upserted = 0;

  for (const doc of docsToProcess) {
    scanned++;
    const dateIso = ensureIsoDate(doc.get('date') ?? doc.id);

    const existingPdfId = doc.get('pdf.pdfId');
    const existingSource = String(doc.get('source') ?? '').trim();

    // Skip draws already synced from official GLO PDF unless forced.
    if (!force && existingPdfId && String(existingPdfId).trim()) {
      continue;
    }

    const prize2 = doc.get('results.prize2');
    const prize3 = doc.get('results.prize3');
    const prize4 = doc.get('results.prize4');
    const prize5 = doc.get('results.prize5');
    const adjacentFirst = doc.get('results.adjacentFirst');

    const hasAnyFull =
      (Array.isArray(prize2) && prize2.length > 0) ||
      (Array.isArray(prize3) && prize3.length > 0) ||
      (Array.isArray(prize4) && prize4.length > 0) ||
      (Array.isArray(prize5) && prize5.length > 0) ||
      (Array.isArray(adjacentFirst) && adjacentFirst.length > 0);

    if (!force && hasAnyFull) continue;

    try {
      const candidates = lotteryCoPdfCandidates(dateIso);
      if (!candidates.length) continue;

      const downloaded = await downloadFirstAvailablePdf(candidates);
      const pdfHash = sha256Hex(downloaded.bytes);

      const storagePath = `lottery_pdfs/${dateIso}_lotteryco_${downloaded.key}.pdf`;
      await bucket.file(storagePath).save(downloaded.bytes, {
        contentType: 'application/pdf',
        resumable: false,
        metadata: {
          cacheControl: 'private, max-age=0, no-transform',
          metadata: {
            sourcePdfUrl: downloaded.url,
            pdfId: `lotteryco:${downloaded.key}`,
            date: dateIso,
            sha256: pdfHash,
          },
        },
      });

      const { default: pdfParse } = await import('pdf-parse');
      const parsed = await pdfParse(downloaded.bytes);
      const parsedText = parsed.text ?? '';
      let parsedResults = parseFullResultsFromPdfText(parsedText);

      // If the PDF is image-based, pdf-parse may return only a header with no digits.
      // In that case, OCR from the stored PDF in GCS.
      if (!hasLikelyPrizeDigits(parsedText) || (!parsedResults.firstPrize && !parsedResults.last2)) {
        try {
          const ocrText = await ocrPdfFromGcs({
            bucketName: bucket.name,
            objectPath: storagePath,
            dateIso,
            pdfHash,
          });
          if (ocrText && ocrText.length > 50) {
            parsedResults = parseFullResultsFromPdfText(ocrText);
          }
        } catch (e) {
          logger.warn('OCR failed for PDF', { dateIso, storagePath, error: String((e as Error)?.message ?? e) });
        }
      }

      // If OCR is still imperfect (common for image-based PDFs), parse the draw web page.
      // The lottery.co.th page includes text tables with all prize lists.
      if (!isLikelyFullPrizeSet(parsedResults)) {
        try {
          const pageText = await fetchLotteryCoDrawPageText(dateIso);
          const fromPage = parseFullResultsFromPdfText(pageText);
          if (isLikelyFullPrizeSet(fromPage)) {
            parsedResults = fromPage;
          } else {
            // Keep best-effort: use whichever has more complete long lists.
            if (fromPage.prize5.length > parsedResults.prize5.length) parsedResults.prize5 = fromPage.prize5;
            if (fromPage.prize4.length > parsedResults.prize4.length) parsedResults.prize4 = fromPage.prize4;
            if (fromPage.prize3.length > parsedResults.prize3.length) parsedResults.prize3 = fromPage.prize3;
            if (fromPage.prize2.length > parsedResults.prize2.length) parsedResults.prize2 = fromPage.prize2;
            if (fromPage.adjacentFirst.length > parsedResults.adjacentFirst.length) parsedResults.adjacentFirst = fromPage.adjacentFirst;
          }
        } catch (e) {
          logger.warn('lottery.co.th page fallback failed', { dateIso, error: String((e as Error)?.message ?? e) });
        }
      }

      const docRef = db.collection(COLLECTION).doc(dateIso);
      await docRef.set(
        {
          date: dateIso,
          source: existingSource === 'glo_pdf' ? 'glo_pdf' : 'lottery_co_th_pdf',
          updatedAt: Timestamp.now(),
          pdf: {
            pdfUrl: downloaded.url,
            pdfId: `lotteryco:${downloaded.key}`,
            storagePath,
            sha256: pdfHash,
            size: downloaded.bytes.length,
          },
          results: {
            firstPrize: parsedResults.firstPrize,
            last3f: parsedResults.last3f,
            last3b: parsedResults.last3b,
            last2: parsedResults.last2,
            adjacentFirst: parsedResults.adjacentFirst,
            prize2: parsedResults.prize2,
            prize3: parsedResults.prize3,
            prize4: parsedResults.prize4,
            prize5: parsedResults.prize5,
          },
          parse: {
            ok: !!(
              parsedResults.firstPrize &&
              parsedResults.last2 &&
              parsedResults.last3f.length === 2 &&
              parsedResults.last3b.length === 2
            ),
            warnings: [
              ...(parsedResults.firstPrize ? [] : ['missing_firstPrize']),
              ...(parsedResults.last2 ? [] : ['missing_last2']),
              ...(parsedResults.last3f.length ? [] : ['missing_last3f']),
              ...(parsedResults.last3b.length ? [] : ['missing_last3b']),
              ...(parsedResults.adjacentFirst.length ? [] : ['missing_adjacentFirst']),
              ...(parsedResults.prize2.length ? [] : ['missing_prize2']),
              ...(parsedResults.prize3.length ? [] : ['missing_prize3']),
              ...(parsedResults.prize4.length ? [] : ['missing_prize4']),
              ...(parsedResults.prize5.length ? [] : ['missing_prize5']),
            ],
          },
        },
        { merge: true }
      );

      upserted++;
      logger.info('Backfilled lottery.co.th PDF', {
        date: dateIso,
        key: downloaded.key,
        url: downloaded.url,
        storagePath,
        upserted,
      });

      if (upserted >= maxUpserts) break;
    } catch (e) {
      logger.warn('Lottery.co.th PDF backfill failed for draw', { dateIso, error: String((e as Error)?.message ?? e) });
      continue;
    }
  }

  return { scanned, upserted, cutoffIso };
}

export const backfillLastYearPdfFromLotteryCo = onSchedule(
  {
    region: REGION,
    schedule: 'every day 04:05',
    timeZone: 'Asia/Bangkok',
  },
  async () => {
    await backfillLastYearPdfFromLotteryCoOnce();
  }
);

export const backfillLastYearPdfFromLotteryCoHttp = onRequest(
  {
    region: REGION,
    timeoutSeconds: 540,
    memory: '1GiB',
  },
  async (req, res) => {
    if (req.method !== 'POST') {
      res.status(405).json({ ok: false, error: 'Method Not Allowed' });
      return;
    }

    const days = Number(req.query.days ?? req.body?.days);
    const maxUpserts = Number(req.query.maxUpserts ?? req.body?.maxUpserts);
    const limitQuery = Number(req.query.limitQuery ?? req.body?.limitQuery);
    const date = String(req.query.date ?? req.body?.date ?? '').trim();
    const forceRaw = String(req.query.force ?? req.body?.force ?? '').trim().toLowerCase();
    const force = forceRaw === '1' || forceRaw === 'true' || forceRaw === 'yes';

    try {
      const result = await backfillLastYearPdfFromLotteryCoOnce({
        days: Number.isFinite(days) ? days : undefined,
        maxUpserts: Number.isFinite(maxUpserts) ? maxUpserts : undefined,
        limitQuery: Number.isFinite(limitQuery) ? limitQuery : undefined,
        date: date || undefined,
        force,
      });
      res.json({ ok: true, ...result });
    } catch (e) {
      logger.error('backfillLastYearPdfFromLotteryCoHttp failed', e);
      res.status(500).json({ ok: false, error: 'backfill_pdf_failed' });
    }
  }
);

export const ingestLotteryPdfUploadHttp = onRequest(
  {
    region: REGION,
    timeoutSeconds: 540,
    memory: '1GiB',
  },
  async (req, res) => {
    if (req.method !== 'POST') {
      res.status(405).json({ ok: false, error: 'Method Not Allowed' });
      return;
    }

    const dateRaw = String(req.query.date ?? req.body?.date ?? '').trim();
    const startRaw = String(req.query.start ?? req.body?.start ?? '').trim();
    const endRaw = String(req.query.end ?? req.body?.end ?? '').trim();
    const filename = String(req.query.filename ?? req.body?.filename ?? '').trim();
    const forceRaw = String(req.query.force ?? req.body?.force ?? '').trim().toLowerCase();
    const force = forceRaw === '1' || forceRaw === 'true' || forceRaw === 'yes';

    const pdfBase64Raw = String(req.body?.pdfBase64 ?? req.body?.pdf_base64 ?? '').trim();
    if (!pdfBase64Raw) {
      res.status(400).json({ ok: false, error: 'Missing pdfBase64' });
      return;
    }

    try {
      // Support data URLs: data:application/pdf;base64,...
      const b64 = pdfBase64Raw.includes('base64,')
        ? pdfBase64Raw.split('base64,').pop() ?? ''
        : pdfBase64Raw;

      const pdfBytes = Buffer.from(b64, 'base64');
      if (pdfBytes.length < 10 || pdfBytes.subarray(0, 4).toString('utf8') !== '%PDF') {
        res.status(400).json({ ok: false, error: 'Uploaded content is not a PDF' });
        return;
      }

      const { default: pdfParse } = await import('pdf-parse');
      const parsed = await pdfParse(pdfBytes);
      const parsedText = parsed.text ?? '';

      const detectedDate = extractDrawDateIsoFromThaiText(parsedText);
      const dateIso = dateRaw
        ? ensureIsoDate(normalizeDateInputToIso(dateRaw))
        : detectedDate;

      if (!dateIso) {
        res.status(400).json({
          ok: false,
          error: 'Missing date and could not auto-detect draw date from PDF',
        });
        return;
      }

      const startIso = startRaw ? ensureIsoDate(normalizeDateInputToIso(startRaw)) : null;
      const endIso = endRaw ? ensureIsoDate(normalizeDateInputToIso(endRaw)) : null;
      if (startIso && dateIso < startIso) {
        res.status(400).json({ ok: false, error: 'date_out_of_range', date: dateIso, start: startIso, end: endIso });
        return;
      }
      if (endIso && dateIso > endIso) {
        res.status(400).json({ ok: false, error: 'date_out_of_range', date: dateIso, start: startIso, end: endIso });
        return;
      }

      const db = getFirestore();
      const docRef = db.collection(COLLECTION).doc(dateIso);
      const existing = await docRef.get();
      if (!force && existing.exists) {
        const source = String(existing.get('source') ?? '').trim();
        const parseOk = !!existing.get('parse.ok');
        const pdfId = String(existing.get('pdf.pdfId') ?? '').trim();
        const hasPrize5 = Array.isArray(existing.get('results.prize5')) && (existing.get('results.prize5') as unknown[]).length > 0;
        if (source === 'glo_pdf' && parseOk && pdfId && hasPrize5) {
          res.json({ ok: true, skipped: true, reason: 'already_has_glo_pdf', date: dateIso });
          return;
        }
      }

      const bucket = getStorage().bucket();
      const pdfHash = sha256Hex(pdfBytes);
      const uploadId = pdfHash.slice(0, 12);
      const storagePath = `lottery_pdfs/${dateIso}_upload_${uploadId}.pdf`;

      await bucket.file(storagePath).save(pdfBytes, {
        contentType: 'application/pdf',
        resumable: false,
        metadata: {
          cacheControl: 'private, max-age=0, no-transform',
          metadata: {
            sourcePdfUrl: 'local_upload',
            pdfId: `upload:${uploadId}`,
            date: dateIso,
            sha256: pdfHash,
            originalFileName: filename || null,
          },
        },
      });

      let parsedResults = parseFullResultsFromPdfText(parsedText);

      // If the PDF is image-based or parsing is incomplete, OCR it using Vision.
      if (!hasLikelyPrizeDigits(parsedText) || !isLikelyFullPrizeSet(parsedResults)) {
        try {
          const ocrText = await ocrPdfFromGcs({
            bucketName: bucket.name,
            objectPath: storagePath,
            dateIso,
            pdfHash,
          });
          if (ocrText && ocrText.length > 50) {
            const fromOcr = parseFullResultsFromPdfText(ocrText);
            if (isLikelyFullPrizeSet(fromOcr) || !isLikelyFullPrizeSet(parsedResults)) {
              parsedResults = fromOcr;
            }
          }
        } catch (e) {
          logger.warn('OCR failed for uploaded PDF', { dateIso, storagePath, error: String((e as Error)?.message ?? e) });
        }
      }

      const coreOk = !!(
        parsedResults.firstPrize &&
        parsedResults.last2 &&
        parsedResults.last3f.length === 2 &&
        parsedResults.last3b.length === 2
      );

      await docRef.set(
        {
          date: dateIso,
          source: 'glo_pdf',
          updatedAt: Timestamp.now(),
          pdf: {
            pdfUrl: null,
            pdfId: `upload:${uploadId}`,
            storagePath,
            sha256: pdfHash,
            size: pdfBytes.length,
          },
          results: {
            firstPrize: parsedResults.firstPrize,
            last3f: parsedResults.last3f,
            last3b: parsedResults.last3b,
            last2: parsedResults.last2,
            adjacentFirst: parsedResults.adjacentFirst,
            prize2: parsedResults.prize2,
            prize3: parsedResults.prize3,
            prize4: parsedResults.prize4,
            prize5: parsedResults.prize5,
          },
          amounts: null,
          parse: {
            ok: coreOk,
            warnings: [
              ...(parsedResults.firstPrize ? [] : ['missing_firstPrize']),
              ...(parsedResults.last2 ? [] : ['missing_last2']),
              ...(parsedResults.last3f.length ? [] : ['missing_last3f']),
              ...(parsedResults.last3b.length ? [] : ['missing_last3b']),
              ...(parsedResults.adjacentFirst.length ? [] : ['missing_adjacentFirst']),
              ...(parsedResults.prize2.length ? [] : ['missing_prize2']),
              ...(parsedResults.prize3.length ? [] : ['missing_prize3']),
              ...(parsedResults.prize4.length ? [] : ['missing_prize4']),
              ...(parsedResults.prize5.length ? [] : ['missing_prize5']),
            ],
          },
        },
        { merge: true }
      );

      res.json({
        ok: true,
        date: dateIso,
        storagePath,
        hasFullPrizes: isLikelyFullPrizeSet(parsedResults),
      });
    } catch (e) {
      logger.error('ingestLotteryPdfUploadHttp failed', e);
      res.status(500).json({ ok: false, error: 'ingest_failed' });
    }
  }
);

function extractDateIsoFromStorageObjectName(objectName: string): string | null {
  const name = String(objectName ?? '');
  // Expected patterns:
  // - lottery_pdfs/YYYY-MM-DD_<...>.pdf
  // - lottery_pdfs/YYYY-MM-DD.pdf (if any)
  const m = /lottery_pdfs\/(\d{4}-\d{2}-\d{2})\b/.exec(name);
  if (!m) return null;
  try {
    return ensureIsoDate(m[1]);
  } catch {
    return null;
  }
}

async function extractDateIsoFromGcsCustomMetadata(file: any): Promise<string | null> {
  try {
    const [meta] = await file.getMetadata();
    const dateRaw = meta?.metadata?.date;
    if (typeof dateRaw !== 'string') return null;
    const trimmed = dateRaw.trim();
    if (!trimmed) return null;
    return ensureIsoDate(trimmed);
  } catch {
    return null;
  }
}

function pickMoreCompleteResults(a: ReturnType<typeof parseFullResultsFromPdfText>, b: ReturnType<typeof parseFullResultsFromPdfText>) {
  const score = (r: ReturnType<typeof parseFullResultsFromPdfText>) => {
    let s = 0;
    if (r.firstPrize) s += 3;
    if (r.last2) s += 2;
    if (r.last3f.length === 2) s += 2;
    if (r.last3b.length === 2) s += 2;
    if (r.adjacentFirst.length === 2) s += 2;
    s += Math.min(5, r.prize2.length) * 0.2;
    s += Math.min(10, r.prize3.length) * 0.1;
    s += Math.min(50, r.prize4.length) * 0.02;
    s += Math.min(100, r.prize5.length) * 0.01;
    return s;
  };
  return score(b) > score(a) ? b : a;
}

export async function completeFromExistingPdfsOnce(opts?: {
  prefix?: string;
  days?: number;
  limitFiles?: number;
  maxUpserts?: number;
  force?: boolean;
  reportOnly?: boolean;
  reportLimit?: number;
  onlyIfDocIncomplete?: boolean;
}): Promise<{
  scannedFiles: number;
  candidateDates: number;
  updated: number;
  skippedFull: number;
  skippedNoDate: number;
  failed: number;
  cutoffIso: string;
  report?: Array<{
    date: string;
    objectPath: string;
    docHasFullPrizes: boolean;
    docCounts: {
      adjacentFirst: number;
      prize2: number;
      prize3: number;
      prize4: number;
      prize5: number;
      last3f: number;
      last3b: number;
    };
  }>;
}> {
  const prefix = String(opts?.prefix ?? 'lottery_pdfs/').trim() || 'lottery_pdfs/';
  const days = Math.max(1, Math.min(370, opts?.days ?? 366));
  const limitFiles = Math.max(10, Math.min(2000, opts?.limitFiles ?? 800));
  const maxUpserts = Math.max(1, Math.min(800, opts?.maxUpserts ?? 200));
  const force = !!opts?.force;
  const reportOnly = !!opts?.reportOnly;
  const onlyIfDocIncomplete = opts?.onlyIfDocIncomplete !== false;
  const reportLimit = Math.max(1, Math.min(500, opts?.reportLimit ?? 100));

  const cutoff = new Date();
  cutoff.setUTCDate(cutoff.getUTCDate() - days);
  const cutoffIso = isoDateFromDate(cutoff);

  const db = getFirestore();
  const bucket = getStorage().bucket();

  const [files] = await bucket.getFiles({ prefix, maxResults: limitFiles });

  let scannedFiles = 0;
  let candidateDates = 0;
  let updated = 0;
  let skippedFull = 0;
  let skippedNoDate = 0;
  let failed = 0;
  const report: Array<{
    date: string;
    objectPath: string;
    docHasFullPrizes: boolean;
    docCounts: {
      adjacentFirst: number;
      prize2: number;
      prize3: number;
      prize4: number;
      prize5: number;
      last3f: number;
      last3b: number;
    };
  }> = [];

  for (const f of files) {
    scannedFiles++;
    let dateIso = extractDateIsoFromStorageObjectName(f.name);
    if (!dateIso) {
      dateIso = await extractDateIsoFromGcsCustomMetadata(f);
    }

    // Download + parse the PDF. If we still don't know the date, detect it from the PDF text.
    let pdfBytes: Buffer;
    try {
      const [buf] = await f.download();
      pdfBytes = buf;
    } catch (e) {
      failed++;
      logger.warn('Failed to download stored PDF', { objectPath: f.name, error: String((e as Error)?.message ?? e) });
      continue;
    }

    if (pdfBytes.length < 10 || pdfBytes.subarray(0, 4).toString('utf8') !== '%PDF') {
      failed++;
      logger.warn('Stored object is not a PDF', { objectPath: f.name });
      continue;
    }

    const pdfHash = sha256Hex(pdfBytes);
    const { default: pdfParse } = await import('pdf-parse');
    const parsed = await pdfParse(pdfBytes);
    const text = parsed.text ?? '';

    const detectedDateFromText = extractDrawDateIsoFromThaiText(text);
    if (detectedDateFromText) {
      dateIso = detectedDateFromText;
    }

    // If still missing date, OCR and try again.
    let ocrTextForDate = '';
    if (!dateIso) {
      try {
        ocrTextForDate = await ocrPdfFromGcs({
          bucketName: bucket.name,
          objectPath: f.name,
          dateIso: '0000-00-00',
          pdfHash,
        });
        const detectedFromOcr = extractDrawDateIsoFromThaiText(ocrTextForDate);
        if (detectedFromOcr) {
          dateIso = detectedFromOcr;
        }
      } catch (e) {
        logger.warn('OCR date detect failed for stored PDF', { objectPath: f.name, error: String((e as Error)?.message ?? e) });
      }
    }

    if (!dateIso) {
      skippedNoDate++;
      continue;
    }

    if (!isoDateWithinOrAfter(dateIso, cutoffIso)) {
      continue;
    }

    candidateDates++;

    const docRef = db.collection(COLLECTION).doc(dateIso);
    const snap = await docRef.get();
    if (!snap.exists) {
      // If the doc doesn't exist yet, we still allow creating it from the PDF.
    }

    const existingResults = (snap.exists ? (snap.get('results') ?? {}) : {}) as Record<string, unknown>;
    const existingParsed = {
      firstPrize: (typeof existingResults['firstPrize'] === 'string' ? String(existingResults['firstPrize']).trim() : null) || null,
      last2: (typeof existingResults['last2'] === 'string' ? String(existingResults['last2']).trim() : null) || null,
      last3f: readStringArray(existingResults['last3f']),
      last3b: readStringArray(existingResults['last3b']),
      adjacentFirst: readStringArray(existingResults['adjacentFirst']),
      prize2: readStringArray(existingResults['prize2']),
      prize3: readStringArray(existingResults['prize3']),
      prize4: readStringArray(existingResults['prize4']),
      prize5: readStringArray(existingResults['prize5']),
    };

    const docHasFullPrizes = isLikelyFullPrizeSet(existingParsed);
    if (reportOnly) {
      if (report.length < reportLimit) {
        report.push({
          date: dateIso,
          objectPath: f.name,
          docHasFullPrizes,
          docCounts: {
            adjacentFirst: existingParsed.adjacentFirst.length,
            prize2: existingParsed.prize2.length,
            prize3: existingParsed.prize3.length,
            prize4: existingParsed.prize4.length,
            prize5: existingParsed.prize5.length,
            last3f: existingParsed.last3f.length,
            last3b: existingParsed.last3b.length,
          },
        });
      }
      // Skip writes in report-only mode.
      continue;
    }

    if (!force && snap.exists && docHasFullPrizes) {
      skippedFull++;
      continue;
    }

    if (onlyIfDocIncomplete && snap.exists && docHasFullPrizes && !force) {
      skippedFull++;
      continue;
    }

    try {
      let results = parseFullResultsFromPdfText(text);

      if (!hasLikelyPrizeDigits(text) || !isLikelyFullPrizeSet(results)) {
        try {
          const ocrText = await ocrPdfFromGcs({
            bucketName: bucket.name,
            objectPath: f.name,
            dateIso,
            pdfHash,
          });
          if (ocrText && ocrText.length > 50) {
            const fromOcr = parseFullResultsFromPdfText(ocrText);
            results = pickMoreCompleteResults(results, fromOcr);
          }
        } catch (e) {
          logger.warn('OCR failed for stored PDF', { dateIso, objectPath: f.name, error: String((e as Error)?.message ?? e) });
        }
      }

      const merged = {
        firstPrize: results.firstPrize ?? existingParsed.firstPrize,
        last2: results.last2 ?? existingParsed.last2,
        last3f: results.last3f.length === 2 ? results.last3f : existingParsed.last3f,
        last3b: results.last3b.length === 2 ? results.last3b : existingParsed.last3b,
        adjacentFirst: results.adjacentFirst.length === 2 ? results.adjacentFirst : existingParsed.adjacentFirst,
        prize2: results.prize2.length ? results.prize2 : existingParsed.prize2,
        prize3: results.prize3.length ? results.prize3 : existingParsed.prize3,
        prize4: results.prize4.length ? results.prize4 : existingParsed.prize4,
        prize5: results.prize5.length ? results.prize5 : existingParsed.prize5,
      };

      const coreOk = !!(
        merged.firstPrize &&
        merged.last2 &&
        merged.last3f.length === 2 &&
        merged.last3b.length === 2
      );

      await docRef.set(
        {
          date: dateIso,
          source: (snap.exists ? (snap.get('source') ?? 'glo_pdf') : 'glo_pdf') as string,
          updatedAt: Timestamp.now(),
          pdf: {
            ...(snap.exists ? (snap.get('pdf') ?? {}) : {}),
            storagePath: f.name,
            sha256: (snap.exists && snap.get('pdf.sha256')) ? snap.get('pdf.sha256') : pdfHash,
            size: (snap.exists && snap.get('pdf.size')) ? snap.get('pdf.size') : pdfBytes.length,
          },
          results: {
            firstPrize: merged.firstPrize,
            last3f: merged.last3f,
            last3b: merged.last3b,
            last2: merged.last2,
            adjacentFirst: merged.adjacentFirst,
            prize2: merged.prize2,
            prize3: merged.prize3,
            prize4: merged.prize4,
            prize5: merged.prize5,
          },
          parse: {
            ok: coreOk,
            warnings: [
              ...(merged.firstPrize ? [] : ['missing_firstPrize']),
              ...(merged.last2 ? [] : ['missing_last2']),
              ...(merged.last3f.length === 2 ? [] : ['missing_last3f']),
              ...(merged.last3b.length === 2 ? [] : ['missing_last3b']),
              ...(merged.adjacentFirst.length === 2 ? [] : ['missing_adjacentFirst']),
              ...(merged.prize2.length === 5 ? [] : ['missing_prize2']),
              ...(merged.prize3.length === 10 ? [] : ['missing_prize3']),
              ...(merged.prize4.length === 50 ? [] : ['missing_prize4']),
              ...(merged.prize5.length === 100 ? [] : ['missing_prize5']),
            ],
          },
        },
        { merge: true }
      );

      updated++;
    } catch (e) {
      failed++;
      logger.warn('completeFromExistingPdfs failed', { dateIso, objectPath: f.name, error: String((e as Error)?.message ?? e) });
    }

    if (updated >= maxUpserts) break;
  }

  return {
    scannedFiles,
    candidateDates,
    updated,
    skippedFull,
    skippedNoDate,
    failed,
    cutoffIso,
    ...(reportOnly ? { report } : {}),
  };
}

export const completeFromExistingPdfsHttp = onRequest(
  {
    region: REGION,
    timeoutSeconds: 3600,
    memory: '2GiB',
  },
  async (req, res) => {
    if (req.method !== 'POST') {
      res.status(405).json({ ok: false, error: 'Method Not Allowed' });
      return;
    }

    const days = Number(req.query.days ?? req.body?.days);
    const limitFiles = Number(req.query.limitFiles ?? req.body?.limitFiles);
    const maxUpserts = Number(req.query.maxUpserts ?? req.body?.maxUpserts);
    const prefix = String(req.query.prefix ?? req.body?.prefix ?? '').trim();
    const reportOnlyRaw = String(req.query.reportOnly ?? req.body?.reportOnly ?? '').trim().toLowerCase();
    const reportOnly = reportOnlyRaw === '1' || reportOnlyRaw === 'true' || reportOnlyRaw === 'yes';
    const reportLimit = Number(req.query.reportLimit ?? req.body?.reportLimit);
    const onlyIfDocIncompleteRaw = String(req.query.onlyIfDocIncomplete ?? req.body?.onlyIfDocIncomplete ?? '').trim().toLowerCase();
    const onlyIfDocIncomplete = onlyIfDocIncompleteRaw
      ? !(onlyIfDocIncompleteRaw === '0' || onlyIfDocIncompleteRaw === 'false' || onlyIfDocIncompleteRaw === 'no')
      : true;
    const forceRaw = String(req.query.force ?? req.body?.force ?? '').trim().toLowerCase();
    const force = forceRaw === '1' || forceRaw === 'true' || forceRaw === 'yes';

    try {
      const result = await completeFromExistingPdfsOnce({
        days: Number.isFinite(days) ? days : undefined,
        limitFiles: Number.isFinite(limitFiles) ? limitFiles : undefined,
        maxUpserts: Number.isFinite(maxUpserts) ? maxUpserts : undefined,
        prefix: prefix || undefined,
        force,
        reportOnly,
        reportLimit: Number.isFinite(reportLimit) ? reportLimit : undefined,
        onlyIfDocIncomplete,
      });
      res.json({ ok: true, ...result, force, reportOnly, onlyIfDocIncomplete, prefix: prefix || 'lottery_pdfs/' });
    } catch (e) {
      logger.error('completeFromExistingPdfsHttp failed', e);
      res.status(500).json({ ok: false, error: 'complete_from_pdfs_failed' });
    }
  }
);

function normalizeDateInputToIso(input: string): string {
  const raw = String(input ?? '').trim();
  if (!raw) throw new Error('Missing date');
  const normalized = /^\d{4}\/\d{1,2}\/\d{1,2}$/.test(raw) ? raw.replace(/\//g, '-') : raw;
  if (/^\d{4}-\d{1,2}-\d{1,2}$/.test(normalized)) {
    const [yRaw, mRaw, dRaw] = normalized.split('-');
    let y = Number(yRaw);
    const m = Number(mRaw);
    const d = Number(dRaw);
    if (!Number.isFinite(y) || !Number.isFinite(m) || !Number.isFinite(d)) {
      throw new Error('Invalid date');
    }

    // Accept Thai Buddhist year inputs (e.g. 2568) by converting to Gregorian.
    if (y >= 2400) y -= 543;

    const iso = `${String(y).padStart(4, '0')}-${pad2(m)}-${pad2(d)}`;
    ensureIsoDate(iso);
    return iso;
  }
  throw new Error('Unsupported date format (use YYYY-MM-DD or YYYY/MM/DD)');
}

export const debugGetLotteryDrawHttp = onRequest(
  {
    region: REGION,
  },
  async (req, res) => {
    try {
      const dateRaw = String(req.query.date ?? req.body?.date ?? '').trim();
      const dateIso = normalizeDateInputToIso(dateRaw);

      const db = getFirestore();
      const snap = await db.collection(COLLECTION).doc(dateIso).get();
      if (!snap.exists) {
        res.status(404).json({ ok: false, error: 'not_found', date: dateIso });
        return;
      }

      const results = (snap.get('results') ?? {}) as Record<string, unknown>;
      const pdf = (snap.get('pdf') ?? {}) as Record<string, unknown>;
      const amounts = (snap.get('amounts') ?? null) as Record<string, unknown> | null;

      const listLen = (v: unknown) => (Array.isArray(v) ? v.length : 0);
      const nonEmptyString = (v: unknown) => (typeof v === 'string' && v.trim() ? v.trim() : null);

      const summary = {
        firstPrize: nonEmptyString(results['firstPrize']),
        last2: nonEmptyString(results['last2']),
        last3fCount: listLen(results['last3f']),
        last3bCount: listLen(results['last3b']),
        adjacentFirstCount: listLen(results['adjacentFirst']),
        prize2Count: listLen(results['prize2']),
        prize3Count: listLen(results['prize3']),
        prize4Count: listLen(results['prize4']),
        prize5Count: listLen(results['prize5']),
      };

      const amountKeys = ['first', 'near1', 'second', 'third', 'fourth', 'fifth', 'last3', 'last3f', 'last2'] as const;
      const missingAmountKeys = !amounts
        ? [...amountKeys]
        : amountKeys.filter((k) => typeof (amounts as Record<string, unknown>)[k] !== 'number');
      const hasFullAmounts = isLikelyFullAmounts(amounts);

      res.json({
        ok: true,
        date: dateIso,
        source: snap.get('source') ?? null,
        updatedAt: snap.get('updatedAt') ?? null,
        pdf: {
          pdfId: pdf['pdfId'] ?? null,
          pdfUrl: pdf['pdfUrl'] ?? null,
          storagePath: pdf['storagePath'] ?? null,
          sha256: pdf['sha256'] ?? null,
          size: pdf['size'] ?? null,
        },
        amounts: {
          hasFullAmounts,
          missingKeys: missingAmountKeys,
        },
        summary,
        hasFullPrizes: !!(
          summary.firstPrize &&
          summary.last2 &&
          summary.last3fCount === 2 &&
          summary.last3bCount === 2 &&
          summary.adjacentFirstCount > 0 &&
          summary.prize2Count > 0 &&
          summary.prize3Count > 0 &&
          summary.prize4Count > 0 &&
          summary.prize5Count > 0
        ),
      });
    } catch (e) {
      logger.error('debugGetLotteryDrawHttp failed', e);
      res.status(400).json({ ok: false, error: String((e as Error)?.message ?? e) });
    }
  }
);
