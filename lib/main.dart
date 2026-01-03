import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'check_lottery_screen.dart';
import 'buy_lottery_screen.dart';
import 'cart_controller.dart';
import 'cart_scope.dart';
import 'admin_support_screens.dart';

import 'login_screen.dart';

import 'pdf_cache/pdf_cache.dart';

const MethodChannel _notificationsChannel = MethodChannel('tungtong/notifications');

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Ensure Firebase is initialized for background isolate.
  try {
    await Firebase.initializeApp();
  } catch (_) {
    // Best-effort only.
  }
}

bool _isFcmSupportedPlatform() {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final isFirebaseSupported =
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);
  if (isFirebaseSupported) {
    await Firebase.initializeApp();

    if (_isFcmSupportedPlatform()) {
      try {
        FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
      } catch (_) {
        // Best-effort only.
      }
    }

    // App Check: in debug use debug provider; in release use Play Integrity / DeviceCheck.
    // This avoids "No AppCheckProvider installed" and supports projects that enforce App Check.
    try {
      await FirebaseAppCheck.instance.activate(
        providerAndroid: kDebugMode
            ? const AndroidDebugProvider()
            : const AndroidPlayIntegrityProvider(),
        providerApple: kDebugMode
            ? const AppleDebugProvider()
            : const AppleDeviceCheckProvider(),
      );
    } catch (_) {
      // Best-effort only.
    }

    // Storage rules often require an authenticated user. Use anonymous auth silently
    // so guests can browse/add to cart without seeing a login screen.
    await _ensureAnonymousAuthIfNeeded();
  }

  runApp(const App());
}

bool _isFirestorePermissionDenied(Object? e) {
  return e is FirebaseException && e.code == 'permission-denied';
}

Future<bool> _ensureAnonymousAuthIfNeeded() async {
  try {
    final auth = FirebaseAuth.instance;
    if (auth.currentUser == null) {
      await auth.signInAnonymously();
    }
    return auth.currentUser != null;
  } catch (e) {
    if (kDebugMode) {
      debugPrint('Anonymous sign-in failed: $e');
    }
    // Best-effort only. If Storage rules allow public read, this isn't needed.
    return false;
  }
}

class App extends StatefulWidget {
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  final _cartController = CartController();

  final GlobalKey<ScaffoldMessengerState> _scaffoldMessengerKey =
      GlobalKey<ScaffoldMessengerState>();

  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  StreamSubscription<User?>? _authSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _notificationsSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _supportRepliesSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _supportChatDocSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _storeConfigSub;
  StreamSubscription<String>? _fcmTokenRefreshSub;
  StreamSubscription<RemoteMessage>? _fcmOpenedSub;
  StreamSubscription<RemoteMessage>? _fcmMessageSub;
  bool _handledInitialFcmOpen = false;

  VoidCallback? _cartChangeListener;
  Timer? _cartMirrorDebounce;
  bool _cartMirrorSyncing = false;
  bool _retryingStreamsForAuth = false;

  String? _cachedProfileUid;
  Map<String, dynamic>? _cachedProfile;
  DateTime? _cachedProfileFetchedAt;

  String? _currentUid;
  bool _notificationsInitialized = false;
  final Set<String> _shownNotificationIds = <String>{};

  bool _supportRepliesInitialized = false;
  String? _supportRepliesUid;
  final Set<String> _shownSupportMessageIds = <String>{};

  bool _supportChatInitialized = false;
  String? _supportChatUid;
  Timestamp? _lastNotifiedSupportChatAt;

  static const String _notificationsCollection = 'notifications';
  static const String _supportChatsCollection = 'support_chats';
  static const String _supportMessagesSubcollection = 'messages';
  static const String _ticketCartCountsCollection = 'ticket_cart_counts';
  static const String _storeConfigCollection = 'app_config';
  static const String _storeConfigDoc = 'global';
  static const String _userProfilesCollection = 'users';
  static const String _adminCartCollection = 'user_carts';

  @override
  void initState() {
    super.initState();
    _currentUid = FirebaseAuth.instance.currentUser?.uid;
    _configureCartExpiry();
    _startCartMirrorToFirestore();
    _listenAuth();
    _listenNotifications();
    _listenSupportReplies();
    _listenSupportChatDoc();
    _listenStoreConfigForCartExpiry();

    if (_isFcmSupportedPlatform()) {
      unawaited(_initPushNotifications());
    }
  }

