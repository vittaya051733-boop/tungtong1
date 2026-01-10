import { initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore, Timestamp } from 'firebase-admin/firestore';
import { getMessaging } from 'firebase-admin/messaging';
import { logger } from 'firebase-functions';
import { onDocumentCreated, onDocumentUpdated } from 'firebase-functions/v2/firestore';
import { HttpsError, onCall } from 'firebase-functions/v2/https';
import * as functionsV1 from 'firebase-functions/v1';
import { defineSecret } from 'firebase-functions/params';
import crypto from 'crypto';
import nodemailer from 'nodemailer';

export {
  syncLatestLotteryPdf,
  syncLatestLotteryPdfHttp,
  backfillLastYearFromApi,
  backfillLastYearFromApiHttp,
  backfillLastYearPdfFromLotteryCo,
  backfillLastYearPdfFromLotteryCoHttp,
  completeLastYearToFullResultsHttp,
  completeFromExistingPdfsHttp,
  ingestLotteryPdfUploadHttp,
  debugGetLotteryDrawHttp,
} from './lottery_pdf_sync';

initializeApp();

const SUPPORT_CHATS_COLLECTION = 'support_chats';
const SUPPORT_MESSAGES_SUBCOLLECTION = 'messages';
const USERS_COLLECTION = 'users';
const APP_CONFIG_COLLECTION = 'app_config';
const APP_CONFIG_DOC = 'global';

const EMAIL_VERIFICATION_CODES_COLLECTION = 'email_verification_codes';

const SMTP_USER_SECRET = defineSecret('SMTP_USER');
const SMTP_PASS_SECRET = defineSecret('SMTP_PASS');

function requireAuthedUid(request: any): string {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError('unauthenticated', 'กรุณาเข้าสู่ระบบ');
  return uid;
}

function requireNonEmptyString(value: unknown, field: string): string {
  const v = String(value ?? '').trim();
  if (!v) throw new HttpsError('invalid-argument', `กรุณากรอก ${field}`);
  return v;
}

function getSmtpConfig() {
  // Defaults for Gmail SMTP; can be overridden via env vars.
  const host = String(process.env.SMTP_HOST ?? 'smtp.gmail.com').trim();
  const portRaw = String(process.env.SMTP_PORT ?? '465').trim();
  const fromEnv = String(process.env.SMTP_FROM ?? '').trim();

  const user = String(SMTP_USER_SECRET.value() ?? '').trim();
  const pass = String(SMTP_PASS_SECRET.value() ?? '').trim();
  const from = fromEnv || user;

  if (!user || !pass) {
    throw new HttpsError(
      'failed-precondition',
      'ยังไม่ได้ตั้งค่าอีเมลผู้ส่ง (ตั้งค่า Secrets: SMTP_USER และ SMTP_PASS)'
    );
  }

  const port = Number(portRaw);
  if (!Number.isFinite(port) || port <= 0) {
    throw new HttpsError('failed-precondition', 'SMTP_PORT ไม่ถูกต้อง');
  }

  if (!host) {
    throw new HttpsError('failed-precondition', 'SMTP_HOST ไม่ถูกต้อง');
  }

  return { host, port, user, pass, from };
}

function createTransport() {
  const cfg = getSmtpConfig();
  return nodemailer.createTransport({
    host: cfg.host,
    port: cfg.port,
    secure: cfg.port === 465,
    auth: {
      user: cfg.user,
      pass: cfg.pass,
    },
  });
}

function generateSixDigitCode(): string {
  const n = crypto.randomInt(0, 1000000);
  return String(n).padStart(6, '0');
}

function hashCode(code: string, salt: string): string {
  return crypto.createHash('sha256').update(`${code}:${salt}`, 'utf8').digest('hex');
}

function pickSupportBody(data: Record<string, unknown>): string {
  const type = String(data['type'] ?? 'text').trim().toLowerCase();
  if (type === 'image') return 'แอดมินส่งรูปภาพ';
  const text = String(data['text'] ?? '').trim();
  if (!text) return 'มีข้อความใหม่จากแอดมิน';
  return text.length > 140 ? `${text.slice(0, 140)}…` : text;
}

