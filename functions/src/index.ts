import { initializeApp } from 'firebase-admin/app';
import { getFirestore, Timestamp } from 'firebase-admin/firestore';
import { getMessaging } from 'firebase-admin/messaging';
import { logger } from 'firebase-functions';
import { onDocumentCreated, onDocumentUpdated } from 'firebase-functions/v2/firestore';
import { HttpsError, onCall } from 'firebase-functions/v2/https';
import * as functionsV1 from 'firebase-functions/v1';

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
