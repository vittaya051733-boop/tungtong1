import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'cart_controller.dart';
import 'cart_scope.dart';
import 'cart_entry_screen.dart';

class BuyLotteryScreen extends StatefulWidget {
  const BuyLotteryScreen({super.key});

  @override
  State<BuyLotteryScreen> createState() => _BuyLotteryScreenState();
}

enum BuyMode { all, single, set }

class _BuyLotteryScreenState extends State<BuyLotteryScreen> {
  final _digitControllers = List<TextEditingController>.generate(
    6,
    (_) => TextEditingController(),
  );
  final _digitFocusNodes = List<FocusNode>.generate(6, (_) => FocusNode());

  BuyMode _mode = BuyMode.all;
  int _bottomIndex = 0;

  static final bool _firebaseStorageSupported =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  static const int _pageSize = 10;

  // Optional fast-path: if you maintain a Firestore index collection for tickets,
  // the app will use it automatically (faster + ordered + paginates cleanly).
  // Schema (recommended): { path: string, createdAt: timestamp }
  static const String _firestoreIndexCollection = 'ticket_image_index';

  // Try the user's provided path first.
  static const List<String> _ticketImagePrefixes = <String>[
    'lottery_copy/ookaYaimgZVdw5zXAVpsY',
    'lottery_copy',
    'lottery',
  ];

  // Use the default Firebase app's Storage bucket (configured by
  // android/app/google-services.json and ios/Runner/GoogleService-Info.plist).
  late final FirebaseStorage _storage = FirebaseStorage.instance;

  // Admin-controlled switch (Firestore): read /app_config/global.isOpen.
  static const String _storeConfigCollection = 'app_config';
  static const String _storeConfigDoc = 'global';
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _storeConfigSub;
  bool _storeOpen = true;
  String _storeClosedMessage = 'ปิดร้านชั่วคราว';