  Future<void> _initPushNotifications() async {
    if (!_isFcmSupportedPlatform()) return;

    // Android 13+: request runtime notification permission.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _notificationsChannel.invokeMethod<bool>('requestPermission');
      } catch (_) {
        // Best-effort only.
      }
    }

    // iOS: request permission.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      try {
        await FirebaseMessaging.instance.requestPermission(
          alert: true,
          badge: true,
          sound: true,
        );
      } catch (_) {
        // Best-effort only.
      }
    }

    await _syncFcmTokenToFirestore();

    // If the app was opened from a notification tap (terminated state), route now.
    await _handleInitialFcmOpen();

    // If the app is in background and user taps the notification, route to chat.
    _fcmOpenedSub?.cancel();
    _fcmOpenedSub = FirebaseMessaging.onMessageOpenedApp.listen((message) {
      if (_isSupportReplyPush(message)) {
        _openSupportChat();
      }
    });

    // Foreground push: no call handling.
    _fcmMessageSub?.cancel();
    _fcmMessageSub = FirebaseMessaging.onMessage.listen((message) {
      // Intentionally no-op.
    });

    _fcmTokenRefreshSub?.cancel();
    _fcmTokenRefreshSub = FirebaseMessaging.instance.onTokenRefresh.listen((token) {
      unawaited(_syncFcmTokenToFirestore(tokenOverride: token));
    });
  }

  bool _isSupportReplyPush(RemoteMessage message) {
    final kind = (message.data['kind'] ?? '').toString().trim();
    return kind == 'support_reply';
  }

  Future<void> _handleInitialFcmOpen() async {
    if (_handledInitialFcmOpen) return;
    _handledInitialFcmOpen = true;

    try {
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial == null) return;

      // Ensure Navigator is ready.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_isSupportReplyPush(initial)) {
          _openSupportChat();
          return;
        }
      });
    } catch (_) {
      // Best-effort only.
    }
  }

  Future<void> _syncFcmTokenToFirestore({String? tokenOverride}) async {
    if (!_isFcmSupportedPlatform()) return;

    final uid = (_currentUid ?? '').trim();
    if (uid.isEmpty) return;

    String? token = tokenOverride;
    try {
      token ??= await FirebaseMessaging.instance.getToken();
    } catch (_) {
      // Best-effort only.
      return;
    }

    token = (token ?? '').trim();
    if (token.isEmpty) return;

    try {
      await FirebaseFirestore.instance.collection(_userProfilesCollection).doc(uid).set(
        {
          'fcmTokens': FieldValue.arrayUnion([token]),
          'fcmUpdatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    } catch (_) {
      // Best-effort only.
    }
  }

  void _startCartMirrorToFirestore() {
    _cartChangeListener ??= () {
      _scheduleCartMirrorSync();
    };
    _cartController.addListener(_cartChangeListener!);

    // Initial best-effort sync (e.g. if cart is pre-populated).
    _scheduleCartMirrorSync();
  }

  void _scheduleCartMirrorSync() {
    _cartMirrorDebounce?.cancel();
    _cartMirrorDebounce = Timer(const Duration(milliseconds: 450), () {
      unawaited(_syncCartMirrorNow());
    });
  }

  String? _pickFirstNonEmptyString(List<Object?> candidates) {
    for (final v in candidates) {
      if (v == null) continue;
      final s = v.toString().trim();
      if (s.isEmpty) continue;
      if (s.toLowerCase() == 'null') continue;
      return s;
    }
    return null;
  }

  Future<Map<String, dynamic>?> _fetchUserProfile(String uid) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection(_userProfilesCollection)
          .doc(uid)
          .get();
      return snap.data();
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _getCachedUserProfile(String uid) async {
    final id = uid.trim();
    if (id.isEmpty) return null;

    final cachedFresh =
        _cachedProfileUid == id &&
        _cachedProfileFetchedAt != null &&
        DateTime.now().difference(_cachedProfileFetchedAt!) <
            const Duration(minutes: 5);
    if (cachedFresh) return _cachedProfile;

    final profile = await _fetchUserProfile(id);
    _cachedProfileUid = id;
    _cachedProfile = profile;
    _cachedProfileFetchedAt = DateTime.now();
    return profile;
  }

  String? _authEmailFromProviders(User user) {
    final candidates = <Object?>[
      user.email,
      for (final p in user.providerData) p.email,
    ];
    return _pickFirstNonEmptyString(candidates);
  }

  Future<String?> _resolveUserEmailForCartMirror(User user) async {
    final uid = user.uid.trim();
    if (uid.isEmpty) return null;

    final authEmail = _authEmailFromProviders(user);
    if (authEmail != null) return authEmail;

    // If user is anonymous, we generally won't have an email.
    // Still attempt profile lookup in case the app stored one.

    final profile = await _getCachedUserProfile(uid);
    final profileEmail = profile == null
        ? null
        : _pickFirstNonEmptyString([
            profile['email'],
            profile['userEmail'],
            profile['emailAddress'],
            profile['mail'],
            profile['user_email'],
            profile['userMail'],
          ]);
    return profileEmail;
  }

  Future<String?> _resolveUserPhoneForCartMirror(User user) async {
    final uid = user.uid.trim();
    if (uid.isEmpty) return null;

    final authPhone = (user.phoneNumber ?? '').trim();
    if (authPhone.isNotEmpty) return authPhone;

    final profile = await _getCachedUserProfile(uid);
    final profilePhone = profile == null
        ? null
        : _pickFirstNonEmptyString([
            profile['phone'],
            profile['phoneNumber'],
            profile['tel'],
            profile['mobile'],
            profile['userPhone'],
          ]);
    return profilePhone;
  }

  Map<String, Object?> _cartItemToAdminMap(CartItem item) {
    final digits6 = _extractDigits6(
      displayName: item.displayName,
      imagePath: item.imagePath,
    );
    return <String, Object?>{
      'itemId': item.id,
      'digits': digits6,
      'displayName': item.displayName,
      'imagePath': item.imagePath,
      'quantity': item.quantity,
      'addedAt': Timestamp.fromDate(item.addedAt),
    };
  }

  Future<void> _syncCartMirrorNow() async {
    if (_cartMirrorSyncing) return;
    _cartMirrorSyncing = true;
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final uid = user.uid.trim();
      if (uid.isEmpty) return;

      final items = _cartController.items;
      final doc = FirebaseFirestore.instance
          .collection(_adminCartCollection)
          .doc(uid);

      if (items.isEmpty) {
        try {
          await doc.delete();
        } catch (_) {
          // Best-effort only.
        }
        return;
      }

        final email = await _resolveUserEmailForCartMirror(user);
          final phone = await _resolveUserPhoneForCartMirror(user);

          final providerIds = user.providerData
              .map((p) => p.providerId.trim())
              .where((v) => v.isNotEmpty)
            .toSet()
            .toList(growable: false);
          providerIds.sort();

      final cartStartedAt = _cartController.cartStartedAt;
      final payload = <String, Object?>{
        'uid': uid,
        'email': email,
        'phoneNumber': phone,
        'displayName': (user.displayName ?? '').trim().isEmpty
            ? null
            : user.displayName,
        'providerIds': providerIds,
        'isAnonymous': user.isAnonymous,
        'totalTickets': _cartController.count,
        'cartStartedAt': cartStartedAt == null
            ? null
            : Timestamp.fromDate(cartStartedAt),
        'items': items.map(_cartItemToAdminMap).toList(growable: false),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      await doc.set(payload, SetOptions(merge: true));
    } catch (e) {
      // Best-effort only.
      if (kDebugMode) {
        debugPrint('Firestore cart mirror failed: $e');
      }
    } finally {
      _cartMirrorSyncing = false;
    }
  }

  void _configureCartExpiry() {
    _cartController.setOnExpired((cart) async {
      // Snapshot items first (handler may clear the cart).
      final items = cart.items;
      if (items.isEmpty) return;

      await _releaseReservedTicketsToShop(items);
      cart.clear();

      _showInAppNotification(
        title: 'หมดเวลา 15 นาที',
        body: 'คืนสลากกลับหน้าซื้อแล้ว',
      );
    });
  }

  void _listenStoreConfigForCartExpiry() {
    _storeConfigSub?.cancel();
    try {
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
            _cartController.setStoreOpen(open);
          }, onError: (Object error, StackTrace stackTrace) {
            if (kDebugMode) {
              debugPrint('Cart-expiry store config stream error: $error');
            }

            if (_isFirestorePermissionDenied(error) && !_retryingStreamsForAuth) {
              _retryingStreamsForAuth = true;
              unawaited(_ensureAnonymousAuthIfNeeded().then((ok) {
                _retryingStreamsForAuth = false;
                if (!ok) {
                  _showInAppNotification(
                    title: 'สิทธิ์ไม่พอ',
                    body: 'กรุณาเปิด Anonymous Sign-in ใน Firebase Auth',
                  );
                  return;
                }
                _listenStoreConfigForCartExpiry();
              }));
              return;
            }

            _showInAppNotification(
              title: 'โหลดสถานะร้านไม่สำเร็จ',
              body: '',
            );
          });
    } catch (_) {
      // Best-effort only.
    }
  }

  String? _extractDigits6({required String displayName, String? imagePath}) {
    final m = RegExp(r'\d{6}').firstMatch(displayName);
    if (m != null) return m.group(0);

    if (imagePath != null && imagePath.trim().isNotEmpty) {
      final last = imagePath.split('/').last;
      final leading = RegExp(r'^(\d{6})(?=[^\d]|$)').firstMatch(last);
      if (leading != null) return leading.group(1);

      final any = RegExp(r'\d{6}').firstMatch(last);
      if (any != null) return any.group(0);
    }

    return null;
  }

  String _ticketCartDocId({required String imagePath, String? ticketNumber}) {
    final key = (ticketNumber == null || ticketNumber.trim().isEmpty)
        ? imagePath
        : ticketNumber.trim();
    return key.replaceAll('/', '_');
  }

  Future<void> _releaseReservedTicketsToShop(List<CartItem> items) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    for (final item in items) {
      final imagePath = (item.imagePath ?? '').trim();
      if (imagePath.isEmpty) continue;

      final digits6 = _extractDigits6(
        displayName: item.displayName,
        imagePath: item.imagePath,
      );

      final qty = item.quantity.clamp(1, 999999).toInt();
      final ref = FirebaseFirestore.instance
          .collection(_ticketCartCountsCollection)
          .doc(_ticketCartDocId(imagePath: imagePath, ticketNumber: digits6));

      try {
        await FirebaseFirestore.instance.runTransaction<void>((tx) async {
          final snap = await tx.get(ref);
          final data = snap.data();
          final lockedBy = (data == null)
              ? null
              : (data['lockedByUid'] as String?)?.trim();
          // Only unlock if the current user owns the lock.
          if (lockedBy != null && lockedBy.isNotEmpty && lockedBy != uid) {
            return;
          }

          // This project treats a cart reservation as exclusive, so release -> 0.
          final next = 0;
          tx.set(ref, <String, Object?>{
            'ticketNumber': digits6,
            'imagePath': imagePath,
            'addedCount': next,
            'setCount': qty,
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

  void _listenAuth() {
    _authSub?.cancel();
    _authSub = FirebaseAuth.instance.userChanges().listen((user) {
      final next = user?.uid;
      final uidChanged = next != _currentUid;
      _currentUid = next;
      if (uidChanged) {
        _cachedProfileUid = null;
        _cachedProfile = null;
        _cachedProfileFetchedAt = null;
        _listenSupportReplies();
        _listenSupportChatDoc();

        if (_isFcmSupportedPlatform()) {
          unawaited(_syncFcmTokenToFirestore());
        }
      }
      // Always resync on any user profile/provider change.
      _scheduleCartMirrorSync();
    });
  }

  void _listenSupportChatDoc() {
    _supportChatDocSub?.cancel();
    _supportChatDocSub = null;

    final uid = (_currentUid ?? '').trim();
    _supportChatUid = uid.isEmpty ? null : uid;
    _supportChatInitialized = false;
    _lastNotifiedSupportChatAt = null;

    if (uid.isEmpty) return;

    try {
      _supportChatDocSub = FirebaseFirestore.instance
          .collection(_supportChatsCollection)
          .doc(uid)
          .snapshots()
          .listen((snap) {
        final data = snap.data();
        if (data == null) return;

        final lastAt = data['lastMessageAt'];
        final lastMessageAt = lastAt is Timestamp ? lastAt : null;

        final role = (data['lastSenderRole'] as String?)?.trim().toLowerCase();
        final isAdmin = role == null || role.isEmpty ? true : role != 'user';

        // Ignore initial snapshot so existing lastMessage doesn't spam.
        if (!_supportChatInitialized || _supportChatUid != uid) {
          _supportChatInitialized = true;
          _supportChatUid = uid;
          _lastNotifiedSupportChatAt = lastMessageAt;
          return;
        }

        if (!isAdmin) return;
        if (lastMessageAt == null) return;

        final prev = _lastNotifiedSupportChatAt;
        if (prev != null && !lastMessageAt.toDate().isAfter(prev.toDate())) {
          return;
        }

        final preview = (data['lastMessagePreview'] as String?)?.trim();
        final lastMessage = (data['lastMessage'] as String?)?.trim();
        final body = (preview != null && preview.isNotEmpty)
            ? preview
            : (lastMessage ?? 'มีข้อความใหม่จากแอดมิน');

        _lastNotifiedSupportChatAt = lastMessageAt;
        _showSupportInAppNotification(body: body);
      }, onError: (Object error, StackTrace stackTrace) {
        if (kDebugMode) {
          debugPrint('Support chat doc stream error: $error');
        }
      });
    } catch (_) {
      // Best-effort only.
    }
  }

  bool _isAdminSupportMessage(Map<String, dynamic> data, String uid) {
    final role = (data['senderRole'] as String?)?.trim().toLowerCase();
    if (role != null && role.isNotEmpty) {
      return role != 'user';
    }

    // Fallback: if senderUid exists and matches current user, treat as user message.
    final senderUid = (data['senderUid'] as String?)?.trim() ?? '';
    if (senderUid.isNotEmpty) {
      return senderUid != uid;
    }

    // If senderUid is missing, it's almost certainly an admin/staff message.
    // (User-created messages are required by Firestore rules to include senderUid==uid.)
    return true;
  }

  void _listenSupportReplies() {
    _supportRepliesSub?.cancel();
    _supportRepliesSub = null;

    final uid = (_currentUid ?? '').trim();
    _supportRepliesUid = uid.isEmpty ? null : uid;
    _supportRepliesInitialized = false;
    _shownSupportMessageIds.clear();

    if (uid.isEmpty) return;

    try {
      _supportRepliesSub = FirebaseFirestore.instance
          .collection(_supportChatsCollection)
          .doc(uid)
          .collection(_supportMessagesSubcollection)
          .orderBy('createdAt', descending: true)
          .limit(50)
          .snapshots()
          .listen((snap) {
            // Ignore initial snapshot so older admin messages don't spam.
            if (!_supportRepliesInitialized || _supportRepliesUid != uid) {
              _supportRepliesInitialized = true;
              _supportRepliesUid = uid;
              for (final doc in snap.docs) {
                _shownSupportMessageIds.add(doc.id);
              }
              return;
            }

            for (final change in snap.docChanges) {
              if (change.type != DocumentChangeType.added) continue;
              final doc = change.doc;
              if (_shownSupportMessageIds.contains(doc.id)) continue;

              final data = doc.data();
              if (data == null) continue;

              if (kDebugMode) {
                debugPrint('Support message change (added): id=${doc.id} data=$data');
              }

              // Only notify for admin/staff replies.
              if (!_isAdminSupportMessage(data, uid)) {
                _shownSupportMessageIds.add(doc.id);
                continue;
              }

              final type = (data['type'] as String?)?.trim().toLowerCase() ?? 'text';
              String body = '';
              if (type == 'image') {
                body = 'แอดมินส่งรูปภาพ';
              } else {
                body = (data['text'] as String?)?.trim() ?? '';
              }

              _shownSupportMessageIds.add(doc.id);
              _showSupportInAppNotification(body: body);
            }
          }, onError: (Object error, StackTrace stackTrace) {
            if (kDebugMode) {
              debugPrint('Support replies stream error: $error');
            }
          });
    } catch (_) {
      // Best-effort only.
    }
  }

  bool _shouldShowNotification(Map<String, dynamic> data, String? uid) {
    // Optional flags.
    final active = data['active'];
    if (active is bool && active == false) return false;

    final audience = (data['audience'] as String?)?.trim().toLowerCase();
    if (audience == null || audience.isEmpty || audience == 'all') {
      return true;
    }

    if (audience == 'user') {
      final targetUid = (data['uid'] as String?)?.trim();
      if (uid == null || uid.isEmpty) return false;
      return targetUid != null && targetUid.isNotEmpty && targetUid == uid;
    }

    // Optional: audience='uids' with explicit list.
    if (audience == 'uids') {
      final uids = data['uids'];
      if (uids is List) {
        if (uid == null || uid.isEmpty) return false;
        return uids.contains(uid);
      }
    }

    return false;
  }

  void _showInAppNotification({required String title, required String body}) {
    final messenger = _scaffoldMessengerKey.currentState;
    if (messenger == null) return;

    final text = body.trim().isEmpty
        ? title.trim()
        : '${title.trim()}\n${body.trim()}';
    if (text.trim().isEmpty) return;

    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(text),
        duration: const Duration(milliseconds: 2400),
      ),
    );
  }

  void _openSupportChat() {
    final nav = _navigatorKey.currentState;
    if (nav == null) return;
    nav.push(MaterialPageRoute(builder: (_) => const _ContactSupportScreen()));
  }

  void _showSupportInAppNotification({required String body}) {
    // Disabled: user requested no in-app bottom banner for admin replies.
    // Push notifications (FCM) still handle background/lock-screen alerts.
    return;
  }

  void _listenNotifications() {
    _notificationsSub?.cancel();
    try {
      _notificationsSub = FirebaseFirestore.instance
          .collection(_notificationsCollection)
          .orderBy('createdAt', descending: true)
          .limit(50)
          .snapshots()
          .listen((snap) {
            // Ignore the initial snapshot so old notifications don't spam on app start.
            if (!_notificationsInitialized) {
              _notificationsInitialized = true;
              for (final doc in snap.docs) {
                _shownNotificationIds.add(doc.id);
              }
              return;
            }

            for (final change in snap.docChanges) {
              if (change.type != DocumentChangeType.added) continue;
              final doc = change.doc;
              if (_shownNotificationIds.contains(doc.id)) continue;

              final data = doc.data();
              if (data == null) continue;

              if (!_shouldShowNotification(data, _currentUid)) {
                _shownNotificationIds.add(doc.id);
                continue;
              }

              final title = (data['title'] as String?) ?? 'แจ้งเตือน';
              final body = (data['body'] as String?) ?? '';

              _shownNotificationIds.add(doc.id);
              _showInAppNotification(title: title, body: body);
            }
          }, onError: (Object error, StackTrace stackTrace) {
            if (kDebugMode) {
              debugPrint('Notifications stream error: $error');
            }
            if (_isFirestorePermissionDenied(error) && !_retryingStreamsForAuth) {
              _retryingStreamsForAuth = true;
              unawaited(_ensureAnonymousAuthIfNeeded().then((ok) {
                _retryingStreamsForAuth = false;
                if (!ok) {
                  _showInAppNotification(
                    title: 'สิทธิ์ไม่พอ',
                    body: 'กรุณาเปิด Anonymous Sign-in ใน Firebase Auth',
                  );
                  return;
                }
                _listenNotifications();
              }));
              return;
            }
          });
    } catch (_) {
      // Best-effort only.
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _notificationsSub?.cancel();
    _supportRepliesSub?.cancel();
    _supportChatDocSub?.cancel();
    _storeConfigSub?.cancel();
    _fcmTokenRefreshSub?.cancel();
    _fcmOpenedSub?.cancel();
    _fcmMessageSub?.cancel();
    _cartMirrorDebounce?.cancel();
    if (_cartChangeListener != null) {
      _cartController.removeListener(_cartChangeListener!);
    }
    _cartController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CartScope(
      controller: _cartController,
      child: MaterialApp(
        title: 'ถุงทอง ล็อตเตอรี่',
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: _scaffoldMessengerKey,
        navigatorKey: _navigatorKey,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.red),
          scaffoldBackgroundColor: Colors.grey.shade100,
          appBarTheme: const AppBarTheme(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
            elevation: 0,
          ),
        ),
        home: const HomeScreen(),
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _digitControllers = List<TextEditingController>.generate(
    6,
    (_) => TextEditingController(),
  );
  final _digitFocusNodes = List<FocusNode>.generate(6, (_) => FocusNode());

  bool _loadingDraws = false;
  String? _drawLoadError;
  List<GloDrawOption> _drawOptions = const [];
  String? _selectedDrawId;

  bool _homeChecking = false;
  String? _homeCheckError;
  LotteryCheckResult? _homeCheck;
  int _navIndex = 0;

  static const String _storeConfigCollection = 'app_config';
  static const String _storeConfigDoc = 'global';
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _storeConfigSub;
  bool _storeOpen = true;
  String _storeClosedMessage = 'ปิดร้านชั่วคราว';
  bool _retryingHomeConfigAuth = false;

  @override
  void initState() {
    super.initState();
    _loadDrawOptions();
    _listenStoreConfig();
  }

  void _listenStoreConfig() {
    try {
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
            if (!mounted) return;
            setState(() {
              _storeOpen = open;
              _storeClosedMessage = (note == null || note.isEmpty)
                  ? 'ปิดร้านชั่วคราว'
                  : note;
            });
          }, onError: (Object error, StackTrace stackTrace) {
            if (kDebugMode) {
              debugPrint('Home store config stream error: $error');
            }

            if (_isFirestorePermissionDenied(error) && !_retryingHomeConfigAuth) {
              _retryingHomeConfigAuth = true;
              unawaited(_ensureAnonymousAuthIfNeeded().then((ok) {
                _retryingHomeConfigAuth = false;
                if (!ok || !mounted) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'กรุณาเปิด Anonymous Sign-in ใน Firebase Auth เพื่อใช้งานแบบผู้เยี่ยมชม',
                      ),
                    ),
                  );
                  return;
                }
                _listenStoreConfig();
              }));
              return;
            }

            // Best-effort fallback.
            if (!mounted) return;
            setState(() {
              _storeOpen = true;
            });
          });
    } catch (_) {
      // Best-effort: if Firestore isn't available, default to open.
      _storeOpen = true;
    }
  }

  @override
  void dispose() {
    _storeConfigSub?.cancel();
    for (final c in _digitControllers) {
      c.dispose();
    }
    for (final f in _digitFocusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _loadDrawOptions() async {
    if (_loadingDraws) return;
    setState(() {
      _loadingDraws = true;
      _drawLoadError = null;
    });

    try {
      var options = await GloClient().fetchDrawOptions(
        firestoreLimit: 20,
        apiPages: 6,
        daysBack: 366,
      );

      if (options.isEmpty) {
        final latest = await GloClient().fetchLatestDraw(
          preferFirestore: false,
        );
        options = [
          GloDrawOption(
            id: 'latest',
            dateIso: DateTime.now().toUtc().toIso8601String().substring(0, 10),
            label: 'งวดล่าสุด: ${latest.drawDateText}',
            fromFirestore: false,
          ),
        ];
      }

      if (!mounted) return;
      setState(() {
        _drawOptions = options;
        _selectedDrawId = options.first.id;
      });

      // Best-effort: auto-download PDF for the latest Firestore draw.
      final first = options.first;
      if (first.fromFirestore) {
        final draw = await GloClient().fetchDrawById(first.id);
        unawaited(
          PdfCache.maybeAutoDownloadLatest(
            drawDateIso: draw.drawDateIso,
            storagePath: draw.pdfStoragePath,
            sha256: draw.pdfSha256,
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _drawLoadError = 'โหลดรายการงวดไม่สำเร็จ';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingDraws = false;
        });
      }
    }
  }

  void _onDigitChanged(int index, String value) {
    if (value.isNotEmpty && index < _digitFocusNodes.length - 1) {
      _digitFocusNodes[index + 1].requestFocus();
    }
    if (value.isEmpty && index > 0) {
      _digitFocusNodes[index - 1].requestFocus();
    }

    if (_homeCheck != null || _homeCheckError != null) {
      setState(() {
        _homeCheck = null;
        _homeCheckError = null;
      });
    }
  }

  String _ticketFromDigits() {
    return _digitControllers.map((c) => c.text.trim()).join();
  }

  Future<void> _checkTicketFromHome() async {
    if (_homeChecking) return;

    FocusManager.instance.primaryFocus?.unfocus();

    final ticket = _ticketFromDigits();
    if (!RegExp(r'^\d{6}$').hasMatch(ticket)) {
      setState(() {
        _homeCheck = LotteryCheckResult(
          ticketNumber: ticket,
          matches: const [],
          error: 'กรุณากรอกเลข 6 หลักให้ครบ',
        );
        _homeCheckError = null;
      });
      return;
    }

    setState(() {
      _homeChecking = true;
      _homeCheckError = null;
      _homeCheck = null;
    });

    try {
      final selectedId = _selectedDrawId;
      final draw = selectedId == null
          ? await GloClient().fetchLatestDraw()
          : await GloClient().fetchDrawById(selectedId);
      final matches = <PrizeMatch>[];

      if (ticket == draw.firstPrize) {
        matches.add(
          const PrizeMatch(label: 'รางวัลที่ 1', amountBaht: 6000000),
        );
      }

      if (draw.adjacentFirst.contains(ticket)) {
        matches.add(
          const PrizeMatch(
            label: 'รางวัลข้างเคียงรางวัลที่ 1',
            amountBaht: 100000,
          ),
        );
      }

      if (draw.prize2.contains(ticket)) {
        matches.add(const PrizeMatch(label: 'รางวัลที่ 2', amountBaht: 200000));
      }

      if (draw.prize3.contains(ticket)) {
        matches.add(const PrizeMatch(label: 'รางวัลที่ 3', amountBaht: 80000));
      }

      if (draw.prize4.contains(ticket)) {
        matches.add(const PrizeMatch(label: 'รางวัลที่ 4', amountBaht: 40000));
      }

      if (draw.prize5.contains(ticket)) {
        matches.add(const PrizeMatch(label: 'รางวัลที่ 5', amountBaht: 20000));
      }

      final front3 = ticket.substring(0, 3);
      final last3 = ticket.substring(3);
      final last2 = ticket.substring(4);

      if (draw.front3.contains(front3)) {
        matches.add(
          const PrizeMatch(label: 'รางวัลเลขหน้า 3 ตัว', amountBaht: 4000),
        );
      }

      if (draw.last3.contains(last3)) {
        matches.add(
          const PrizeMatch(label: 'รางวัลเลขท้าย 3 ตัว', amountBaht: 4000),
        );
      }

      if (draw.last2 == last2) {
        matches.add(
          const PrizeMatch(label: 'รางวัลเลขท้าย 2 ตัว', amountBaht: 2000),
        );
      }

      if (!mounted) return;
      setState(() {
        _homeCheck = LotteryCheckResult(ticketNumber: ticket, matches: matches);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _homeCheckError = 'ดึงข้อมูลผลรางวัลไม่สำเร็จ';
      });
    } finally {
      if (mounted) {
        setState(() {
          _homeChecking = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'ถุงทอง ล็อตเตอรี่',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        leadingWidth: 56,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: _LogoMark.small(),
        ),
      ),
      body: SafeArea(
        top: false,
        child: IndexedStack(
          index: _navIndex,
          children: [
            _HomeContent(
              drawOptions: _drawOptions,
              selectedDrawId: _selectedDrawId,
              loadingDraws: _loadingDraws,
              drawLoadError: _drawLoadError,
              onDrawChanged: (value) {
                if (value == null) return;
                setState(() {
                  _selectedDrawId = value;
                  _homeCheck = null;
                  _homeCheckError = null;
                });
              },
              digitControllers: _digitControllers,
              digitFocusNodes: _digitFocusNodes,
              onDigitChanged: _onDigitChanged,
              checking: _homeChecking,
              checkError: _homeCheckError,
              checkResult: _homeCheck,
              onCheckPressed: _checkTicketFromHome,
            ),
            const _PlaceholderTab(title: 'ข่าวสารสายมู'),
            const _PlaceholderTab(title: 'ซื้อสลากฯ'),
            CheckLotteryScreen(
              selectedDrawId: _selectedDrawId,
              drawOptions: _drawOptions,
              loadingDraws: _loadingDraws,
              drawLoadError: _drawLoadError,
              onDrawChanged: (value) {
                if (value == null) return;
                setState(() {
                  _selectedDrawId = value;
                });
              },
            ),
            _SettingsTab(onGoHome: () => setState(() => _navIndex = 0)),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.red,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        onPressed: () {
          if (!_storeOpen) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(_storeClosedMessage),
                backgroundColor: Colors.grey.shade900,
                duration: const Duration(milliseconds: 1400),
              ),
            );
            return;
          }

          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const BuyLotteryScreen()));
        },
        child: SizedBox.expand(
          child: Image.asset('assets/icons/app_icon.png', fit: BoxFit.cover),
        ),
      ),
      bottomNavigationBar: _BottomNavBar(
        currentIndex: _navIndex,
        onChanged: (i) => setState(() => _navIndex = i),
      ),
    );
  }
}