function isAdminReply(data: Record<string, unknown>, uid: string): boolean {
  const senderRole = String(data['senderRole'] ?? '').trim().toLowerCase();
  if (senderRole) return senderRole !== 'user';
  const senderUid = String(data['senderUid'] ?? '').trim();
  if (senderUid) return senderUid !== uid;
  // If senderUid is missing, it's most likely an admin/staff message.
  // (User messages are created by the client and include senderUid==uid.)
  return true;
}

function isAdminChatSummary(data: Record<string, unknown>): boolean {
  const role = String(data['lastSenderRole'] ?? '').trim().toLowerCase();
  if (role) return role !== 'user';
  // If role missing, assume admin to avoid silent failures.
  return true;
}

function pickChatSummaryBody(data: Record<string, unknown>): string {
  const preview = String(data['lastMessagePreview'] ?? '').trim();
  if (preview) return preview.length > 140 ? `${preview.slice(0, 140)}…` : preview;
  const last = String(data['lastMessage'] ?? '').trim();
  if (!last) return 'มีข้อความใหม่จากแอดมิน';
  return last.length > 140 ? `${last.slice(0, 140)}…` : last;
}

export const notifySupportReply = onDocumentCreated(
  {
    region: 'asia-southeast1',
    document: `${SUPPORT_CHATS_COLLECTION}/{uid}/${SUPPORT_MESSAGES_SUBCOLLECTION}/{messageId}`,
  },
  async (event) => {
    const uid = String(event.params.uid ?? '').trim();
    const messageId = String(event.params.messageId ?? '').trim();
    if (!uid) return;

    const snap = event.data;
    const data = (snap?.data() ?? {}) as Record<string, unknown>;

    // Safe debug logging to inspect which fields were provided by admin.
    const type = String(data['type'] ?? 'text').trim().toLowerCase();
    const senderRole = String(data['senderRole'] ?? '').trim();
    const senderUid = String(data['senderUid'] ?? '').trim();
    const text = String(data['text'] ?? '').trim();
    logger.info('Support message created', {
      uid,
      messageId,
      type,
      hasCreatedAt: 'createdAt' in data && data['createdAt'] != null,
      hasSenderRole: !!senderRole,
      hasSenderUid: !!senderUid,
      senderRole: senderRole ? senderRole : null,
      senderUid: senderUid ? senderUid : null,
      textPreview: text ? (text.length > 50 ? `${text.slice(0, 50)}…` : text) : null,
    });

    // Ensure admin-console created messages still work with client query orderBy('createdAt').
    // Only patch when it's not a user message.
    try {
      const senderUid = String(data['senderUid'] ?? '').trim();
      const isUserMessage = senderUid && senderUid === uid;
      if (!isUserMessage) {
        const patch: Record<string, unknown> = {};

        if (!('createdAt' in data) || data['createdAt'] == null) {
          patch['createdAt'] = Timestamp.now();
        }

        const senderRole = String(data['senderRole'] ?? '').trim();
        if (!senderRole) {
          patch['senderRole'] = 'admin';
        }

        if (Object.keys(patch).length > 0) {
          await getFirestore()
            .collection(SUPPORT_CHATS_COLLECTION)
            .doc(uid)
            .collection(SUPPORT_MESSAGES_SUBCOLLECTION)
            .doc(messageId)
            .set(patch, { merge: true });
        }
      }
    } catch (e) {
      logger.warn('Failed to patch support message fields', { uid, messageId, e });
    }

    if (!isAdminReply(data, uid)) return;

    const db = getFirestore();
    const userDoc = await db.collection(USERS_COLLECTION).doc(uid).get();
    const userData = (userDoc.data() ?? {}) as Record<string, unknown>;
    const rawTokens = userData['fcmTokens'];

    const tokens = Array.isArray(rawTokens)
      ? [...new Set(rawTokens.map((t) => String(t ?? '').trim()).filter(Boolean))]
      : [];

    if (tokens.length === 0) {
      logger.info('No FCM tokens for user', { uid });
      return;
    }

    logger.info('Preparing to send support reply push', {
      uid,
      tokenCount: tokens.length,
    });

    const body = pickSupportBody(data);

    const resp = await getMessaging().sendEachForMulticast({
      tokens: tokens.slice(0, 500),
      notification: {
        title: 'ข้อความจากแอดมิน',
        body,
      },
      data: {
        kind: 'support_reply',
        uid,
        messageId: messageId || '',
      },
    });

    // Remove invalid tokens to keep the list clean.
    const invalidTokens: string[] = [];
    resp.responses.forEach((r, idx) => {
      if (r.success) return;
      const code = (r.error as any)?.code ?? '';
      if (code === 'messaging/registration-token-not-registered' || code === 'messaging/invalid-registration-token') {
        invalidTokens.push(tokens[idx]);
      }
    });

    if (invalidTokens.length > 0) {
      try {
        await db.collection(USERS_COLLECTION).doc(uid).set(
          {
            fcmTokens: (tokens.filter((t) => !invalidTokens.includes(t))),
            fcmUpdatedAt: Timestamp.now(),
          },
          { merge: true }
        );
      } catch (e) {
        logger.warn('Failed to prune invalid FCM tokens', { uid, e });
      }
    }

    logger.info('Sent support reply push', {
      uid,
      messageId,
      successCount: resp.successCount,
      failureCount: resp.failureCount,
    });
  }
);