  static int? _toInt(Object? value) {
    if (value is int) return value;
    if (value is double) return value.round();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static String? _extractLeadingDigits6FromImagePath(String imagePath) {
    final name = imagePath.split('/').last;
    final base = _TicketMetaCollection._baseNameNoExt(imagePath);
    final m1 = RegExp(r'^(\d{6})(?=[^\d]|$)').firstMatch(base);
    if (m1 != null && m1.group(1) != '000000') return m1.group(1);
    final m2 = RegExp(r'^(\d{6})(?=[^\d]|$)').firstMatch(name);
    if (m2 != null && m2.group(1) != '000000') return m2.group(1);
    return null;
  }

  bool _isUnderKnownTicketPrefix(String path) {
    final p = path.trim();
    if (p.isEmpty) return false;
    return _ticketImagePrefixes.any((prefix) => p == prefix || p.startsWith('$prefix/'));
  }

  Future<bool> _storageObjectExists(String path) async {
    final p = path.trim();
    if (p.isEmpty) return false;
    try {
      await _storage.ref(p).getMetadata();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _lotteryRecordExistsForPath(String path) async {
    final ticketNumber = _extractTicketNumberFromPath(path);
    final setCount = await _resolveSetCountFromLottery(
      imagePath: path,
      ticketNumber: ticketNumber,
    );
    return setCount != null;
  }

  Future<bool> _shouldDisplayIndexPath(String path) async {
    // Index entries are not authoritative; only show if Storage OR `lottery` confirms it.
    final p = path.trim();
    if (p.isEmpty) return false;
    if (!_isUnderKnownTicketPrefix(p)) return false;
    if (!_isImagePath(p)) return false;

    // Known phantom pattern from assets/non-ticket images.
    if (RegExp(r'(^|/)file_000000').hasMatch(p)) return false;

    if (await _storageObjectExists(p)) return true;
    return _lotteryRecordExistsForPath(p);
  }

  Future<int?> _fetchSetCountFromLotteryByDigits(String digits6) async {
    final digits = digits6.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(digits)) return null;

    final col = FirebaseFirestore.instance.collection('lottery');
    final results = <int>[];

    final q1 = await col.where('digits', isEqualTo: digits).limit(10).get();
    for (final d in q1.docs) {
      final v = _toInt(d.data()['setCount']);
      if (v != null) results.add(v);
    }

    final asInt = int.tryParse(digits);
    if (asInt != null) {
      final q2 = await col.where('digits', isEqualTo: asInt).limit(10).get();
      for (final d in q2.docs) {
        final v = _toInt(d.data()['setCount']);
        if (v != null) results.add(v);
      }
    }

    if (results.isEmpty) return null;
    results.sort();
    return results.last;
  }

  Future<int?> _resolveSetCountFromLottery({
    required String imagePath,
    required String? ticketNumber,
  }) async {
    // 1) Prefer explicit ticketNumber (6 digits).
    if (ticketNumber != null &&
        RegExp(r'^\d{6}$').hasMatch(ticketNumber.trim())) {
      final v = await _fetchSetCountFromLotteryByDigits(ticketNumber.trim());
      if (v != null) return v;
    }

    // 2) If filename starts with 6 digits, use that.
    final leading = _extractLeadingDigits6FromImagePath(imagePath);
    if (leading != null) {
      final v = await _fetchSetCountFromLotteryByDigits(leading);
      if (v != null) return v;
    }

    // 3) Try docId candidates (e.g. 715335_1766796200825_003).
    final col = FirebaseFirestore.instance.collection('lottery');
    for (final id in _lotteryDocIdCandidatesForImagePath(imagePath)) {
      final snap = await col.doc(id).get();
      final data = snap.data();
      if (data == null) continue;
      final setCount = _toInt(data['setCount']);
      final digits = (data['digits'] as String?)?.trim();
      if (digits != null && RegExp(r'^\d{6}$').hasMatch(digits)) {
        final v = await _fetchSetCountFromLotteryByDigits(digits);
        if (v != null) return v;
      }
      if (setCount != null) return setCount;
    }

    return null;
  }

  void _listenStoreConfig() {
    _storeConfigSub?.cancel();
    _storeConfigSub = FirebaseFirestore.instance
        .collection(_storeConfigCollection)
        .doc(_storeConfigDoc)
        .snapshots()
        .listen((snap) {
          final data = snap.data();
          final open = (data?['isOpen'] is bool)
              ? (data?['isOpen'] as bool)
              : ((data?['storeOpen'] is bool)
                    ? (data?['storeOpen'] as bool)
                    : true);
            final statusNote = (data?['statusNote'] as String?)?.trim();
            final msg = (data?['closedMessage'] as String?)?.trim();
            final note = (statusNote == null || statusNote.isEmpty) ? msg : statusNote;

          final wasOpen = _storeOpen;
          final shouldKickToHome = wasOpen && !open;

          if (!mounted) return;
          setState(() {
            _storeOpen = open;
            _storeClosedMessage = (note == null || note.isEmpty)
                ? 'ปิดร้านชั่วคราว'
                : note;
            if (!_storeOpen) {
              _randomPickedImagePath = null;
            }
          });

          if (shouldKickToHome) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              Navigator.of(context).popUntil((route) => route.isFirst);
            });
          }
        }, onError: (Object error, StackTrace stackTrace) {
          if (kDebugMode) {
            debugPrint('Store config stream error: $error');
          }

          // If the project requires auth for read and anonymous sign-in isn't ready,
          // this can throw permission-denied asynchronously. In release this can
          // appear as an app "crash". Recover by ensuring guest auth and retrying.
          if (_isFirestorePermissionDenied(error)) {
            unawaited(
              _ensureAnonymousAuthForRead(showMessageIfFails: true).then((ok) {
                if (!ok || !mounted) return;
                _listenStoreConfig();
              }),
            );
            return;
          }

          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('โหลดสถานะร้านไม่สำเร็จ')),
          );
        });
  }

  final ScrollController _scrollController = ScrollController();

  final List<String> _ticketImagePaths = <String>[];
  final Set<String> _ticketImagePathSet = <String>{};
  bool _isInitialLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  Object? _loadError;

  // Pager selection
  bool _useFirestoreIndex = false;
  DocumentSnapshot<Map<String, dynamic>>? _firestoreLastDoc;

  // Storage pager state (supports nested prefixes by walking a prefix queue).
  final List<Reference> _storagePrefixQueue = <Reference>[];
  final Set<String> _storageSeenPrefixes = <String>{};
  final Map<String, String?> _storagePageTokenByPrefix = <String, String?>{};
  int _storagePrefixIndex = 0;

  double? _ticketAspectRatio;

  String? _randomPickedImagePath;

  final Map<String, int> _setCountByImagePath = <String, int>{};
  final Set<String> _setCountLoading = <String>{};
  final Map<String, int> _countByTicketNumber = <String, int>{};

  // Paths hidden because another user reserved them.
  // When their lock expires, we reinsert them into the grid without refresh.
  final Map<String, DateTime> _reservedByOtherUntil = <String, DateTime>{};
  Timer? _reservationExpiryTicker;
  static const Duration _reservationRefreshInterval = Duration(seconds: 1);

    // Realtime reservation watcher: listens for lock changes on the currently-loaded
    // ticket docs so other users' carts hide numbers immediately.
    final List<StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>
    _reservationSubs = <StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>[];
    Timer? _reservationWatchDebounce;
    Set<String> _reservationWatchedDocIds = <String>{};
    final Map<String, List<String>> _pathsByReservationDocId =
      <String, List<String>>{};
    static const Duration _reservationWatchDebounceDuration =
      Duration(milliseconds: 250);

  // If a Storage path cannot be shown (missing/permission/invalid), remove it so
  // the grid reflows and doesn't leave visible gaps.
  final Set<String> _invalidTicketPaths = <String>{};
  final Set<String> _pendingInvalidTicketPaths = <String>{};
  bool _invalidateTicketsScheduled = false;

  void _scheduleInvalidateTicketPath(String path) {
    final p = path.trim();
    if (p.isEmpty) return;
    if (_invalidTicketPaths.contains(p)) return;
    if (!_pendingInvalidTicketPaths.add(p)) return;

    if (_invalidateTicketsScheduled) return;
    _invalidateTicketsScheduled = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _invalidateTicketsScheduled = false;
      if (!mounted) return;

      if (_pendingInvalidTicketPaths.isEmpty) return;

      final toRemove = _pendingInvalidTicketPaths.toList(growable: false);
      _pendingInvalidTicketPaths.clear();

      bool changed = false;
      for (final rp in toRemove) {
        if (!_invalidTicketPaths.add(rp)) continue;

        if (_ticketImagePathSet.remove(rp)) {
          _ticketImagePaths.remove(rp);
          changed = true;

          final ticketNumber = _extractTicketNumberFromPath(rp);
          if (ticketNumber != null && ticketNumber.length == 6) {
            final cur = _countByTicketNumber[ticketNumber] ?? 0;
            if (cur <= 1) {
              _countByTicketNumber.remove(ticketNumber);
            } else {
              _countByTicketNumber[ticketNumber] = cur - 1;
            }
          }
        }

        _setCountByImagePath.remove(rp);
        _setCountLoading.remove(rp);
      }

      if (changed) {
        setState(() {});
      }
    });
  }

  // Single-mode source of truth (preferred): Firestore collection `lottery` where setCount == 1.
  final Set<String> _singleLotteryDocIds = <String>{};
  bool _singleLotteryIdsLoaded = false;
  bool _singleLotteryIdsLoading = false;
  Object? _singleLotteryIdsError;

  bool _drainingSingleMode = false;
  bool _drainingSetMode = false;

  bool _drainingSearch = false;

  static const Duration _rotationInterval = Duration(minutes: 5);
  Timer? _rotationTicker;
  DateTime? _nextRotationAt;
  int _rotationOffset = 0;
  int _rotationSecondsRemaining = _rotationInterval.inSeconds;

  @override
  void initState() {
    super.initState();

    _scrollController.addListener(_onScroll);
    _initPagerAndLoadFirstPage();

    _listenStoreConfig();

    _startRotationCountdown();

    _startReservationExpiryTicker();

    _scheduleReservationWatchUpdate();
  }

  bool _isFirestorePermissionDenied(Object? e) {
    return e is FirebaseException && e.code == 'permission-denied';
  }

  Future<bool> _ensureAnonymousAuthForRead({bool showMessageIfFails = false}) async {
    final auth = FirebaseAuth.instance;
    if (auth.currentUser != null) return true;
    try {
      await auth.signInAnonymously();
      return auth.currentUser != null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Anonymous sign-in (BuyLotteryScreen) failed: $e');
      }
      if (showMessageIfFails && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'ไม่สามารถเข้าใช้งานแบบผู้เยี่ยมชมได้ (กรุณาเปิด Anonymous Sign-in ใน Firebase Auth)',
            ),
          ),
        );
      }
      return false;
    }
  }

  Future<T> _withFirestoreAuthRetry<T>(Future<T> Function() action) async {
    try {
      return await action();
    } catch (e) {
      if (_isFirestorePermissionDenied(e)) {
        final ok = await _ensureAnonymousAuthForRead(showMessageIfFails: true);
        if (ok) {
          return await action();
        }
      }
      rethrow;
    }
  }

  DateTime? _lockedUntilFromCountDoc(Map<String, dynamic>? data) {
    if (data == null) return null;
    final lockedUntilRaw = data['lockedUntil'];
    if (lockedUntilRaw is Timestamp) {
      return lockedUntilRaw.toDate();
    }
    // Back-compat fallback: infer a 15-minute lock from lastAddedAt.
    final lastAddedAtRaw = data['lastAddedAt'];
    if (lastAddedAtRaw is Timestamp) {
      return lastAddedAtRaw.toDate().add(const Duration(minutes: 15));
    }
    return null;
  }

  void _markReservedByOther({
    required List<String> paths,
    required DateTime? lockedUntil,
  }) {
    if (paths.isEmpty) return;
    final until = lockedUntil ?? DateTime.now().add(const Duration(minutes: 15));
    for (final p in paths) {
      final existing = _reservedByOtherUntil[p];
      if (existing == null || until.isAfter(existing)) {
        _reservedByOtherUntil[p] = until;
      }
    }
  }

  void _startReservationExpiryTicker() {
    _reservationExpiryTicker?.cancel();
    _reservationExpiryTicker = Timer.periodic(_reservationRefreshInterval, (_) {
      if (!mounted) return;
      _reinsertExpiredReservedTickets();
    });
  }

  void _reinsertExpiredReservedTickets() {
    if (_reservedByOtherUntil.isEmpty) return;
    final now = DateTime.now();

    final expired = <String>[];
    _reservedByOtherUntil.forEach((path, until) {
      if (!now.isBefore(until)) {
        expired.add(path);
      }
    });

    if (expired.isEmpty) return;

    setState(() {
      for (final p in expired) {
        _reservedByOtherUntil.remove(p);
        if (_ticketImagePathSet.add(p)) {
          _ticketImagePaths.add(p);

          final ticketNumber = _extractTicketNumberFromPath(p);
          if (ticketNumber != null && ticketNumber.length == 6) {
            _countByTicketNumber[ticketNumber] =
                (_countByTicketNumber[ticketNumber] ?? 0) + 1;
          }

          if (_mode != BuyMode.all) {
            unawaited(_ensureSetCountLoaded(p));
          }
        }
      }
    });

    _scheduleReservationWatchUpdate();
  }

  void _scheduleReservationWatchUpdate() {
    _reservationWatchDebounce?.cancel();
    _reservationWatchDebounce = Timer(_reservationWatchDebounceDuration, () {
      if (!mounted) return;
      unawaited(_updateReservationWatches());
    });
  }

  void _cancelReservationWatches() {
    for (final s in _reservationSubs) {
      s.cancel();
    }
    _reservationSubs.clear();
    _reservationWatchedDocIds = <String>{};
  }

  void _removeTicketPathLocal(String path) {
    if (_ticketImagePathSet.remove(path)) {
      _ticketImagePaths.remove(path);

      final ticketNumber = _extractTicketNumberFromPath(path);
      if (ticketNumber != null && ticketNumber.length == 6) {
        final cur = _countByTicketNumber[ticketNumber] ?? 0;
        if (cur <= 1) {
          _countByTicketNumber.remove(ticketNumber);
        } else {
          _countByTicketNumber[ticketNumber] = cur - 1;
        }
      }

      _setCountByImagePath.remove(path);
      _setCountLoading.remove(path);
    }
  }

  void _addTicketPathLocal(String path) {
    if (_ticketImagePathSet.add(path)) {
      _ticketImagePaths.add(path);

      final ticketNumber = _extractTicketNumberFromPath(path);
      if (ticketNumber != null && ticketNumber.length == 6) {
        _countByTicketNumber[ticketNumber] =
            (_countByTicketNumber[ticketNumber] ?? 0) + 1;
      }

      if (_mode != BuyMode.all) {
        unawaited(_ensureSetCountLoaded(path));
      }
    }
  }

  bool _isReservedByOtherUserDoc(
    Map<String, dynamic>? data, {
    required String? myUid,
  }) {
    if (data == null) return false;

    final current = (data['addedCount'] as num?)?.toInt() ?? 0;
    if (current <= 0) return false;

    final lockedUntil = _lockedUntilFromCountDoc(data);
    final now = DateTime.now();
    if (lockedUntil != null && now.isAfter(lockedUntil)) return false;

    final lockedBy = (data['lockedByUid'] as String?)?.trim();
    if (lockedBy == null || lockedBy.isEmpty) return true;
    if (myUid == null || myUid.trim().isEmpty) return true;
    return lockedBy != myUid.trim();
  }

  Future<void> _updateReservationWatches() async {
    if (!mounted) return;

    final myUid = FirebaseAuth.instance.currentUser?.uid;

    // Watch both currently loaded tickets and those hidden due to reservation.
    final pathSet = <String>{
      ..._ticketImagePaths,
      ..._reservedByOtherUntil.keys,
    };
    if (pathSet.isEmpty) {
      _cancelReservationWatches();
      _pathsByReservationDocId.clear();
      return;
    }

    final nextDocIds = <String>{};
    final nextPathsByDocId = <String, List<String>>{};

    for (final p in pathSet) {
      final ticketNumber = _extractTicketNumberFromPath(p);
      final docId = _TicketCartCollection._docId(
        imagePath: p,
        ticketNumber: ticketNumber,
      );
      nextDocIds.add(docId);
      (nextPathsByDocId[docId] ??= <String>[]).add(p);
    }

    if (nextDocIds.length == _reservationWatchedDocIds.length &&
        nextDocIds.containsAll(_reservationWatchedDocIds)) {
      _pathsByReservationDocId
        ..clear()
        ..addAll(nextPathsByDocId);
      return;
    }

    _cancelReservationWatches();
    _reservationWatchedDocIds = nextDocIds;
    _pathsByReservationDocId
      ..clear()
      ..addAll(nextPathsByDocId);

    const chunkSize = 30; // Firestore whereIn limit.
    final docIdList = nextDocIds.toList(growable: false);

    for (var i = 0; i < docIdList.length; i += chunkSize) {
      final chunk = docIdList.sublist(
        i,
        (i + chunkSize).clamp(0, docIdList.length),
      );

      final sub = FirebaseFirestore.instance
          .collection(_TicketCartCollection._collection)
          .where(FieldPath.documentId, whereIn: chunk)
          .snapshots()
          .listen((snap) {
            if (!mounted) return;

            bool changed = false;
            for (final doc in snap.docs) {
              final docId = doc.id;
              final data = doc.data();

              final reservedByOther = _isReservedByOtherUserDoc(
                data,
                myUid: myUid,
              );
              final paths = _pathsByReservationDocId[docId] ?? const <String>[];
              if (paths.isEmpty) continue;

              if (reservedByOther) {
                final until = _lockedUntilFromCountDoc(data);
                _markReservedByOther(paths: paths, lockedUntil: until);
                for (final p in paths) {
                  if (_ticketImagePathSet.contains(p)) {
                    _removeTicketPathLocal(p);
                    changed = true;
                  }
                }
              } else {
                // If it was hidden due to reservation and is now free, re-add immediately.
                for (final p in paths) {
                  if (_reservedByOtherUntil.containsKey(p) &&
                      !_ticketImagePathSet.contains(p)) {
                    _reservedByOtherUntil.remove(p);
                    _addTicketPathLocal(p);
                    changed = true;
                  }
                }
              }
            }

            if (changed) {
              setState(() {});
              _scheduleReservationWatchUpdate();
            }
          });

      _reservationSubs.add(sub);
    }
  }

  void _startRotationCountdown() {
    _rotationTicker?.cancel();
    _nextRotationAt = DateTime.now().add(_rotationInterval);
    _rotationSecondsRemaining = _rotationInterval.inSeconds;

    _rotationTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final next = _nextRotationAt;
      if (next == null) {
        _nextRotationAt = DateTime.now().add(_rotationInterval);
        setState(() {
          _rotationSecondsRemaining = _rotationInterval.inSeconds;
        });
        return;
      }

      final remainingMs = next.difference(DateTime.now()).inMilliseconds;
      final remaining = (remainingMs / 1000).ceil();
      if (remaining <= 0) {
        setState(() {
          _rotationOffset += 5;
          _nextRotationAt = DateTime.now().add(_rotationInterval);
          _rotationSecondsRemaining = _rotationInterval.inSeconds;
        });
        return;
      }

      if (remaining != _rotationSecondsRemaining) {
        setState(() {
          _rotationSecondsRemaining = remaining;
        });
      }
    });
  }

  List<String> _sortByTicketNumberAscending(List<String> paths) {
    final list = paths.toList(growable: false);
    list.sort((a, b) {
      final an = int.tryParse(_extractTicketNumberFromPath(a) ?? '');
      final bn = int.tryParse(_extractTicketNumberFromPath(b) ?? '');

      if (an == null && bn == null) return a.compareTo(b);
      if (an == null) return 1;
      if (bn == null) return -1;
      final c = an.compareTo(bn);
      if (c != 0) return c;
      return a.compareTo(b);
    });
    return list;
  }

  List<String> _rotateCircular(List<String> paths, int offset) {
    if (paths.length <= 1) return paths;
    final shift = offset % paths.length;
    if (shift == 0) return paths;
    return <String>[...paths.sublist(shift), ...paths.sublist(0, shift)];
  }

  void _setModeAndReload(BuyMode mode) {
    if (_mode == mode) return;
    setState(() {
      _mode = mode;
      _randomPickedImagePath = null;
    });

    unawaited(_reloadForMode());
  }

  Future<void> _reloadForMode() async {
    await _initPagerAndLoadFirstPage();
    if (!mounted) return;
    if (_mode == BuyMode.single) {
      unawaited(_ensureSingleLotteryIdsLoaded());
      unawaited(_drainAllPagesForSingleMode());
    } else if (_mode == BuyMode.set) {
      // Use the same source-of-truth to exclude setCount==1 from set-mode.
      unawaited(_ensureSingleLotteryIdsLoaded());
      unawaited(_drainAllPagesForSetMode());
    }
  }

  List<String> _lotteryDocIdCandidatesForImagePath(String imagePath) {
    final last = imagePath.split('/').last;
    final dot = last.lastIndexOf('.');
    final noExt = (dot <= 0) ? last : last.substring(0, dot);
    if (noExt == last) return <String>[last];
    return <String>[noExt, last];
  }

  Future<void> _ensureSingleLotteryIdsLoaded() async {
    if (_singleLotteryIdsLoaded || _singleLotteryIdsLoading) return;
    _singleLotteryIdsLoading = true;
    _singleLotteryIdsError = null;
    if (mounted) setState(() {});

    try {
      final col = FirebaseFirestore.instance.collection('lottery');
      const pageSize = 500;

      Future<void> loadWhereEqualTo(dynamic value) async {
        DocumentSnapshot<Map<String, dynamic>>? last;
        while (mounted && _mode == BuyMode.single) {
          var q = col
              .where('setCount', isEqualTo: value)
              .orderBy(FieldPath.documentId)
              .limit(pageSize);
          if (last != null) q = q.startAfterDocument(last);
          final snap = await q.get();
          for (final d in snap.docs) {
            _singleLotteryDocIds.add(d.id);
          }
          if (snap.docs.isEmpty || snap.docs.length < pageSize) break;
          last = snap.docs.last;
        }
      }

      // In your data, setCount appears to be stored as string ("1").
      await loadWhereEqualTo('1');
      // Also support numeric storage just in case.
      await loadWhereEqualTo(1);

      _singleLotteryIdsLoaded = true;
    } catch (e) {
      _singleLotteryIdsError = e;
      _singleLotteryIdsLoaded =
          true; // loaded-but-failed; prevents infinite retries.
    } finally {
      _singleLotteryIdsLoading = false;
      if (mounted) setState(() {});
    }
  }

  List<String> _currentSearchDigits() {
    return List<String>.generate(6, (i) {
      final t = _digitControllers[i].text.trim();
      if (t.isEmpty) return '';
      final ch = t.characters.first;
      return RegExp(r'\d').hasMatch(ch) ? ch : '';
    }, growable: false);
  }

  bool get _isSearchActive {
    for (final c in _digitControllers) {
      if (c.text.trim().isNotEmpty) return true;
    }
    return false;
  }

  bool _matchesSearchDigits(String imagePath) {
    if (!_isSearchActive) return true;
    final ticketNumber = _extractTicketNumberFromPath(imagePath);
    if (ticketNumber == null) return false;
    if (ticketNumber.length < 6) return false;

    final digits = _currentSearchDigits();
    for (var i = 0; i < 6; i++) {
      final d = digits[i];
      if (d.isEmpty) continue;
      if (ticketNumber[i] != d) return false;
    }
    return true;
  }

  Future<void> _drainAllPagesForSearch() async {
    if (_drainingSearch) return;
    _drainingSearch = true;
    try {
      while (mounted && _isSearchActive && _hasMore) {
        if (_isLoadingMore || _isInitialLoading) {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          continue;
        }
        await _loadNextPage();
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    } finally {
      _drainingSearch = false;
    }
  }

  Future<void> _drainAllPagesForSingleMode() async {
    if (_drainingSingleMode) return;
    _drainingSingleMode = true;
    try {
      while (mounted && _mode == BuyMode.single && _hasMore) {
        if (_isLoadingMore || _isInitialLoading) {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          continue;
        }
        await _loadNextPage();
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    } finally {
      _drainingSingleMode = false;
    }
  }

  Future<void> _drainAllPagesForSetMode() async {
    if (_drainingSetMode) return;
    _drainingSetMode = true;
    try {
      while (mounted && _mode == BuyMode.set && _hasMore) {
        if (_isLoadingMore || _isInitialLoading) {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          continue;
        }
        await _loadNextPage();
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    } finally {
      _drainingSetMode = false;
    }
  }

  Future<void> _ensureSetCountLoaded(String imagePath) async {
    if (_setCountByImagePath.containsKey(imagePath)) return;
    if (!_setCountLoading.add(imagePath)) return;

    try {
      final ticketNumber = _extractTicketNumberFromPath(imagePath);
      final meta = await _TicketMetaCollection.get(
        imagePath: imagePath,
        ticketNumber: ticketNumber,
      );
      _setCountByImagePath[imagePath] = meta.setCount;
    } finally {
      _setCountLoading.remove(imagePath);
      if (mounted) setState(() {});
    }
  }

  int? _parseSetCountFromPath(String imagePath) {
    // Best-effort: some upload filenames include the set size, e.g. "set2", "2set", "2ใบ".
    final name = imagePath.split('/').last;
    final patterns = <RegExp>[
      RegExp(r'(?:set|ชุด|qty|count|ใบ)[-_ ]?(\d{1,2})', caseSensitive: false),
      RegExp(r'(\d{1,2})[-_ ]?(?:set|ชุด|ใบ)', caseSensitive: false),
      RegExp(r'\b(?:x|\*)\s*(\d{1,2})\b', caseSensitive: false),
    ];

    for (final re in patterns) {
      final m = re.firstMatch(name);
      final raw = m?.group(1);
      if (raw == null) continue;
      final v = int.tryParse(raw);
      if (v == null) continue;
      if (v >= 1 && v <= 99) return v;
    }
    return null;
  }

  int? _effectiveSetCountForImagePath(String imagePath) {
    final cached = _setCountByImagePath[imagePath];
    if (cached != null) return cached;

    final fromName = _parseSetCountFromPath(imagePath);
    if (fromName != null) return fromName;

    final ticketNumber = _extractTicketNumberFromPath(imagePath);
    if (ticketNumber == null || ticketNumber.length != 6) return null;
    return _countByTicketNumber[ticketNumber];
  }

  bool _matchesModeIfKnown(String imagePath) {
    if (_mode == BuyMode.single && _singleLotteryIdsLoaded) {
      for (final id in _lotteryDocIdCandidatesForImagePath(imagePath)) {
        if (_singleLotteryDocIds.contains(id)) return true;
      }
      return false;
    }

    if (_mode == BuyMode.set && _singleLotteryIdsLoaded) {
      for (final id in _lotteryDocIdCandidatesForImagePath(imagePath)) {
        if (_singleLotteryDocIds.contains(id)) return false;
      }
      // Not a known single => continue with setCount-based check below.
    }

    final setCount = _effectiveSetCountForImagePath(imagePath);
    if (setCount == null) return false;
    if (_mode == BuyMode.single) return setCount <= 1;
    if (_mode == BuyMode.set) return setCount > 1;
    return true;
  }

  void _onScroll() {
    if (!_hasMore || _isLoadingMore || _isInitialLoading) return;
    if (!_scrollController.hasClients) return;

    final position = _scrollController.position;
    // Start loading when user is close to the bottom.
    if (position.pixels >= position.maxScrollExtent - 600) {
      _loadNextPage();
    }
  }

  Future<void> _initPagerAndLoadFirstPage() async {
    if (!_firebaseStorageSupported) {
      setState(() {
        _isInitialLoading = false;
        _hasMore = false;
      });
      return;
    }

    // Firestore rules in this project require auth even for read-only ticket data.
    // Treat a guest as an anonymous user so they can browse without a login UI.
    await _ensureAnonymousAuthForRead(showMessageIfFails: false);

    setState(() {
      _isInitialLoading = true;
      _loadError = null;
      _hasMore = true;
      _isLoadingMore = false;
      _ticketImagePaths.clear();
      _ticketImagePathSet.clear();
      _countByTicketNumber.clear();

      _invalidTicketPaths.clear();
      _pendingInvalidTicketPaths.clear();
      _invalidateTicketsScheduled = false;

      _singleLotteryDocIds.clear();
      _singleLotteryIdsLoaded = false;
      _singleLotteryIdsLoading = false;
      _singleLotteryIdsError = null;

      _ticketAspectRatio = null;

      _useFirestoreIndex = false;
      _firestoreLastDoc = null;
      _storagePrefixQueue.clear();
      _storageSeenPrefixes.clear();
      _storagePageTokenByPrefix.clear();
      _storagePrefixIndex = 0;

      _randomPickedImagePath = null;
    });

    final usedFs = await _tryInitFirestoreIndexPager();
    if (!usedFs) {
      await _initStoragePager();
    }

    await _loadNextPage();
    if (!mounted) return;
    setState(() => _isInitialLoading = false);

    if (_mode == BuyMode.single) {
      unawaited(_ensureSingleLotteryIdsLoaded());
      unawaited(_drainAllPagesForSingleMode());
    }
    if (_mode == BuyMode.set) {
      unawaited(_ensureSingleLotteryIdsLoaded());
      unawaited(_drainAllPagesForSetMode());
    }
    if (_isSearchActive) {
      unawaited(_drainAllPagesForSearch());
    }
  }

  void _pickRandomTicketFromLoaded() {
    final cart = CartScope.of(context);
    final candidatesAll = _ticketImagePaths
        .where((p) => !cart.contains(p))
        .toList(growable: false);
    final candidates = _mode == BuyMode.all
        ? candidatesAll
        : candidatesAll.where(_matchesModeIfKnown).toList(growable: false);

    if (candidates.isEmpty) {
      if (_mode != BuyMode.all) {
        for (final p in candidatesAll) {
          unawaited(_ensureSetCountLoaded(p));
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _mode == BuyMode.single
                  ? 'กำลังค้นหาสลากหนึ่งใบ...'
                  : 'กำลังค้นหาสลากหวยชุด...',
            ),
          ),
        );
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ยังไม่มีสลากให้สุ่ม (กำลังโหลดรูป)')),
      );
      return;
    }

    final picked = candidates[Random().nextInt(candidates.length)];
    setState(() {
      _randomPickedImagePath = picked;
    });
  }

  Future<void> _maybeComputeTicketAspectRatio(List<String> paths) async {
    if (_ticketAspectRatio != null) return;
    if (!_firebaseStorageSupported) return;
    if (paths.isEmpty) return;

    try {
      final url = await _storage.ref(paths.first).getDownloadURL();
      final size = await _getNetworkImageIntrinsicSize(url);
      if (size.width <= 0 || size.height <= 0) return;
      if (!mounted) return;

      setState(() {
        _ticketAspectRatio = size.width / size.height;
      });
    } catch (_) {
      // Keep fallback sizing.
    }
  }

  Future<Size> _getNetworkImageIntrinsicSize(String url) {
    final completer = Completer<Size>();
    final provider = NetworkImage(url);
    final stream = provider.resolve(const ImageConfiguration());
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (imageInfo, synchronousCall) {
        completer.complete(
          Size(
            imageInfo.image.width.toDouble(),
            imageInfo.image.height.toDouble(),
          ),
        );
        stream.removeListener(listener);
      },
      onError: (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  bool _isImagePath(String path) {
    final p = path.toLowerCase();
    // If the object has no extension, allow it (some Storage objects are named as IDs).
    if (!p.contains('.')) return true;
    return p.endsWith('.png') ||
        p.endsWith('.jpg') ||
        p.endsWith('.jpeg') ||
        p.endsWith('.webp');
  }

  Future<bool> _tryInitFirestoreIndexPager() async {
    try {
      final query = FirebaseFirestore.instance
          .collection(_firestoreIndexCollection)
          .orderBy('createdAt', descending: true)
          .limit(1);
      final snap = await _withFirestoreAuthRetry(() => query.get());
      if (snap.docs.isEmpty) return false;

      final data = snap.docs.first.data();
      final path = (data['path'] as String?)?.trim() ?? '';
      if (path.isEmpty) return false;

      _useFirestoreIndex = true;
      _firestoreLastDoc = null;
      if (kDebugMode) {
        debugPrint(
          'Ticket source: Firestore index ($_firestoreIndexCollection)',
        );
      }
      return true;
    } catch (_) {
      // If permissions/index are not available, fallback to Storage.
      if (kDebugMode) {
        debugPrint('Ticket source: Storage (Firestore index unavailable)');
      }
      return false;
    }
  }

  Future<void> _initStoragePager() async {
    Object? lastError;

    // Prefer known prefixes.
    for (final prefix in _ticketImagePrefixes) {
      try {
        final ref = _storage.ref(prefix);
        final res = await ref.list(const ListOptions(maxResults: 1));
        if (res.items.isNotEmpty || res.prefixes.isNotEmpty) {
          _storagePrefixQueue.add(ref);
          _storageSeenPrefixes.add(ref.fullPath);
          _storagePageTokenByPrefix[ref.fullPath] = null;
          return;
        }
      } catch (e) {
        lastError = e;
      }

      // If list() fails/empty, it might be a single file.
      try {
        await _storage.ref(prefix).getDownloadURL();
        final ref = _storage.ref(prefix);
        _storagePrefixQueue.add(ref);
        _storageSeenPrefixes.add(ref.fullPath);
        _storagePageTokenByPrefix[ref.fullPath] = null;
        return;
      } catch (e) {
        lastError = e;
      }
    }

    // Final fallback: bucket root.
    try {
      final ref = _storage.ref();
      _storagePrefixQueue.add(ref);
      _storageSeenPrefixes.add(ref.fullPath);
      _storagePageTokenByPrefix[ref.fullPath] = null;
      return;
    } catch (e) {
      lastError = e;
    }

    if (_isStoragePermissionDenied(lastError)) {
      throw lastError;
    }
  }

  Future<void> _loadNextPage() async {
    if (!_hasMore || _isLoadingMore) return;
    if (!_firebaseStorageSupported) return;

    setState(() {
      _isLoadingMore = true;
      _loadError = null;
    });

    try {
      // Filter out tickets that are currently reserved by other users.
      final myUid = FirebaseAuth.instance.currentUser?.uid;

      bool isReservedByOther(Map<String, dynamic>? data) {
        if (data == null) return false;

        final lockedBy = (data['lockedByUid'] as String?)?.trim();
        final lockedUntil = _lockedUntilFromCountDoc(data);

        final current = (data['addedCount'] as num?)?.toInt() ?? 0;
        if (current <= 0) return false;

        final now = DateTime.now();
        if (lockedUntil != null && now.isAfter(lockedUntil)) return false;

        // If lock owner is unknown, treat as reserved.
        if (lockedBy == null || lockedBy.isEmpty) return true;
        if (myUid == null || myUid.trim().isEmpty) return true;
        return lockedBy != myUid.trim();
      }

      Future<List<String>> filterOutReservedByOtherUsers(
        List<String> candidates,
      ) async {
        if (candidates.isEmpty) return candidates;

        // Build docIds (digits preferred; fallback to path-based id).
        final docIdByPath = <String, String>{};
        final pathsByDocId = <String, List<String>>{};
        final docIds = <String>[];
        for (final p in candidates) {
          final ticketNumber = _extractTicketNumberFromPath(p);
          final docId = _TicketCartCollection._docId(
            imagePath: p,
            ticketNumber: ticketNumber,
          );
          docIdByPath[p] = docId;
          (pathsByDocId[docId] ??= <String>[]).add(p);
          docIds.add(docId);
        }

        final reservedDocIds = <String>{};
        const chunkSize = 30; // Firestore whereIn limit.
        for (var i = 0; i < docIds.length; i += chunkSize) {
          final chunk = docIds.sublist(
            i,
            (i + chunkSize).clamp(0, docIds.length),
          );
          final q = await _withFirestoreAuthRetry(() {
            return FirebaseFirestore.instance
                .collection(_TicketCartCollection._collection)
                .where(FieldPath.documentId, whereIn: chunk)
                .get();
          });

          for (final d in q.docs) {
            if (isReservedByOther(d.data())) {
              reservedDocIds.add(d.id);

              // Record expiry for realtime re-appearance.
              _markReservedByOther(
                paths: pathsByDocId[d.id] ?? const <String>[],
                lockedUntil: _lockedUntilFromCountDoc(d.data()),
              );
            }
          }
        }

        return candidates
            .where((p) => !reservedDocIds.contains(docIdByPath[p]))
            .toList(growable: false);
      }

      final newPaths = <String>[];

      if (_useFirestoreIndex) {
        // Try a few times to fill a page after filtering out reserved tickets.
        for (var attempt = 0; attempt < 3 && newPaths.length < _pageSize; attempt++) {
          var query = FirebaseFirestore.instance
              .collection(_firestoreIndexCollection)
              .orderBy('createdAt', descending: true)
              .limit(_pageSize);
          if (_firestoreLastDoc != null) {
            query = query.startAfterDocument(_firestoreLastDoc!);
          }

          final snap = await _withFirestoreAuthRetry(() => query.get());
          final indexCandidates = <String>[];
          for (final doc in snap.docs) {
            final data = doc.data();
            final path = (data['path'] as String?)?.trim() ?? '';
            if (path.isEmpty) continue;
            if (!_isImagePath(path)) continue;
            indexCandidates.add(path);
          }

          final displayable = <String>[];
          for (final p in indexCandidates) {
            if (await _shouldDisplayIndexPath(p)) {
              displayable.add(p);
            }
          }

          final filtered = await filterOutReservedByOtherUsers(displayable);
          for (final p in filtered) {
            if (newPaths.length >= _pageSize) break;
            newPaths.add(p);
          }

          if (snap.docs.isNotEmpty) {
            _firestoreLastDoc = snap.docs.last;
          }
          if (snap.docs.length < _pageSize) {
            _hasMore = false;
            break;
          }
        }
      } else {
        // Walk through prefixes and list with page tokens so we don't have to
        // download everything at once.
        while (newPaths.length < _pageSize &&
            _storagePrefixIndex < _storagePrefixQueue.length) {
          final ref = _storagePrefixQueue[_storagePrefixIndex];
          final token = _storagePageTokenByPrefix[ref.fullPath];
          final res = await ref.list(
            ListOptions(
              maxResults: _pageSize - newPaths.length,
              pageToken: token,
            ),
          );

          for (final p in res.prefixes) {
            if (_storageSeenPrefixes.add(p.fullPath)) {
              _storagePrefixQueue.add(p);
              _storagePageTokenByPrefix[p.fullPath] = null;
            }
          }

          for (final item in res.items) {
            if (_isImagePath(item.fullPath)) {
              newPaths.add(item.fullPath);
              if (newPaths.length >= _pageSize) break;
            }
          }

          _storagePageTokenByPrefix[ref.fullPath] = res.nextPageToken;
          if (res.nextPageToken == null) {
            _storagePrefixIndex += 1;
          }
        }

        // Filter out reserved tickets (by other users) from this page.
        if (newPaths.isNotEmpty) {
          final filtered = await filterOutReservedByOtherUsers(newPaths);
          newPaths
            ..clear()
            ..addAll(filtered);
        }

        if (newPaths.isEmpty) {
          _hasMore = false;
        }
      }

      if (newPaths.isNotEmpty) {
        for (final p in newPaths) {
          if (_ticketImagePathSet.add(p)) {
            _ticketImagePaths.add(p);

            final ticketNumber = _extractTicketNumberFromPath(p);
            if (ticketNumber != null && ticketNumber.length == 6) {
              _countByTicketNumber[ticketNumber] =
                  (_countByTicketNumber[ticketNumber] ?? 0) + 1;
            }

            if (_mode != BuyMode.all) {
              unawaited(_ensureSetCountLoaded(p));
            }
          }
        }

        _scheduleReservationWatchUpdate();

        // Compute aspect ratio once from the first available image.
        await _maybeComputeTicketAspectRatio(_ticketImagePaths);
      }
    } catch (e) {
      _loadError = e;
      if (_isStoragePermissionDenied(e)) {
        _hasMore = false;
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingMore = false;
        });
      }
    }
  }

  bool _isStoragePermissionDenied(Object? e) {
    if (e == null) return false;

    // firebase_storage typically throws FirebaseException; on some platforms message contains 403/Permission denied.
    final s = e.toString().toLowerCase();
    return s.contains('permission denied') ||
        s.contains('unauthorized') ||
        s.contains('httpresult: 403') ||
        s.contains('code: -13021');
  }

  @override
  void dispose() {
    _storeConfigSub?.cancel();
    _rotationTicker?.cancel();
    _reservationExpiryTicker?.cancel();
    _reservationWatchDebounce?.cancel();
    _cancelReservationWatches();
    _scrollController.dispose();
    for (final c in _digitControllers) {
      c.dispose();
    }
    for (final f in _digitFocusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  void _onDigitChanged(int index, String value) {
    if (value.isNotEmpty && index < _digitFocusNodes.length - 1) {
      _digitFocusNodes[index + 1].requestFocus();
    }
    if (value.isEmpty && index > 0) {
      _digitFocusNodes[index - 1].requestFocus();
    }

    setState(() {
      _randomPickedImagePath = null;
    });

    if (_isSearchActive) {
      unawaited(_drainAllPagesForSearch());
    }
  }

  @override
  Widget build(BuildContext context) {
    final cart = CartScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'ถุงทอง ล็อตเตอรี่',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        leadingWidth: 56,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: _HeaderLogo.small(),
        ),
        actions: [
          StreamBuilder<User?>(
            stream: FirebaseAuth.instance.authStateChanges(),
            builder: (context, snapshot) {
              final user = snapshot.data ?? FirebaseAuth.instance.currentUser;
              final uid = (user != null && !user.isAnonymous)
                  ? user.uid.trim()
                  : '';

              void openCart() {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const CartEntryScreen()),
                );
              }

              if (uid.isEmpty) {
                return IconButton(
                  onPressed: openCart,
                  icon: const Icon(Icons.person_outline),
                );
              }

              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: TextButton.icon(
                  onPressed: openCart,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  icon: const Icon(Icons.person_outline, size: 20),
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: Text(
                      _shortUid(uid),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        controller: _scrollController,
        child: Column(
          children: [
            Container(
              color: Colors.red,
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 22),
              child: Column(
                children: [
                  Text(
                    'ถุงทอง ล็อตเตอรี่',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'จำหน่ายสลากกินแบ่งรัฐบาล ที่ถูกต้องตามกฎหมาย',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'กรอกตัวเลข ค้นหารางวัลที่ 1',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: Colors.grey.shade900,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          _ModeButton(
                            label: 'ทั้งหมด',
                            selected: _mode == BuyMode.all,
                            onTap: () => _setModeAndReload(BuyMode.all),
                          ),
                          const SizedBox(width: 10),
                          _ModeButton(
                            label: 'หวยเดี่ยว',
                            selected: _mode == BuyMode.single,
                            onTap: () => _setModeAndReload(BuyMode.single),
                          ),
                          const SizedBox(width: 10),
                          _ModeButton(
                            label: 'หวยชุด',
                            selected: _mode == BuyMode.set,
                            onTap: () => _setModeAndReload(BuyMode.set),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: List.generate(6, (i) {
                          return _BuyDigitBox(
                            controller: _digitControllers[i],
                            focusNode: _digitFocusNodes[i],
                            onChanged: (v) => _onDigitChanged(i, v),
                            hintText: '${i + 1}',
                          );
                        }),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: SizedBox(
                              height: 52,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.grey.shade900,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                onPressed: _pickRandomTicketFromLoaded,
                                icon: const Icon(Icons.auto_awesome),
                                label: const Text(
                                  'สุ่มตัวเลข',
                                  style: TextStyle(fontWeight: FontWeight.w900),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: SizedBox(
                              height: 52,
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                onPressed: () {
                                  FocusScope.of(context).unfocus();
                                  setState(() {
                                    _randomPickedImagePath = null;
                                  });
                                  if (_isSearchActive) {
                                    unawaited(_drainAllPagesForSearch());
                                  }
                                },
                                child: const Text(
                                  'ค้นหา',
                                  style: TextStyle(fontWeight: FontWeight.w900),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),

                      if (_storeOpen && _randomPickedImagePath != null) ...[
                        const SizedBox(height: 14),
                        LayoutBuilder(
                          builder: (context, constraints) {
                            // Match the visual size of a single grid item (2 columns).
                            const crossAxisSpacing = 2.0;
                            final itemWidth =
                                (constraints.maxWidth - crossAxisSpacing) / 2;
                            final aspect = _ticketAspectRatio ?? 1.18;
                            final itemHeight = itemWidth / aspect;

                            final imagePath = _randomPickedImagePath!;
                            final cart = CartScope.of(context);
                            if (cart.contains(imagePath)) {
                              return const SizedBox.shrink();
                            }

                            return Align(
                              alignment: Alignment.centerLeft,
                              child: SizedBox(
                                width: itemWidth,
                                height: itemHeight,
                                child: _TicketCardPlaceholder(
                                  imagePath: imagePath,
                                  onAddToCart: () async {
                                    final ticketId = imagePath;
                                    final ticketNumber =
                                        _extractTicketNumberFromPath(imagePath);
                                    final displayName = ticketNumber == null
                                        ? 'สลาก ${imagePath.split('/').last}'
                                        : 'สลากเลข $ticketNumber';

                                    final meta =
                                        await _TicketMetaCollection.get(
                                          imagePath: imagePath,
                                          ticketNumber: ticketNumber,
                                        );

                                    // Source of truth: Firestore `lottery.setCount` for this 6-digit number.
                                    // Do not guess from cart quantity or default fallback.
                                    final addQty =
                                        (await _resolveSetCountFromLottery(
                                          imagePath: imagePath,
                                          ticketNumber: ticketNumber,
                                        )) ??
                                        1;
                                    int? newRemoteCount;
                                    try {
                                      newRemoteCount =
                                          await _TicketCartCollection.incrementAndGetCount(
                                            ticketNumber: ticketNumber,
                                            imagePath: imagePath,
                                            delta: addQty,
                                            setCount: addQty,
                                            prizeMillion: meta.prizeMillion,
                                            prizeText: meta.prizeText,
                                          );
                                    } on _TicketAlreadyReserved {
                                      if (!context.mounted) return;
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'เลขนี้มีคนหยิบใส่ตะกร้าแล้ว กรุณาเลือกเลขอื่น',
                                          ),
                                          backgroundColor: Colors.red,
                                          duration: Duration(milliseconds: 1400),
                                        ),
                                      );
                                      return;
                                    }

                                    if (newRemoteCount == null) {
                                      if (!context.mounted) return;
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'ทำรายการไม่สำเร็จ กรุณาลองใหม่',
                                          ),
                                          backgroundColor: Colors.red,
                                          duration: Duration(milliseconds: 1400),
                                        ),
                                      );
                                      return;
                                    }

                                    if (!context.mounted) return;

                                    cart.add(
                                      CartItem(
                                        id: ticketId,
                                        displayName: displayName,
                                        imagePath: imagePath,
                                        quantity: addQty,
                                      ),
                                    );

                                    if (mounted) {
                                      setState(() {
                                        _randomPickedImagePath = null;
                                      });
                                    }

                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          ticketNumber == null
                                              ? 'รายการนี้สะสมในระบบ $newRemoteCount ใบ (+$addQty) (ในตะกร้า ${cart.count} ใบ)'
                                              : 'เลข $ticketNumber สะสมในระบบ $newRemoteCount ใบ (+$addQty) (ในตะกร้า ${cart.count} ใบ)',
                                        ),
                                        backgroundColor: Colors.green,
                                        duration: Duration(milliseconds: 900),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            Container(
              width: double.infinity,
              color: Colors.red,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: Container(
                      height: 220,
                      width: double.infinity,
                      color: Colors.red.shade700,
                      alignment: Alignment.center,
                      child: Image.asset(
                        'assets/file_0000000069407209bc6937c0c3ce34f0.png',
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _CountdownRow(
                    days: 0,
                    hours: 0,
                    minutes: (_rotationSecondsRemaining ~/ 60).clamp(0, 99),
                    seconds: (_rotationSecondsRemaining % 60).clamp(0, 59),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: AnimatedBuilder(
                animation: cart,
                builder: (context, _) {
                  if (!_storeOpen) {
                    return Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Text(
                        _storeClosedMessage,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                    );
                  }

                  if (_loadError != null) {
                    return Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: const Text(
                        'ยังดึงรูปสลากไม่ได้ (Storage ถูกปิดสิทธิ์อ่าน)\n\nถ้าต้องการให้ “ดูสลากได้โดยไม่ต้องล็อกอิน”\nให้ตั้ง Storage Rules เป็น allow read ได้ก่อน',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    );
                  }

                  if (_isInitialLoading && _ticketImagePaths.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    );
                  }

                  final uniquePaths = _ticketImagePaths.toList(growable: false);

                  // If a ticket has been added to cart, hide it from this grid
                  // so it effectively "moves" to the bottom cart.
                  final availablePaths = uniquePaths
                      .where((p) => !cart.contains(p))
                      .toList(growable: false);

                  // For set-mode, we must exclude all tickets that are marked as single (setCount==1)
                  // in Firestore collection `lottery`. Wait until that index is loaded to avoid
                  // briefly showing single tickets in the set grid.
                  if (_mode == BuyMode.set && _singleLotteryIdsError != null) {
                    return Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Text(
                        'อ่านข้อมูลหวยชุดจาก Firestore ไม่ได้\n(คอลเลกชัน lottery / setCount)\n\n$_singleLotteryIdsError',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                    );
                  }

                  if (_mode == BuyMode.set &&
                      (!_singleLotteryIdsLoaded || _singleLotteryIdsLoading)) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    );
                  }

                  final filteredPaths =
                      (_mode == BuyMode.all
                              ? availablePaths
                              : availablePaths.where(_matchesModeIfKnown))
                          .toList(growable: false);

                  if (_mode == BuyMode.set) {
                    filteredPaths.sort((a, b) {
                      final bc = _effectiveSetCountForImagePath(b) ?? 0;
                      final ac = _effectiveSetCountForImagePath(a) ?? 0;
                      return bc.compareTo(ac);
                    });
                  }

                  if (_mode != BuyMode.all) {
                    for (final p in availablePaths) {
                      unawaited(_ensureSetCountLoaded(p));
                    }
                  }

                  // If there are no images, don't show any ticket frames/buttons.
                  if (availablePaths.isEmpty) {
                    return const SizedBox.shrink();
                  }

                  if (_mode != BuyMode.all && filteredPaths.isEmpty) {
                    if (_mode == BuyMode.single &&
                        _singleLotteryIdsError != null) {
                      return Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Text(
                          'อ่านข้อมูลหวยเดี่ยวจาก Firestore ไม่ได้\n(คอลเลกชัน lottery / setCount)\n\n$_singleLotteryIdsError',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                      );
                    }

                    if (_mode == BuyMode.single &&
                        (!_singleLotteryIdsLoaded ||
                            _singleLotteryIdsLoading)) {
                      return const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      );
                    }

                    final stillLoadingCounts =
                        _setCountLoading.isNotEmpty ||
                        _isLoadingMore ||
                        _isInitialLoading;
                    if (stillLoadingCounts || _hasMore) {
                      return const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      );
                    }

                    return Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Text(
                        _mode == BuyMode.single
                            ? 'ไม่มี สลาก 1ใบ'
                            : 'ไม่มี สลาก หวยชุด',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                    );
                  }

                  final finalPathsRaw = _isSearchActive
                      ? filteredPaths
                        .where(_matchesSearchDigits)
                        .toList(growable: false)
                      : filteredPaths;

                  // Remove missing/bad items so the grid doesn't show gaps.
                  final finalPaths = _invalidTicketPaths.isEmpty
                      ? finalPathsRaw
                      : finalPathsRaw
                        .where((p) => !_invalidTicketPaths.contains(p))
                        .toList(growable: false);

                  // Base order: low ticket number -> high ticket number.
                  // Then rotate positions in a circle every 5 minutes.
                  final orderedForGrid = _rotateCircular(
                    _sortByTicketNumberAscending(finalPaths),
                    _rotationOffset,
                  );

                  if (_isSearchActive && finalPaths.isEmpty) {
                    final stillLoading =
                        _isLoadingMore || _isInitialLoading || _hasMore;
                    if (stillLoading) {
                      return const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      );
                    }

                    return Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: const Text(
                        'ไม่พบสลากตามเลขที่กรอก',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontWeight: FontWeight.w900),
                      ),
                    );
                  }

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: orderedForGrid.length + (_hasMore ? 1 : 0),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 2,
                          mainAxisSpacing: 2,
                          // Card = image + built-in bottom bar.
                          childAspectRatio: _ticketAspectRatio ?? 1.18,
                        ),
                        itemBuilder: (context, index) {
                          if (index >= orderedForGrid.length) {
                            if (!_isLoadingMore) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted) _loadNextPage();
                              });
                            }
                            return Center(
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: _isLoadingMore
                                    ? const CircularProgressIndicator(
                                        strokeWidth: 2,
                                      )
                                    : const Icon(Icons.expand_more),
                              ),
                            );
                          }

                          final imagePath = orderedForGrid[index];

                          final ticketId = imagePath;
                          final ticketNumber = _extractTicketNumberFromPath(
                            imagePath,
                          );
                          final displayName = ticketNumber == null
                              ? 'สลาก ${imagePath.split('/').last}'
                              : 'สลากเลข $ticketNumber';

                          return _TicketCardPlaceholder(
                            imagePath: imagePath,
                            onInvalidPath: _scheduleInvalidateTicketPath,
                            onAddToCart: () async {
                              final meta = await _TicketMetaCollection.get(
                                imagePath: imagePath,
                                ticketNumber: ticketNumber,
                              );

                              // Source of truth: Firestore `lottery.setCount` for this 6-digit number.
                              final addQty =
                                  (await _resolveSetCountFromLottery(
                                    imagePath: imagePath,
                                    ticketNumber: ticketNumber,
                                  )) ??
                                  1;
                              int? newRemoteCount;
                              try {
                                newRemoteCount =
                                    await _TicketCartCollection.incrementAndGetCount(
                                      ticketNumber: ticketNumber,
                                      imagePath: imagePath,
                                      delta: addQty,
                                      setCount: addQty,
                                      prizeMillion: meta.prizeMillion,
                                      prizeText: meta.prizeText,
                                    );
                              } on _TicketAlreadyReserved {
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'เลขนี้มีคนหยิบใส่ตะกร้าแล้ว กรุณาเลือกเลขอื่น',
                                    ),
                                    backgroundColor: Colors.red,
                                    duration: Duration(milliseconds: 1400),
                                  ),
                                );
                                return;
                              }

                              if (newRemoteCount == null) {
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'ทำรายการไม่สำเร็จ กรุณาลองใหม่',
                                    ),
                                    backgroundColor: Colors.red,
                                    duration: Duration(milliseconds: 1400),
                                  ),
                                );
                                return;
                              }

                              if (!context.mounted) return;

                              cart.add(
                                CartItem(
                                  id: ticketId,
                                  displayName: displayName,
                                  imagePath: imagePath,
                                  quantity: addQty,
                                ),
                              );

                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    ticketNumber == null
                                        ? 'รายการนี้สะสมในระบบ $newRemoteCount ใบ (+$addQty) (ในตะกร้า ${cart.count} ใบ)'
                                        : 'เลข $ticketNumber สะสมในระบบ $newRemoteCount ใบ (+$addQty) (ในตะกร้า ${cart.count} ใบ)',
                                  ),
                                  backgroundColor: Colors.green,
                                  duration: Duration(milliseconds: 900),
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
      bottomNavigationBar: AnimatedBuilder(
        animation: cart,
        builder: (context, _) {
          return _BuyBottomNavBar(
            currentIndex: _bottomIndex,
            cartCount: cart.count,
            onChanged: (i) {
              if (i == 0) {
                Navigator.of(context).pop();
                return;
              }

              if (i == 2) {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const CartEntryScreen()),
                );
                return;
              }

              setState(() => _bottomIndex = i);
            },
          );
        },
      ),
    );
  }
}