class _HomeContent extends StatelessWidget {
  const _HomeContent({
    required this.drawOptions,
    required this.selectedDrawId,
    required this.loadingDraws,
    required this.drawLoadError,
    required this.onDrawChanged,
    required this.digitControllers,
    required this.digitFocusNodes,
    required this.onDigitChanged,
    required this.checking,
    required this.checkError,
    required this.checkResult,
    required this.onCheckPressed,
  });

  final List<GloDrawOption> drawOptions;
  final String? selectedDrawId;
  final bool loadingDraws;
  final String? drawLoadError;
  final ValueChanged<String?> onDrawChanged;
  final List<TextEditingController> digitControllers;
  final List<FocusNode> digitFocusNodes;
  final void Function(int index, String value) onDigitChanged;
  final bool checking;
  final String? checkError;
  final LotteryCheckResult? checkResult;
  final VoidCallback onCheckPressed;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: [
          Stack(
            children: [
              Container(height: 210, color: Colors.red),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: _CheckLotteryCard(
                  drawOptions: drawOptions,
                  selectedDrawId: selectedDrawId,
                  loadingDraws: loadingDraws,
                  drawLoadError: drawLoadError,
                  onDrawChanged: onDrawChanged,
                  digitControllers: digitControllers,
                  digitFocusNodes: digitFocusNodes,
                  onDigitChanged: onDigitChanged,
                  checking: checking,
                  checkError: checkError,
                  checkResult: checkResult,
                  onCheckPressed: onCheckPressed,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                const _PromoCarousel(),
                const SizedBox(height: 18),
                const _ShortcutsRow(),
                const SizedBox(height: 18),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'ข่าวสารยอดนิยม',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: Colors.grey.shade900,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const _NewsPlaceholderCard(),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsTab extends StatefulWidget {
  const _SettingsTab({required this.onGoHome});

  final VoidCallback onGoHome;

  @override
  State<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<_SettingsTab> {
  bool _busy = false;
  bool _isAdmin = false;
  bool _adminChecked = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadAdminFlag());
  }

  Future<void> _loadAdminFlag() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        if (!mounted) return;
        setState(() {
          _isAdmin = false;
          _adminChecked = true;
        });
        return;
      }

      final token = await user.getIdTokenResult();
      final claims = token.claims ?? const <String, Object?>{};
      final admin = claims['admin'] == true ||
          (claims['role']?.toString().trim().toLowerCase() == 'admin');

      if (!mounted) return;
      setState(() {
        _isAdmin = admin;
        _adminChecked = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isAdmin = false;
        _adminChecked = true;
      });
    }
  }

  void _openContact() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const _ContactSupportScreen()),
    );
  }

  void _openAdminInbox() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AdminSupportInboxScreen()),
    );
  }

  Future<void> _signOut() async {
    if (_busy) return;
    setState(() => _busy = true);

    try {
      // Best-effort sign out from Google, if used.
      try {
        final googleSignIn = GoogleSignIn.instance;
        await googleSignIn.initialize();
        await googleSignIn.signOut();
      } catch (_) {
        // Best-effort.
      }

      await FirebaseAuth.instance.signOut();

      if (!mounted) return;
      final ok = await Navigator.of(context).push<bool>(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );

      if (ok == true && mounted) {
        widget.onGoHome();
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ออกจากระบบไม่สำเร็จ')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            if (_adminChecked && _isAdmin)
              SizedBox(
                height: 52,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: _openAdminInbox,
                  child: const Text(
                    'แชทลูกค้า (แอดมิน)',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
              ),
            if (_adminChecked && _isAdmin) const SizedBox(height: 12),
            SizedBox(
              height: 52,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: _openContact,
                child: const Text(
                  'ติดต่อ สอบถาม',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 52,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.red),
                  foregroundColor: Colors.red,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: _busy ? null : _signOut,
                child: Text(
                  _busy ? 'กำลังออกจากระบบ...' : 'ออกจากระบบ',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ContactSupportScreen extends StatefulWidget {
  const _ContactSupportScreen();

  @override
  State<_ContactSupportScreen> createState() => _ContactSupportScreenState();
}

class _ContactSupportScreenState extends State<_ContactSupportScreen> {
  final TextEditingController _chatController = TextEditingController();

  bool _sending = false;
  bool _sendingImage = false;
  String? _supportUid;

  static const String _supportChatsCollection = 'support_chats';
  static const String _supportMessagesSubcollection = 'messages';
  static const String _supportUploadsFolder = 'uploads';

  @override
  void initState() {
    super.initState();
    unawaited(_ensureSupportUserAndCacheUid());
  }

  @override
  void dispose() {
    _chatController.dispose();
    super.dispose();
  }

  Future<User?> _ensureSupportUser() async {
    final existing = FirebaseAuth.instance.currentUser;
    if (existing != null) return existing;
    try {
      final cred = await FirebaseAuth.instance.signInAnonymously();
      return cred.user;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Support chat anonymous sign-in failed: $e');
      }
      return null;
    }
  }

  Future<void> _ensureSupportUserAndCacheUid() async {
    final user = await _ensureSupportUser();
    final uid = user?.uid.trim() ?? '';
    if (!mounted) return;
    if (uid.isEmpty) return;
    setState(() {
      _supportUid = uid;
    });
  }

  DocumentReference<Map<String, dynamic>>? _chatDocRef() {
    final uid = (_supportUid ?? FirebaseAuth.instance.currentUser?.uid ?? '').trim();
    if (uid.isEmpty) return null;
    return FirebaseFirestore.instance.collection(_supportChatsCollection).doc(uid);
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> _messagesStream() {
    final ref = _chatDocRef();
    if (ref == null) {
      return const Stream.empty();
    }
    return ref
        .collection(_supportMessagesSubcollection)
        .orderBy('createdAt', descending: true)
        .limit(200)
        .snapshots();
  }

  Future<void> _send() async {
    if (_sending) return;
    final text = _chatController.text.trim();
    if (text.isEmpty) return;

    final user = await _ensureSupportUser();
    final uid = user?.uid.trim() ?? '';
    if (uid.isEmpty) return;
    if (_supportUid != uid) {
      setState(() {
        _supportUid = uid;
      });
    }

    setState(() => _sending = true);
    try {
      final chatRef = FirebaseFirestore.instance
          .collection(_supportChatsCollection)
          .doc(uid);
      await chatRef.set({
        'uid': uid,
        'userEmail': user?.email,
        'userPhone': user?.phoneNumber,
        'updatedAt': FieldValue.serverTimestamp(),
        'createdAt': FieldValue.serverTimestamp(),
        'lastMessage': text,
        'lastMessageAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await chatRef.collection(_supportMessagesSubcollection).add({
        'text': text,
        'senderUid': uid,
        'senderRole': 'user',
        'createdAt': FieldValue.serverTimestamp(),
        'type': 'text',
      });

      _chatController.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ส่งแล้ว')),
        );
      }
    } on FirebaseException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ส่งข้อความไม่สำเร็จ (${e.code})')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ส่งข้อความไม่สำเร็จ: $e')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickAndSendImage() async {
    if (_sendingImage) return;

    final user = await _ensureSupportUser();
    final uid = user?.uid.trim() ?? '';
    if (uid.isEmpty) return;
    if (_supportUid != uid) {
      setState(() {
        _supportUid = uid;
      });
    }

    Uint8List? bytes;
    String name = '';
    try {
      final isIOS = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
      final isAndroid = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

      // NOTE: On some Android builds, image_picker can throw a channel-error
      // (plugin channel not established). FilePicker is more reliable here.
      if (isIOS) {
        final picker = ImagePicker();
        final picked = await picker.pickImage(
          source: ImageSource.gallery,
          imageQuality: 85,
          maxWidth: 1600,
        );
        if (picked == null) return;
        name = picked.name;
        bytes = await picked.readAsBytes();
      } else if (isAndroid || kIsWeb || defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.linux) {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.image,
          allowMultiple: false,
          withData: true,
        );
        if (result == null || result.files.isEmpty) return;
        final file = result.files.single;
        name = file.name;
        bytes = file.bytes;
      } else {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.image,
          allowMultiple: false,
          withData: true,
        );
        if (result == null || result.files.isEmpty) return;
        final file = result.files.single;
        name = file.name;
        bytes = file.bytes;
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ไม่สามารถเลือกรูปได้: $e')),
      );
      return;
    }

    if (bytes == null || bytes.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ไฟล์รูปไม่ถูกต้อง')),
      );
      return;
    }

    setState(() => _sendingImage = true);
    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final fileName = name.trim().isEmpty ? 'image.jpg' : name.trim();
      final parts = fileName.split('.');
      final ext = (parts.length >= 2 ? parts.last : '').toLowerCase().trim();
      final safeExt = (ext.isEmpty || ext.length > 5) ? 'jpg' : ext;
      final storagePath = 'support_chats/$uid/$_supportUploadsFolder/$nowMs.$safeExt';

      final ref = FirebaseStorage.instance.ref().child(storagePath);
      final contentType = switch (safeExt) {
        'jpg' || 'jpeg' => 'image/jpeg',
        'png' => 'image/png',
        'webp' => 'image/webp',
        'gif' => 'image/gif',
        _ => 'image/jpeg',
      };
      final meta = SettableMetadata(
        contentType: contentType,
        customMetadata: <String, String>{
          'uid': uid,
          'source': 'support_chat',
        },
      );
      await ref.putData(bytes, meta);
      final url = await ref.getDownloadURL();

      final chatRef = FirebaseFirestore.instance
          .collection(_supportChatsCollection)
          .doc(uid);

      await chatRef.set({
        'uid': uid,
        'userEmail': user?.email,
        'userPhone': user?.phoneNumber,
        'updatedAt': FieldValue.serverTimestamp(),
        'createdAt': FieldValue.serverTimestamp(),
        'lastMessage': '[รูปภาพ]',
        'lastMessageAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await chatRef.collection(_supportMessagesSubcollection).add({
        'type': 'image',
        'imageUrl': url,
        'storagePath': storagePath,
        'senderUid': uid,
        'senderRole': 'user',
        'createdAt': FieldValue.serverTimestamp(),
      });
    } on FirebaseException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('อัปโหลดรูปไม่สำเร็จ (${e.code})')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('อัปโหลดรูปไม่สำเร็จ: $e')),
      );
    } finally {
      if (mounted) setState(() => _sendingImage = false);
    }
  }

  Widget _messageBubble({required String text, required bool isMe}) {
    final bg = isMe ? Colors.red.shade50 : Colors.grey.shade200;
    final align = isMe ? Alignment.centerRight : Alignment.centerLeft;
    final radius = BorderRadius.circular(14);

    return Align(
      alignment: align,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(color: bg, borderRadius: radius),
        child: Text(
          text,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Widget _imageBubble({required String url, required bool isMe}) {
    final bg = isMe ? Colors.red.shade50 : Colors.grey.shade200;
    final align = isMe ? Alignment.centerRight : Alignment.centerLeft;
    final radius = BorderRadius.circular(14);

    return Align(
      alignment: align,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        padding: const EdgeInsets.all(6),
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(color: bg, borderRadius: radius),
        child: ClipRRect(
          borderRadius: radius,
          child: Image.network(
            url,
            height: 220,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ติดต่อ สอบถาม'),
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _messagesStream(),
              builder: (context, snapshot) {
                final chatRef = _chatDocRef();
                if (chatRef == null) {
                  return const Center(
                    child: Text(
                      'กรุณาเข้าสู่ระบบก่อน',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                  );
                }

                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const SizedBox.shrink();
                }

                final docs = snapshot.data?.docs ?? const [];
                if (docs.isEmpty) {
                  return const SizedBox.shrink();
                }

                final uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
                return ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final data = docs[index].data();
                    final type = (data['type'] as String?)?.trim().toLowerCase() ?? 'text';
                    final senderUid = (data['senderUid'] as String?)?.trim() ?? '';
                    final isMe = senderUid.isNotEmpty && senderUid == uid;

                    if (type == 'image') {
                      final imageUrl = (data['imageUrl'] as String?)?.trim() ?? '';
                      if (imageUrl.isEmpty) return const SizedBox.shrink();
                      return _imageBubble(url: imageUrl, isMe: isMe);
                    }

                    final text = (data['text'] as String?)?.trim() ?? '';
                    if (text.isEmpty) return const SizedBox.shrink();
                    return _messageBubble(text: text, isMe: isMe);
                  },
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  SizedBox(
                    height: 48,
                    width: 48,
                    child: ElevatedButton(
                      onPressed: _sendingImage ? null : () => unawaited(_pickAndSendImage()),
                      style: ElevatedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Icon(Icons.image),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _chatController,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => unawaited(_send()),
                      decoration: InputDecoration(
                        hintText: 'พิมพ์ข้อความ...',
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 48,
                    width: 48,
                    child: ElevatedButton(
                      onPressed: _sending ? null : () => unawaited(_send()),
                      style: ElevatedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Icon(Icons.send),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckLotteryCard extends StatelessWidget {
  const _CheckLotteryCard({
    required this.drawOptions,
    required this.selectedDrawId,
    required this.loadingDraws,
    required this.drawLoadError,
    required this.onDrawChanged,
    required this.digitControllers,
    required this.digitFocusNodes,
    required this.onDigitChanged,
    required this.checking,
    required this.checkError,
    required this.checkResult,
    required this.onCheckPressed,
  });

  final List<GloDrawOption> drawOptions;
  final String? selectedDrawId;
  final bool loadingDraws;
  final String? drawLoadError;
  final ValueChanged<String?> onDrawChanged;
  final List<TextEditingController> digitControllers;
  final List<FocusNode> digitFocusNodes;
  final void Function(int index, String value) onDigitChanged;
  final bool checking;
  final String? checkError;
  final LotteryCheckResult? checkResult;
  final VoidCallback onCheckPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 6,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'ตรวจผลสลากกินแบ่งรัฐบาล',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
                color: Colors.red,
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey<String?>(selectedDrawId),
              initialValue: selectedDrawId,
              items: drawOptions
                  .map(
                    (e) => DropdownMenuItem<String>(
                      value: e.id,
                      child: Text(e.label, overflow: TextOverflow.ellipsis),
                    ),
                  )
                  .toList(),
              onChanged: loadingDraws ? null : onDrawChanged,
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.grey.shade50,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(28),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
              ),
            ),
            if (loadingDraws)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'กำลังโหลดงวด…',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey.shade700,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            if (drawLoadError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  drawLoadError!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.red,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List.generate(6, (i) {
                return _DigitBox(
                  controller: digitControllers[i],
                  focusNode: digitFocusNodes[i],
                  onChanged: (v) => onDigitChanged(i, v),
                );
              }),
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 50,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(26),
                  ),
                ),
                onPressed: checking ? null : onCheckPressed,
                child: Text(
                  checking ? 'กำลังตรวจ…' : 'ตรวจสลากฯ ของคุณ',
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
            if (checkError != null) ...[
              const SizedBox(height: 10),
              Text(
                checkError!,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: Colors.red),
              ),
            ],
            if (checkResult?.error != null) ...[
              const SizedBox(height: 10),
              Text(
                checkResult!.error!,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: Colors.red),
              ),
            ],
            if (checkResult != null && checkResult!.error == null) ...[
              const SizedBox(height: 10),
              Text(
                checkResult!.matches.isEmpty ? 'ไม่ถูกรางวัล' : 'ถูกรางวัล!',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: checkResult!.matches.isEmpty
                      ? Colors.grey.shade800
                      : Colors.green.shade800,
                ),
              ),
              const SizedBox(height: 2),
              Text('เลข ${checkResult!.ticketNumber}'),
              if (checkResult!.matches.isNotEmpty) ...[
                const SizedBox(height: 8),
                ...checkResult!.matches.map((m) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            '• ${m.label}',
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          '${_formatBaht(m.amountBaht)} บาท',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ],
                    ),
                  );
                }),
                const SizedBox(height: 8),
                Divider(color: Colors.grey.shade200, height: 1),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'รวม',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      '${_formatBaht(checkResult!.matches.fold<int>(0, (s, m) => s + m.amountBaht))} บาท',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

String _formatBaht(int value) {
  final s = value.toString();
  return s.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
}

class _DigitBox extends StatelessWidget {
  const _DigitBox({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;

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

class _PromoCarousel extends StatefulWidget {
  const _PromoCarousel();

  @override
  State<_PromoCarousel> createState() => _PromoCarouselState();
}

class _PromoCarouselState extends State<_PromoCarousel> {
  static const _autoSlideInterval = Duration(seconds: 4);
  static const _autoSlideDuration = Duration(milliseconds: 450);

  final _controller = PageController();

  final List<String> _assets = const [
    'assets/tt/file_00000000504c7206bc17e11932c03118.png',
    'assets/tt/file_00000000698c7206b6c59fb63ecbe6ef.png',
    'assets/tt/file_000000009df4720993867da268d9a032.png',
    'assets/tt/file_00000000a05c7207b18fe24326c0a7d5.png',
  ];

  Timer? _timer;
  int _activeIndex = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(_autoSlideInterval, (_) {
      if (!mounted || !_controller.hasClients || _assets.isEmpty) return;
      final nextIndex = (_activeIndex + 1) % _assets.length;
      _controller.animateToPage(
        nextIndex,
        duration: _autoSlideDuration,
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            height: 190,
            width: double.infinity,
            child: PageView.builder(
              controller: _controller,
              itemCount: _assets.length,
              onPageChanged: (index) {
                setState(() => _activeIndex = index);
              },
              itemBuilder: (context, index) {
                return Image.asset(
                  _assets[index],
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                );
              },
            ),
          ),
        ),
        const SizedBox(height: 12),
        _CarouselDots(count: _assets.length, activeIndex: _activeIndex),
      ],
    );
  }
}

class _CarouselDots extends StatelessWidget {
  const _CarouselDots({required this.count, required this.activeIndex});

  final int count;
  final int activeIndex;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final isActive = i == activeIndex;
        return Container(
          width: isActive ? 22 : 10,
          height: 10,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: isActive ? Colors.red : Colors.grey.shade400,
            borderRadius: BorderRadius.circular(99),
          ),
        );
      }),
    );
  }
}

class _ShortcutsRow extends StatelessWidget {
  const _ShortcutsRow();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: const [
        _ShortcutItem(icon: Icons.bedtime_outlined, label: 'ทำนายฝัน'),
        _ShortcutItem(icon: Icons.auto_awesome, label: 'เสี่ยงเซียมซี'),
        _ShortcutItem(icon: Icons.casino_outlined, label: 'สุ่มเลข'),
        _ShortcutItem(icon: Icons.qr_code_scanner, label: 'QR สุ่มเลข'),
      ],
    );
  }
}

