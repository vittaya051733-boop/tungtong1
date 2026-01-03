import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../cart_controller.dart';

class TicketReservation {
  static const String collection = 'ticket_cart_counts';
  static const Duration lockDuration = Duration(minutes: 15);

  static String docId({required String imagePath, String? ticketNumber}) {
    final key = (ticketNumber == null || ticketNumber.trim().isEmpty)
        ? imagePath
        : ticketNumber.trim();
    return key.replaceAll('/', '_');
  }

  static String? extractDigits6({required String displayName, String? imagePath}) {
    final m = RegExp(r'\d{6}').firstMatch(displayName);
    if (m != null) return m.group(0);

    final p = (imagePath ?? '').trim();
    if (p.isEmpty) return null;

    final last = p.split('/').last;
    final leading = RegExp(r'^(\d{6})(?=[^\d]|$)').firstMatch(last);
    if (leading != null) return leading.group(1);

    final any = RegExp(r'\d{6}').firstMatch(last);
    return any?.group(0);
  }

  static Future<void> releaseForItems({
    required List<CartItem> items,
    required String uid,
  }) async {
    for (final item in items) {
      final imagePath = (item.imagePath ?? '').trim();
      if (imagePath.isEmpty) continue;

      final digits6 = extractDigits6(
        displayName: item.displayName,
        imagePath: item.imagePath,
      );

      final ref = FirebaseFirestore.instance
          .collection(collection)
          .doc(docId(imagePath: imagePath, ticketNumber: digits6));

      try {
        await FirebaseFirestore.instance.runTransaction<void>((tx) async {
          final snap = await tx.get(ref);
          final data = snap.data();
          final lockedBy = (data == null)
              ? null
              : (data['lockedByUid'] as String?)?.trim();

          if (lockedBy != null && lockedBy.isNotEmpty && lockedBy != uid) {
            return;
          }

          tx.set(ref, <String, Object?>{
            'ticketNumber': digits6,
            'imagePath': imagePath,
            'addedCount': 0,
            'lastAddedAt': FieldValue.serverTimestamp(),
            'lastAddedUid': uid,
            'lastAction': 'release',
            'lockedByUid': FieldValue.delete(),
            'lockedUntil': FieldValue.delete(),
          }, SetOptions(merge: true));
        });
      } catch (_) {
        // Best-effort only.
      }
    }
  }

  static Future<List<CartItem>> reserveForItems({
    required List<CartItem> items,
    required String uid,
  }) async {
    final okItems = <CartItem>[];

    for (final item in items) {
      final imagePath = (item.imagePath ?? '').trim();
      if (imagePath.isEmpty) continue;

      final digits6 = extractDigits6(
        displayName: item.displayName,
        imagePath: item.imagePath,
      );

      final qty = item.quantity.clamp(1, 999999).toInt();
      final ref = FirebaseFirestore.instance
          .collection(collection)
          .doc(docId(imagePath: imagePath, ticketNumber: digits6));

      try {
        final reserved = await FirebaseFirestore.instance
            .runTransaction<bool>((tx) async {
          final snap = await tx.get(ref);
          final data = snap.data();

          final current = (data == null
                  ? 0
                  : (data['addedCount'] as num?)?.toInt() ?? 0)
              .clamp(0, 1 << 30);

          final lockedBy =
              (data == null) ? null : (data['lockedByUid'] as String?)?.trim();

          DateTime? lockedUntil;
          final lockedUntilRaw = (data == null) ? null : data['lockedUntil'];
          if (lockedUntilRaw is Timestamp) {
            lockedUntil = lockedUntilRaw.toDate();
          }

          if (lockedUntil == null) {
            final lastAddedAtRaw = (data == null) ? null : data['lastAddedAt'];
            if (lastAddedAtRaw is Timestamp) {
              lockedUntil = lastAddedAtRaw.toDate().add(lockDuration);
            }
          }

          final now = DateTime.now();
          final lockActive = current > 0 &&
              lockedUntil != null &&
              now.isBefore(lockedUntil);

          if (lockActive && lockedBy != null && lockedBy != uid) {
            return false;
          }

          tx.set(ref, <String, Object?>{
            'ticketNumber': digits6,
            'imagePath': imagePath,
            'addedCount': qty,
            'setCount': qty,
            'lockedByUid': uid,
            'lockedUntil': Timestamp.fromDate(now.add(lockDuration)),
            'lastAddedAt': FieldValue.serverTimestamp(),
            'lastAddedUid': uid,
            'lastAction': 'reserve',
          }, SetOptions(merge: true));

          return true;
        });

        if (reserved) {
          okItems.add(item);
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('reserveForItems failed: $e');
        }
      }
    }

    return okItems;
  }
}