String _shortUid(String uid) {
  final v = uid.trim();
  if (v.isEmpty) return '';
  if (v.length <= 6) return v;
  return '${v.substring(0, 6)}…';
}

String? _extractTicketNumberFromPath(String imagePath) {
  final name = imagePath.split('/').last;
  // Common real-world filename: "658014_1766929128526_001".
  // In this case the ticket number is the leading 6 digits, not the last 6-digit group.
  final leading = RegExp(r'^(\d{6})(?=[^\d]|$)').firstMatch(name);
  if (leading != null && leading.group(1) != '000000') return leading.group(1);

  // Prefer the last 6-digit group in the filename.
  // Many upload filenames contain other digits (dates/timestamps/ids) before the actual ticket number.
  final m6All = RegExp(r'\d{6}').allMatches(name).toList(growable: false);
  if (m6All.isNotEmpty) {
    final v = m6All.last.group(0);
    return (v == '000000') ? null : v;
  }

  final matches = RegExp(r'\d+').allMatches(name).toList(growable: false);
  if (matches.isEmpty) return null;
  matches.sort((a, b) => b.group(0)!.length.compareTo(a.group(0)!.length));
  // If multiple groups share the max length, prefer the last one.
  final maxLen = matches.first.group(0)!.length;
  final sameMax = matches
      .where((m) => m.group(0)!.length == maxLen)
      .toList(growable: false);
  final v = sameMax.isNotEmpty ? sameMax.last.group(0) : matches.first.group(0);
  return (v == '000000') ? null : v;
}