// Fallback trigger: some admin tools update support_chats/{uid} (lastMessage/lastMessageAt)
// without creating a document in messages/. This ensures push notifications still work.
export const notifySupportReplyFromChat = onDocumentUpdated(
  {
    region: 'asia-southeast1',
    document: `${SUPPORT_CHATS_COLLECTION}/{uid}`,
  },
  async (event) => {
    const uid = String(event.params.uid ?? '').trim();
    if (!uid) return;

    const before = (event.data?.before.data() ?? {}) as Record<string, unknown>;
    const after = (event.data?.after.data() ?? {}) as Record<string, unknown>;

    if (!isAdminChatSummary(after)) return;

    const afterAt = after['lastMessageAt'] as any;
    const beforeAt = before['lastMessageAt'] as any;
    const afterTs: Timestamp | null = afterAt instanceof Timestamp ? afterAt : null;
    const beforeTs: Timestamp | null = beforeAt instanceof Timestamp ? beforeAt : null;

    // Must have lastMessageAt and it must have advanced.
    if (!afterTs) return;
    if (beforeTs && afterTs.toMillis() <= beforeTs.toMillis()) return;

    // De-dup: store the last user-notified timestamp.
    const notifiedAtAny = after['userNotifiedAt'] as any;
    const notifiedTs: Timestamp | null = notifiedAtAny instanceof Timestamp ? notifiedAtAny : null;
    if (notifiedTs && afterTs.toMillis() <= notifiedTs.toMillis()) return;

    const db = getFirestore();
    const userDoc = await db.collection(USERS_COLLECTION).doc(uid).get();
    const userData = (userDoc.data() ?? {}) as Record<string, unknown>;
    const rawTokens = userData['fcmTokens'];

    const tokens = Array.isArray(rawTokens)
      ? [...new Set(rawTokens.map((t) => String(t ?? '').trim()).filter(Boolean))]
      : [];

    if (tokens.length === 0) {
      logger.info('No FCM tokens for user (chat summary)', { uid });
      return;
    }

    const body = pickChatSummaryBody(after);

    const resp = await getMessaging().sendEachForMulticast({
      tokens: tokens.slice(0, 500),
      notification: {
        title: 'ข้อความจากแอดมิน',
        body,
      },
      data: {
        kind: 'support_reply',
        uid,
        source: 'chat_summary',
        lastMessageAt: String(afterTs.toMillis()),
      },
    });

    // Mark notified so we don't spam on repeated updates.
    try {
      await db
        .collection(SUPPORT_CHATS_COLLECTION)
        .doc(uid)
        .set({ userNotifiedAt: afterTs }, { merge: true });
    } catch (e) {
      logger.warn('Failed to set userNotifiedAt', { uid, e });
    }

    logger.info('Sent support reply push (chat summary)', {
      uid,
      successCount: resp.successCount,
      failureCount: resp.failureCount,
    });
  }
);