class _ShortcutItem extends StatelessWidget {
  const _ShortcutItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          SizedBox(
            width: 56,
            height: 56,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Icon(icon, color: Colors.red),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: Colors.grey.shade900,
            ),
          ),
        ],
      ),
    );
  }
}

class _NewsPlaceholderCard extends StatelessWidget {
  const _NewsPlaceholderCard();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        height: 110,
        width: double.infinity,
        color: Colors.white,
        child: Row(
          children: [
            Container(
              width: 120,
              height: double.infinity,
              color: Colors.grey.shade200,
              alignment: Alignment.center,
              child: Text(
                'รูปข่าว\n(ใส่ทีหลัง)',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.grey.shade700,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 14,
                  horizontal: 4,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'พื้นที่หัวข้อข่าว (ใส่ทีหลัง)',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: Colors.grey.shade900,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'พื้นที่คำอธิบายข่าวสั้นๆ',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey.shade600,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomNavBar extends StatelessWidget {
  const _BottomNavBar({required this.currentIndex, required this.onChanged});

  final int currentIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return BottomAppBar(
      shape: const CircularNotchedRectangle(),
      notchMargin: 8,
      child: SizedBox(
        height: 72,
        child: Row(
          children: [
            _NavItem(
              icon: Icons.home,
              label: 'หน้าแรก',
              selected: currentIndex == 0,
              onTap: () => onChanged(0),
            ),
            _NavItem(
              icon: Icons.article_outlined,
              label: 'ข่าวสารสายมู',
              selected: currentIndex == 1,
              onTap: () => onChanged(1),
            ),
            const Expanded(
              child: Padding(
                padding: EdgeInsets.only(top: 38),
                child: Text(
                  'ซื้อสลากฯ',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11),
                ),
              ),
            ),
            _NavItem(
              icon: Icons.search,
              label: 'ตรวจสลากฯ',
              selected: currentIndex == 3,
              onTap: () => onChanged(3),
            ),
            _NavItem(
              icon: Icons.settings_outlined,
              label: 'ตั้งค่า',
              selected: currentIndex == 4,
              onTap: () => onChanged(4),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? Colors.red : Colors.grey.shade600;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaceholderTab extends StatelessWidget {
  const _PlaceholderTab({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w900,
          color: Colors.grey.shade800,
        ),
      ),
    );
  }
}

class _LogoMark extends StatelessWidget {
  const _LogoMark._({
    required this.size,
    required this.fit,
    required this.padding,
  });

  final double size;
  final BoxFit fit;
  final double padding;

  factory _LogoMark.small() =>
      const _LogoMark._(size: 34, fit: BoxFit.cover, padding: 0);

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
      child: Padding(
        padding: EdgeInsets.all(padding),
        child: Image.asset('assets/icons/app_icon.png', fit: fit),
      ),
    );
  }
}
