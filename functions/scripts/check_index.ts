import { initializeApp } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';

initializeApp();

const INDEX_COLLECTION = 'ticket_image_index';

async function main() {
  const db = getFirestore();

  const snap = await db.collection(INDEX_COLLECTION).orderBy('createdAt', 'desc').limit(5).get();

  console.log(`Index collection: ${INDEX_COLLECTION}`);
  console.log(`Top ${snap.size} docs:`);

  for (const doc of snap.docs) {
    const data = doc.data() as any;
    console.log(`- ${doc.id}`);
    console.log(`  path: ${data.path}`);
    console.log(`  bucket: ${data.bucket}`);
    console.log(`  createdAt: ${data.createdAt?.toDate?.()?.toISOString?.() ?? data.createdAt}`);
  }

  // Count (best-effort). Uses count() aggregation if available.
  const countSnap = await db.collection(INDEX_COLLECTION).count().get();
  console.log(`Total docs (server count): ${countSnap.data().count}`);
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