export const sendEmailVerificationCode = onCall(
  {
    region: 'asia-southeast1',
    secrets: [SMTP_USER_SECRET, SMTP_PASS_SECRET],
  },
  async (request) => {
    const uid = requireAuthedUid(request);

    const auth = getAuth();
    const user = await auth.getUser(uid);
    const email = String(user.email ?? '').trim();
    if (!email) {
      throw new HttpsError('failed-precondition', 'บัญชีนี้ไม่มีอีเมล');
    }
    if (user.emailVerified) {
      return { sent: false, alreadyVerified: true };
    }

    const db = getFirestore();
    const ref = db.collection(EMAIL_VERIFICATION_CODES_COLLECTION).doc(uid);
    const snap = await ref.get();
    const data = (snap.data() ?? {}) as Record<string, unknown>;

    const now = Timestamp.now();
    const lastSentAtAny = data['lastSentAt'] as any;
    const lastSentAt = lastSentAtAny instanceof Timestamp ? lastSentAtAny : null;

    // Rate limit: 60 seconds.
    if (lastSentAt && now.toMillis() - lastSentAt.toMillis() < 60 * 1000) {
      throw new HttpsError('resource-exhausted', 'กรุณารอสักครู่ก่อนส่งรหัสอีกครั้ง');
    }

    const code = generateSixDigitCode();
    const salt = crypto.randomBytes(16).toString('base64');
    const codeHash = hashCode(code, salt);
    const expiresAt = Timestamp.fromMillis(now.toMillis() + 10 * 60 * 1000);

    await ref.set(
      {
        email,
        codeHash,
        salt,
        createdAt: now,
        lastSentAt: now,
        expiresAt,
        attempts: 0,
      },
      { merge: true }
    );

    const cfg = getSmtpConfig();
    const transport = createTransport();

    const subject = 'รหัสยืนยันอีเมล (Tungtong)';
    const text =
      `รหัสยืนยันอีเมลของคุณคือ: ${code}\n` +
      `รหัสนี้จะหมดอายุใน 10 นาที\n\n` +
      `หากคุณไม่ได้เป็นผู้ขอรหัสนี้ สามารถละเว้นอีเมลฉบับนี้ได้`;

    await transport.sendMail({
      from: cfg.from,
      to: email,
      subject,
      text,
    });

    logger.info('Sent email verification code', { uid, email });
    return { sent: true, expiresInSec: 10 * 60 };
  }
);

export const verifyEmailVerificationCode = onCall(
  {
    region: 'asia-southeast1',
    secrets: [SMTP_USER_SECRET, SMTP_PASS_SECRET],
  },
  async (request) => {
    const uid = requireAuthedUid(request);
    const code = requireNonEmptyString((request.data as any)?.code, 'รหัส 6 หลัก');

    if (!/^\d{6}$/.test(code)) {
      throw new HttpsError('invalid-argument', 'รหัสต้องเป็นตัวเลข 6 หลัก');
    }

    const auth = getAuth();
    const user = await auth.getUser(uid);
    const email = String(user.email ?? '').trim();
    if (!email) {
      throw new HttpsError('failed-precondition', 'บัญชีนี้ไม่มีอีเมล');
    }
    if (user.emailVerified) {
      return { verified: true, alreadyVerified: true };
    }

    const db = getFirestore();
    const ref = db.collection(EMAIL_VERIFICATION_CODES_COLLECTION).doc(uid);
    const snap = await ref.get();
    if (!snap.exists) {
      throw new HttpsError('failed-precondition', 'ยังไม่ได้ขอรหัสยืนยัน');
    }

    const data = (snap.data() ?? {}) as Record<string, unknown>;
    const storedEmail = String(data['email'] ?? '').trim();
    if (storedEmail && storedEmail !== email) {
      throw new HttpsError('failed-precondition', 'อีเมลมีการเปลี่ยนแปลง กรุณาขอรหัสใหม่');
    }

    const expiresAtAny = data['expiresAt'] as any;
    const expiresAt = expiresAtAny instanceof Timestamp ? expiresAtAny : null;
    if (!expiresAt) {
      throw new HttpsError('failed-precondition', 'ข้อมูลรหัสไม่สมบูรณ์ กรุณาขอรหัสใหม่');
    }
    if (Timestamp.now().toMillis() > expiresAt.toMillis()) {
      throw new HttpsError('deadline-exceeded', 'รหัสหมดอายุ กรุณาขอรหัสใหม่');
    }

    const attempts = Number(data['attempts'] ?? 0);
    if (!Number.isFinite(attempts) || attempts >= 10) {
      throw new HttpsError('resource-exhausted', 'ลองผิดหลายครั้งเกินไป กรุณาขอรหัสใหม่');
    }

    const salt = String(data['salt'] ?? '').trim();
    const codeHash = String(data['codeHash'] ?? '').trim();
    if (!salt || !codeHash) {
      throw new HttpsError('failed-precondition', 'ข้อมูลรหัสไม่สมบูรณ์ กรุณาขอรหัสใหม่');
    }

    const candidate = hashCode(code, salt);
    if (candidate !== codeHash) {
      await ref.set({ attempts: attempts + 1 }, { merge: true });
      throw new HttpsError('invalid-argument', 'รหัสไม่ถูกต้อง');
    }

    await auth.updateUser(uid, { emailVerified: true });
    await ref.delete().catch(() => undefined);

    logger.info('Email verified via code', { uid, email });
    return { verified: true };
  }
);