class _TicketCartCollection {
  static const String _collection = 'ticket_cart_counts';

  static const Duration _lockDuration = Duration(minutes: 15);

  static String _docId({required String imagePath, String? ticketNumber}) {
    // Document IDs can't contain '/'. Keep it stable and searchable.
    final key = (ticketNumber == null || ticketNumber.isEmpty)
        ? imagePath
        : ticketNumber;
    return key.replaceAll('/', '_');
  }

  static Future<int?> incrementAndGetCount({
    required String imagePath,
    required int delta,
    String? ticketNumber,
    int? setCount,
    int? prizeMillion,
    String? prizeText,
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      final uid = (user == null) ? null : user.uid.trim();
      if (uid == null || uid.isEmpty) {
        throw StateError('User must be authenticated to reserve tickets');
      }
      final ref = FirebaseFirestore.instance
          .collection(_collection)
          .doc(_docId(imagePath: imagePath, ticketNumber: ticketNumber));

      return FirebaseFirestore.instance.runTransaction<int>((tx) async {
        final snap = await tx.get(ref);
        final data = snap.data();

        final current = (data == null
                ? 0
                : (data['addedCount'] as num?)?.toInt() ?? 0)
            .clamp(0, 1 << 30);

        final lockedBy = (data == null)
          ? null
          : (data['lockedByUid'] as String?)?.trim();

        DateTime? lockedUntil;
        final lockedUntilRaw = data == null ? null : data['lockedUntil'];
        if (lockedUntilRaw is Timestamp) {
          lockedUntil = lockedUntilRaw.toDate();
        }
        // Back-compat: if older doc has no lockedUntil, infer from lastAddedAt.
        if (lockedUntil == null) {
          final lastAddedAtRaw = data == null ? null : data['lastAddedAt'];
          if (lastAddedAtRaw is Timestamp) {
            lockedUntil = lastAddedAtRaw.toDate().add(_lockDuration);
          }
        }

        final now = DateTime.now();
        final lockActive = current > 0 &&
            lockedUntil != null &&
            now.isBefore(lockedUntil);

        if (lockActive && lockedBy != null && lockedBy != uid) {
          throw const _TicketAlreadyReserved();
        }

        // If the same user is re-adding (should be rare), keep additive semantics.
        // Otherwise treat as a fresh reservation.
        final next = (lockedBy == uid && lockActive)
            ? (current + delta).clamp(0, 1 << 30)
            : delta.clamp(0, 1 << 30);

        final nextLockedUntil = now.add(_lockDuration);

        tx.set(ref, <String, Object?>{
          'ticketNumber': ticketNumber,
          'imagePath': imagePath,
          'addedCount': next,
          if (setCount != null) 'setCount': setCount,
          if (prizeMillion != null) 'prizeMillion': prizeMillion,
          if (prizeText != null && prizeText.isNotEmpty) 'prizeText': prizeText,
          'lockedByUid': uid,
          'lockedUntil': Timestamp.fromDate(nextLockedUntil),
          'lastAddedAt': FieldValue.serverTimestamp(),
          'lastAddedUid': uid,
          'lastAction': 'reserve',
        }, SetOptions(merge: true));

        return next;
      });
    } on _TicketAlreadyReserved {
      rethrow;
    } catch (e) {
      // Best-effort logging only (rules/auth may block in production).
      if (kDebugMode) {
        debugPrint('Firestore incrementAndGetCount failed: $e');
      }
      return null;
    }
  }
}