const INDEX_COLLECTION = 'ticket_image_index';

// Keep this aligned with the Flutter app's known ticket prefixes.
const ALLOWED_PREFIXES = [
  'lottery_copy/ookaYaimgZVdw5zXAVpsY',
  'lottery_copy',
  'lottery',
];

function isImagePath(path: string): boolean {
  const p = path.toLowerCase();
  if (!p.includes('.')) return true;
  return (
    p.endsWith('.png') ||
    p.endsWith('.jpg') ||
    p.endsWith('.jpeg') ||
    p.endsWith('.webp')
  );
}

function matchesAllowedPrefix(path: string): boolean {
  return ALLOWED_PREFIXES.some((prefix) => path === prefix || path.startsWith(`${prefix}/`));
}

function docIdFromPath(path: string): string {
  return path.split('/').join('_');
}

function parseDigitsFromCopyImagePath(path: string): string | null {
  // Expected: lottery_copy/<uid>/<digits>_...jpg
  const m = /^lottery_copy\/[^/]+\/(\d+)_/i.exec(path);
  if (!m) return null;
  const digits = (m[1] ?? '').trim();
  if (!digits) return null;
  // Match client-side behavior: ignore placeholder values.
  if (digits === '000000') return null;
  return digits;
}

function copyImageStoragePathFromPath(path: string): string | null {
  return path.startsWith('lottery_copy/') ? path : null;
}

// Gen 1 trigger: avoids Eventarc bucket validation issues during deploy.
export const indexTicketImage = functionsV1
  .region('asia-southeast1')
  .storage
  .bucket('tungtong-addmin.firebasestorage.app')
  .object()
  .onFinalize(async (object: functionsV1.storage.ObjectMetadata) => {
    const path = (object.name ?? '').trim();

    if (!path) return;
    if (!matchesAllowedPrefix(path)) return;
    if (!isImagePath(path)) return;

    const bucket = object.bucket ?? '';
    // Defensive guard (even though the trigger is bucket-scoped).
    if (bucket !== 'tungtong-addmin.firebasestorage.app') return;
    const contentType = object.contentType ?? '';

    // timeCreated/updated are RFC3339 strings in metadata.
    const createdAt = object.timeCreated
      ? Timestamp.fromDate(new Date(object.timeCreated))
      : Timestamp.now();
    const updatedAt = object.updated
      ? Timestamp.fromDate(new Date(object.updated))
      : createdAt;

    const docId = docIdFromPath(path);
    const db = getFirestore();

    const copyImageStoragePath = copyImageStoragePathFromPath(path);
    const digits = copyImageStoragePath ? parseDigitsFromCopyImagePath(path) : null;

    await db.collection(INDEX_COLLECTION).doc(docId).set(
      {
        path,
        copyImageStoragePath,
        digits,
        bucket,
        contentType,
        createdAt,
        updatedAt,
        size: object.size ? Number(object.size) : null,
        generation: object.generation ?? null,
        metageneration: object.metageneration ?? null,
      },
      { merge: true }
    );

    logger.info('Indexed ticket image', { path, bucket, docId });
  });