class _TicketAlreadyReserved implements Exception {
  const _TicketAlreadyReserved();
}

class _CountdownRow extends StatelessWidget {
  const _CountdownRow({
    required this.days,
    required this.hours,
    required this.minutes,
    required this.seconds,
  });

  final int days;
  final int hours;
  final int minutes;
  final int seconds;

  @override
  Widget build(BuildContext context) {
    Widget colon() => Text(
      ':',
      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
        color: Colors.white,
        fontWeight: FontWeight.w900,
      ),
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _CountdownBox(value: days, label: 'วัน'),
        const SizedBox(width: 8),
        colon(),
        const SizedBox(width: 8),
        _CountdownBox(value: hours, label: 'ชั่วโมง'),
        const SizedBox(width: 8),
        colon(),
        const SizedBox(width: 8),
        _CountdownBox(value: minutes, label: 'นาที'),
        const SizedBox(width: 8),
        colon(),
        const SizedBox(width: 8),
        _CountdownBox(value: seconds, label: 'วินาที'),
      ],
    );
  }
}

class _CountdownBox extends StatelessWidget {
  const _CountdownBox({required this.value, required this.label});

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 74,
        padding: const EdgeInsets.symmetric(vertical: 10),
        color: Colors.white,
        child: Column(
          children: [
            Text(
              value.toString().padLeft(2, '0'),
              style: textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w900,
                color: Colors.red,
              ),
            ),
            Text(
              label,
              style: textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w900,
                color: Colors.red,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TicketCardPlaceholder extends StatelessWidget {
  const _TicketCardPlaceholder({
    this.imagePath,
    this.onAddToCart,
    this.onInvalidPath,
  });
  final String? imagePath;
  final Future<void> Function()? onAddToCart;
  final ValueChanged<String>? onInvalidPath;

  static final Set<String> _reportedInvalidPaths = <String>{};

  @override
  Widget build(BuildContext context) {
    if (imagePath == null) {
      // No image => don't render any frame/button.
      return const SizedBox.shrink();
    }

    if (!_BuyLotteryScreenState._firebaseStorageSupported) {
      return const SizedBox.shrink();
    }

    final t = Theme.of(context).textTheme;
    const bottomBarHeight = 26.0;
    const bottomBarLift = 0.0;

    Widget buildCard({required Widget image}) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          color: Colors.white,
          child: Stack(
            children: [
              Positioned.fill(child: image),

              // Existing grey strip (button) kept inside the same frame.
              Positioned(
                left: 0,
                right: 0,
                bottom: bottomBarLift,
                height: bottomBarHeight,
                child: Material(
                  color: Colors.grey.shade400,
                  child: InkWell(
                    onTap: onAddToCart == null
                        ? null
                        : () => unawaited(onAddToCart!.call()),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.shopping_cart_outlined,
                          size: 18,
                          color: onAddToCart == null
                              ? Colors.grey.shade600
                              : Colors.grey.shade900,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'หยิบใส่ตะกร้า',
                          style: t.labelLarge?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: onAddToCart == null
                                ? Colors.grey.shade600
                                : Colors.grey.shade900,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Use a cached download URL Future so it doesn't restart on rebuild.
    return FutureBuilder<String>(
      future: _FirebaseStorageTicketImage.downloadUrlFutureForPath(imagePath!),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          // Keep the tile size stable while loading (prevents flicker/jank).
          return buildCard(
            image: const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        final url = snapshot.data;
        if (url == null || snapshot.hasError) {
          // No image => don't render any frame/button.
          final cb = onInvalidPath;
          if (cb != null && _reportedInvalidPaths.add(imagePath!)) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              cb(imagePath!);
            });
          }
          return const SizedBox.shrink();
        }

        return buildCard(
          image: _FirebaseStorageTicketImage(
            path: imagePath!,
            urlOverride: url,
            onLoadFailedPath: onInvalidPath,
          ),
        );
      },
    );
  }
}

class _TicketMeta {
  const _TicketMeta({
    required this.setCount,
    required this.prizeMillion,
    required this.prizeText,
  });

  const _TicketMeta.fallback()
    : setCount = 8,
      prizeMillion = 48,
      prizeText = 'ล้าน';

  final int setCount;
  final int prizeMillion;
  final String prizeText;
}

class _TicketMetaCollection {
  static const String _collection = 'ticket_catalog';
  // In production, setCount is stored in this collection (see Firestore screenshot):
  // collection: lottery, fields: digits ("658014"), setCount ("1"), prizeAmount ("6"), ...
  static const String _fallbackCollection = 'lottery';

  static String _baseNameNoExt(String imagePath) {
    final last = imagePath.split('/').last;
    final dot = last.lastIndexOf('.');
    if (dot <= 0) return last;
    return last.substring(0, dot);
  }

  static String _docId({required String imagePath, String? ticketNumber}) {
    final key = (ticketNumber == null || ticketNumber.isEmpty)
        ? imagePath
        : ticketNumber;
    return key.replaceAll('/', '_');
  }

  static Future<_TicketMeta> get({
    required String imagePath,
    required String? ticketNumber,
  }) async {
    try {
      final col = FirebaseFirestore.instance.collection(_collection);

      Map<String, dynamic>? data;
      if (ticketNumber != null && ticketNumber.trim().isNotEmpty) {
        final snap = await col
            .doc(_docId(imagePath: imagePath, ticketNumber: ticketNumber))
            .get();
        data = snap.data();
      }

      // Fallback: some catalogs may be keyed by imagePath rather than ticketNumber.
      if (data == null) {
        final snap = await col
            .doc(_docId(imagePath: imagePath, ticketNumber: null))
            .get();
        data = snap.data();
      }

      // Fallback (preferred for this project): collection `lottery` docId matches the file name
      // (e.g. `658014_1766929128526_001`). This avoids relying on parsing 6-digit groups.
      if (data == null) {
        try {
          final docId = _baseNameNoExt(imagePath);
          final snap = await FirebaseFirestore.instance
              .collection(_fallbackCollection)
              .doc(docId)
              .get();
          data = snap.data();
        } catch (e) {
          if (kDebugMode) {
            debugPrint('Ticket meta fallback doc lookup failed: $e');
          }
        }
      }

      // Fallback: some projects store the meta in collection `lottery` keyed by a generated id,
      // and queryable by field `digits`.
      if (data == null &&
          ticketNumber != null &&
          ticketNumber.trim().isNotEmpty &&
          ticketNumber.trim().length == 6) {
        try {
          final snap = await FirebaseFirestore.instance
              .collection(_fallbackCollection)
              .where('digits', isEqualTo: ticketNumber.trim())
              .limit(1)
              .get();
          if (snap.docs.isNotEmpty) {
            data = snap.docs.first.data();
          }
        } catch (e) {
          if (kDebugMode) {
            debugPrint('Ticket meta fallback query failed: $e');
          }
        }
      }

      int? toInt(dynamic v) {
        if (v == null) return null;
        if (v is num) return v.toInt();
        if (v is String) return int.tryParse(v.trim());
        return null;
      }

      final setCount =
          toInt(data?['setCount']) ??
          toInt(data?['set_count']) ??
          toInt(data?['qty']) ??
          8;
      final prizeMillion =
          toInt(data?['prizeMillion']) ??
          toInt(data?['prize']) ??
          toInt(data?['prizeAmount']) ??
          48;
      final prizeText = (data?['prizeText'] as String?) ?? 'ล้าน';

      return _TicketMeta(
        setCount: setCount,
        prizeMillion: prizeMillion,
        prizeText: prizeText,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Ticket meta fetch failed: $e');
      }
      return const _TicketMeta.fallback();
    }
  }
}

class _BuyBottomNavBar extends StatelessWidget {
  const _BuyBottomNavBar({
    required this.currentIndex,
    required this.cartCount,
    required this.onChanged,
  });

  final int currentIndex;
  final int cartCount;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return BottomNavigationBar(
      currentIndex: currentIndex,
      type: BottomNavigationBarType.fixed,
      selectedItemColor: Colors.red,
      unselectedItemColor: Colors.grey.shade700,
      selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w900),
      unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w800),
      onTap: onChanged,
      items: [
        const BottomNavigationBarItem(icon: Icon(Icons.home), label: 'หน้าแรก'),
        const BottomNavigationBarItem(
          icon: Icon(Icons.receipt_long),
          label: 'คำสั่งซื้อ',
        ),
        BottomNavigationBarItem(
          icon: Stack(
            clipBehavior: Clip.none,
            children: [
              const Icon(Icons.shopping_cart_outlined),
              if (cartCount > 0)
                Positioned(
                  right: -8,
                  top: -6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.rectangle,
                      borderRadius: BorderRadius.all(Radius.circular(999)),
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 18,
                      minHeight: 18,
                    ),
                    child: Text(
                      cartCount > 99 ? '99+' : '$cartCount',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          label: 'ตะกร้า',
        ),
        const BottomNavigationBarItem(
          icon: Icon(Icons.ondemand_video_outlined),
          label: 'ตู้เชฟ',
        ),
        const BottomNavigationBarItem(
          icon: Icon(Icons.person_outline),
          label: 'สมาชิก',
        ),
      ],
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: SizedBox(
        height: 44,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            backgroundColor: selected ? Colors.red : Colors.white,
            foregroundColor: selected ? Colors.white : Colors.red,
            side: const BorderSide(color: Colors.red),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          onPressed: onTap,
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
        ),
      ),
    );
  }
}

class _FirebaseStorageTicketImage extends StatelessWidget {
  const _FirebaseStorageTicketImage({
    required this.path,
    this.urlOverride,
    this.onLoadFailedPath,
  });

  final String path;
  final String? urlOverride;
  final ValueChanged<String>? onLoadFailedPath;

  static final Map<String, Future<String>> _downloadUrls =
      <String, Future<String>>{};
  static final Set<String> _loggedIntrinsicSizeForPaths = <String>{};
  static final Set<String> _loggedLayoutSizeForPaths = <String>{};
  static final Set<String> _reportedLoadFailedPaths = <String>{};

  static Future<String> downloadUrlFutureForPath(String path) {
    return _downloadUrls.putIfAbsent(
      path,
    () => FirebaseStorage.instance.ref(path).getDownloadURL(),
    );
  }

  Future<String> _getDownloadUrl() {
    final override = urlOverride;
    if (override != null && override.isNotEmpty) {
      return Future<String>.value(override);
    }
    return downloadUrlFutureForPath(path);
  }

  void _debugLogLayoutConstraints(BoxConstraints constraints) {
    if (!kDebugMode) return;
    if (!_loggedLayoutSizeForPaths.add(path)) return;
    final size = constraints.biggest;
    debugPrint(
      'Ticket image layout for "$path": ${size.width.toStringAsFixed(1)} x ${size.height.toStringAsFixed(1)} logical px',
    );
  }

  void _debugLogIntrinsicPixelsOnce(String url) {
    if (!kDebugMode) return;
    if (!_loggedIntrinsicSizeForPaths.add(path)) return;

    final provider = NetworkImage(url);
    final stream = provider.resolve(const ImageConfiguration());
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (imageInfo, synchronousCall) {
        final w = imageInfo.image.width;
        final h = imageInfo.image.height;
        debugPrint('Ticket image intrinsic for "$path": $w x $h px');
        stream.removeListener(listener);
      },
      onError: (error, stackTrace) {
        debugPrint('Ticket image intrinsic read failed for "$path": $error');
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;

    if (!_BuyLotteryScreenState._firebaseStorageSupported) {
      return Center(
        child: Text(
          'ไม่รองรับบนอุปกรณ์นี้',
          textAlign: TextAlign.center,
          style: t.bodySmall?.copyWith(
            color: Colors.grey.shade700,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
    }

    Widget buildImageFromUrl(String url) {
      _debugLogIntrinsicPixelsOnce(url);
      return LayoutBuilder(
        builder: (context, constraints) {
          _debugLogLayoutConstraints(constraints);
          return SizedBox.expand(
            child: Image.network(
              url,
              // Keep the whole ticket visible (no crop).
              fit: BoxFit.contain,
              alignment: Alignment.center,
              gaplessPlayback: true,
              errorBuilder: (context, error, stackTrace) {
                final cb = onLoadFailedPath;
                if (cb != null && _reportedLoadFailedPaths.add(path)) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    cb(path);
                  });
                }
                return Center(
                  child: Text(
                    'โหลดรูปไม่สำเร็จ',
                    textAlign: TextAlign.center,
                    style: t.bodySmall?.copyWith(
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                );
              },
            ),
          );
        },
      );
    }

    final override = urlOverride;
    if (override != null && override.isNotEmpty) {
      return buildImageFromUrl(override);
    }

    return FutureBuilder<String>(
      future: _getDownloadUrl(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }

        final url = snapshot.data;
        if (url == null || snapshot.hasError) {
          return Center(
            child: Text(
              'ไม่พบรูป',
              textAlign: TextAlign.center,
              style: t.bodySmall?.copyWith(
                color: Colors.grey.shade700,
                fontWeight: FontWeight.w800,
              ),
            ),
          );
        }

        return buildImageFromUrl(url);
      },
    );
  }
}

class _BuyDigitBox extends StatelessWidget {
  const _BuyDigitBox({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.hintText,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final String hintText;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 46,
      height: 54,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(1),
        ],
        decoration: InputDecoration(
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          hintText: hintText,
          hintStyle: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: Colors.grey.shade300,
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
        ),
        onChanged: onChanged,
      ),
    );
  }
}

class _HeaderLogo extends StatelessWidget {
  const _HeaderLogo._({required this.size});

  final double size;

  factory _HeaderLogo.small() => const _HeaderLogo._(size: 34);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.asset('assets/icons/app_icon.png', fit: BoxFit.cover),
    );
  }
}
