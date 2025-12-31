import 'package:flutter/material.dart';

import 'dart:async';

import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'cart_controller.dart';
import 'cart_scope.dart';

enum _CartDeliveryOption { safeBox, address }

class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  _CartDeliveryOption _option = _CartDeliveryOption.safeBox;

  // Cart checkout timeout: if the user doesn't complete payment within this
  // window, send them back to the buy screen (keep cart items).
  static const Duration _cartCheckoutTimeout = Duration(minutes: 15);
  DateTime? _cartCheckoutStartedAt;
  DateTime? _cartCheckoutEndsAt;
  int _cartCheckoutRemainingSeconds = 0;
  Timer? _cartCheckoutTicker;

  // Admin-controlled switch (Firestore): when storeOpen=false, allow a short
  // grace period for checkout, then force-return to home.
  static const String _storeConfigCollection = 'app_config';
  static const String _storeConfigDoc = 'global';
  static const Duration _checkoutGracePeriod = Duration(minutes: 10);

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _storeConfigSub;
  bool _storeOpen = true;
  String _storeClosedMessage = 'ปิดร้านชั่วคราว';
  DateTime? _checkoutGraceEndsAt;
  int _checkoutGraceRemainingSeconds = 0;
  Timer? _checkoutGraceTicker;
  bool _graceSnackShown = false;

  final Map<String, Future<bool>> _ticketValidFutureByKey = <String, Future<bool>>{};

  String _formatMmSs(int totalSeconds) {
    final s = totalSeconds.clamp(0, 359999);
    final mm = (s ~/ 60).toString().padLeft(2, '0');
    final ss = (s % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  void _startCartCheckoutCountdownIfNeeded({required CartController cart}) {
    if (cart.count <= 0) {
      _stopCartCheckoutCountdown();
      return;
    }

    final startedAt = cart.cartStartedAt;
    if (startedAt == null) {
      _stopCartCheckoutCountdown();
      return;
    }

    final shouldRestart =
        _cartCheckoutStartedAt == null ||
        _cartCheckoutStartedAt!.millisecondsSinceEpoch !=
            startedAt.millisecondsSinceEpoch;

    if (shouldRestart) {
      _cartCheckoutStartedAt = startedAt;
      _cartCheckoutEndsAt = startedAt.add(_cartCheckoutTimeout);
      _cartCheckoutRemainingSeconds = _cartCheckoutEndsAt!
          .difference(DateTime.now())
          .inSeconds
          .clamp(0, 999999);
    }

    _cartCheckoutTicker?.cancel();
    _cartCheckoutTicker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      final endsAt = _cartCheckoutEndsAt;
      if (endsAt == null) {
        t.cancel();
        return;
      }

      final remainingSeconds = endsAt.difference(DateTime.now()).inSeconds;
      final remainingClamped = remainingSeconds.clamp(0, 999999);

      if (remainingClamped != _cartCheckoutRemainingSeconds) {
        setState(() {
          _cartCheckoutRemainingSeconds = remainingClamped;
        });
      }

      if (remainingSeconds <= 0) {
        t.cancel();
        _cartCheckoutEndsAt = null;
        _cartCheckoutStartedAt = null;
        if (!mounted) return;
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    });
  }

  void _stopCartCheckoutCountdown() {
    _cartCheckoutTicker?.cancel();
    _cartCheckoutTicker = null;
    _cartCheckoutStartedAt = null;
    _cartCheckoutEndsAt = null;
    _cartCheckoutRemainingSeconds = 0;
  }

  static const int _pricePerTicketBaht = 80;

  final Map<String, Future<_LotteryMeta?>> _lotteryMetaFutureByKey =
      <String, Future<_LotteryMeta?>>{};
  final Map<String, Future<int?>> _setCountFutureByDigits =
      <String, Future<int?>>{};

  @override
  void initState() {
    super.initState();
    _listenStoreConfig();
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

          DateTime? closedAt;
          final closedAtRaw = data?['closedAt'];
          if (closedAtRaw is Timestamp) {
            closedAt = closedAtRaw.toDate();
          }
          final updatedAtRaw = data?['updatedAt'];
          if (closedAt == null && updatedAtRaw is Timestamp) {
            closedAt = updatedAtRaw.toDate();
          }

          closedAt ??= DateTime.now();

          if (!mounted) return;

          final willCloseNow = _storeOpen && !open;
          setState(() {
            _storeOpen = open;
            _storeClosedMessage = (note == null || note.isEmpty)
                ? 'ปิดร้านชั่วคราว'
                : note;
          });

          // If store is closed while user is on the cart screen (paying), start a
          // 10-minute grace period, then force back to home.
          if (!open) {
            // Override the normal cart timeout when the store is closed.
            _stopCartCheckoutCountdown();
            _startCheckoutGraceCountdown(
              fromClosedAt: closedAt,
              restart: willCloseNow,
            );
          }

          // If store re-opens, cancel any pending countdown.
          if (open) {
            _stopCheckoutGraceCountdown();
          }
        });
  }

  void _startCheckoutGraceCountdown({
    required DateTime fromClosedAt,
    required bool restart,
  }) {
    final nextEndsAt = fromClosedAt.add(_checkoutGracePeriod);
    if (!restart && _checkoutGraceEndsAt != null) {
      // Keep existing countdown unless admin explicitly closed again.
      return;
    }

    _checkoutGraceTicker?.cancel();
    _checkoutGraceEndsAt = nextEndsAt;
    _graceSnackShown = false;

    final initialRemaining = nextEndsAt.difference(DateTime.now()).inSeconds;
    _checkoutGraceRemainingSeconds = initialRemaining.clamp(0, 999999);
    if (_checkoutGraceRemainingSeconds <= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).popUntil((route) => route.isFirst);
      });
      return;
    }

    _checkoutGraceTicker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      final endsAt = _checkoutGraceEndsAt;
      if (endsAt == null) {
        t.cancel();
        return;
      }

      final remainingSeconds = endsAt.difference(DateTime.now()).inSeconds;
      final remainingClamped = remainingSeconds.clamp(0, 999999);

      if (remainingClamped != _checkoutGraceRemainingSeconds) {
        setState(() {
          _checkoutGraceRemainingSeconds = remainingClamped;
        });
      }

      if (!_graceSnackShown) {
        _graceSnackShown = true;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '$_storeClosedMessage กรุณาชำระเงินให้เสร็จภายใน 10 นาที',
            ),
            duration: const Duration(milliseconds: 2200),
          ),
        );
      }

      if (remainingSeconds <= 0) {
        t.cancel();
        _checkoutGraceEndsAt = null;
        if (!mounted) return;
        Navigator.of(context).popUntil((route) => route.isFirst);
        return;
      }
    });
  }

  void _stopCheckoutGraceCountdown() {
    _checkoutGraceTicker?.cancel();
    _checkoutGraceTicker = null;
    _checkoutGraceEndsAt = null;
    _checkoutGraceRemainingSeconds = 0;
    _graceSnackShown = false;
  }

  int? _toInt(Object? value) {
    if (value is int) return value;
    if (value is double) return value.round();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  String _formatBaht(int value) {
    final digits = value.toString();
    final out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      final fromEnd = digits.length - i;
      out.write(digits[i]);
      if (fromEnd > 1 && fromEnd % 3 == 1) out.write(',');
    }
    return out.toString();
  }

  String? _extractDigits6({required String displayName, String? imagePath}) {
    final fromDisplay = RegExp(r'\d{6}').firstMatch(displayName)?.group(0);
    if (fromDisplay != null && fromDisplay != '000000') return fromDisplay;

    String? extractFromToken(String token) {
      final t = token.trim();
      if (t.isEmpty) return null;
      final noExt = _baseNameNoExt(t);

      // Strong signal: docId/segment like `<digits>_<timestamp>_<seq>`.
      final docLike = RegExp(r'^(\d{6})_\d{8,}(?:_\d+)?$').firstMatch(noExt);
      if (docLike != null) {
        final d = docLike.group(1);
        if (d != null && d != '000000') return d;
      }

      final leading =
          RegExp(r'^(\d{6})(?=[^\d]|$)').firstMatch(noExt)?.group(1);
      if (leading != null && leading != '000000') return leading;

      final matches =
          RegExp(r'\d{6}').allMatches(noExt).toList(growable: false);
      for (var i = matches.length - 1; i >= 0; i--) {
        final g = matches[i].group(0);
        if (g != null && g != '000000') return g;
      }
      return null;
    }

    if (imagePath != null && imagePath.trim().isNotEmpty) {
      final segments = imagePath.split('/');
      for (var i = segments.length - 1; i >= 0; i--) {
        final d = extractFromToken(segments[i]);
        if (d != null) return d;
      }
    }

    return null;
  }

  String _baseNameNoExt(String filename) {
    final dot = filename.lastIndexOf('.');
    if (dot <= 0) return filename;
    return filename.substring(0, dot);
  }

  List<String> _lotteryDocIdCandidates({
    required String itemId,
    String? imagePath,
  }) {
    final out = <String>[];

    // itemId is usually the storage path; try also its filename / basename and
    // each segment (some paths embed Firestore docIds).
    final idSegments = itemId.split('/');
    final idLast = idSegments.isEmpty ? itemId : idSegments.last;
    out.add(itemId);
    out.add(idLast);
    out.add(_baseNameNoExt(idLast));
    for (final s in idSegments) {
      out.add(s);
      out.add(_baseNameNoExt(s));
    }

    if (imagePath != null && imagePath.trim().isNotEmpty) {
      final segments = imagePath.split('/');
      final last = segments.isEmpty ? imagePath : segments.last;
      out.add(imagePath);
      out.add(last);
      out.add(_baseNameNoExt(last));

      for (final s in segments) {
        out.add(s);
        out.add(_baseNameNoExt(s));
      }
    }

    final seen = <String>{};
    return out
        .where((s) => s.trim().isNotEmpty && seen.add(s))
        .toList(growable: false);
  }

  Future<_LotteryMeta?> _fetchLotteryMetaByDocIdCandidates({
    required String itemId,
    required String? imagePath,
  }) async {
    final col = FirebaseFirestore.instance.collection('lottery');
    for (final id in _lotteryDocIdCandidates(
      itemId: itemId,
      imagePath: imagePath,
    )) {
      final snap = await col.doc(id).get();
      final data = snap.data();
      if (data == null) continue;
      final digits = (data['digits'] as String?)?.trim();
      final setCount = _toInt(data['setCount']);
      if (digits != null &&
          RegExp(r'^\d{6}$').hasMatch(digits) &&
          setCount != null) {
        return _LotteryMeta(digits: digits, setCount: setCount);
      }
    }
    return null;
  }

  Future<_LotteryMeta?> _lotteryMetaFutureForItem({
    required String itemId,
    required String? imagePath,
  }) {
    final key = '$itemId|${imagePath ?? ''}';
    return _lotteryMetaFutureByKey.putIfAbsent(
      key,
      () => _fetchLotteryMetaByDocIdCandidates(
        itemId: itemId,
        imagePath: imagePath,
      ),
    );
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

    // Fallback: docId format is often `<digits>_<timestamp>_<seq>`.
    if (results.isEmpty) {
      final prefix = '${digits}_';
      final q3 = await col
          .orderBy(FieldPath.documentId)
          .startAt([prefix])
          .endAt(['$prefix\uf8ff'])
          .limit(20)
          .get();
      for (final d in q3.docs) {
        final v = _toInt(d.data()['setCount']);
        if (v != null) results.add(v);
      }
    }

    if (results.isEmpty) return null;
    results.sort();
    return results.last;
  }

  Future<bool> _validateCartItemPresence({required CartItem item}) async {
    final rawPath = (item.imagePath != null && item.imagePath!.trim().isNotEmpty)
        ? item.imagePath!.trim()
        : item.id.trim();

    var inStorage = false;
    if (rawPath.isNotEmpty) {
      try {
        await FirebaseStorage.instance.ref(rawPath).getMetadata();
        inStorage = true;
      } catch (_) {
        inStorage = false;
      }
    }
    if (inStorage) return true;

    final meta = await _fetchLotteryMetaByDocIdCandidates(
      itemId: item.id,
      imagePath: item.imagePath,
    );
    if (meta != null) return true;

    final digits = _extractDigits6(
      displayName: item.displayName,
      imagePath: item.imagePath,
    );
    if (digits != null && digits != '000000') {
      final setCount = await _fetchSetCountFromLotteryByDigits(digits);
      if (setCount != null) return true;
    }

    return false;
  }

  Future<bool> _ticketValidFutureForItem(CartItem item) {
    final key = '${item.id}|${item.imagePath ?? ''}|${item.displayName}';
    return _ticketValidFutureByKey.putIfAbsent(
      key,
      () => _validateCartItemPresence(item: item),
    );
  }

  Future<int?> _setCountFutureForDigits(String digits6) {
    final key = digits6.trim();
    return _setCountFutureByDigits.putIfAbsent(
      key,
      () => _fetchSetCountFromLotteryByDigits(key),
    );
  }

  @override
  void dispose() {
    _storeConfigSub?.cancel();
    _checkoutGraceTicker?.cancel();
    _cartCheckoutTicker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cart = CartScope.of(context);

    final showStoreClosedCountdown =
        !_storeOpen && _checkoutGraceEndsAt != null;

    // Only run the normal cart checkout timer when the store is open.
    if (_storeOpen) {
      _startCartCheckoutCountdownIfNeeded(cart: cart);
    }
    final showCartCountdown =
        _storeOpen && cart.count > 0 && _cartCheckoutEndsAt != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('ตะกร้าสลาก'),
        actions: [
          if (showStoreClosedCountdown)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  _formatMmSs(_checkoutGraceRemainingSeconds),
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                  ),
                ),
              ),
            )
          else if (showCartCountdown)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  _formatMmSs(_cartCheckoutRemainingSeconds),
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: AnimatedBuilder(
        animation: cart,
        builder: (context, _) {
          if (cart.count == 0) {
            return Center(
              child: Text(
                'ยังไม่มีสลากในตะกร้า',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: Colors.grey.shade700,
                ),
              ),
            );
          }

          final items = cart.items;
          return Column(
            children: [
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    return FutureBuilder<bool>(
                      future: _ticketValidFutureForItem(item),
                      builder: (context, validSnap) {
                        if (validSnap.connectionState == ConnectionState.done &&
                            validSnap.data == false) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            cart.remove(item.id);
                          });
                          return const SizedBox.shrink();
                        }

                        final digits6Raw = _extractDigits6(
                          displayName: item.displayName,
                          imagePath: item.imagePath,
                        );
                        // Some Storage filenames are like `file_000000...` which would
                        // incorrectly extract `000000`. Treat that as unknown and
                        // resolve the real 6-digit number from Firestore `lottery`.
                        final digits6 = (digits6Raw == '000000') ? null : digits6Raw;

                        return Material(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                _TicketThumbnail(path: item.imagePath),
                                const SizedBox(width: 12),
                                const Spacer(),
                                FutureBuilder<_LotteryMeta?>(
                                  future: digits6 == null
                                      ? _lotteryMetaFutureForItem(
                                          itemId: item.id,
                                          imagePath: item.imagePath,
                                        )
                                      : Future<_LotteryMeta?>.value(null),
                                  builder: (context, metaSnap) {
                                    final inferredDigits =
                                        digits6 ?? metaSnap.data?.digits;

                                    if (inferredDigits == null) {
                                      return const _CartBadge(
                                        numberText: '-',
                                        countText: '- ใบ',
                                        priceText: '- บาท',
                                      );
                                    }

                                    return FutureBuilder<int?>(
                                      future: _setCountFutureForDigits(
                                        inferredDigits,
                                      ),
                                      builder: (context, setSnap) {
                                        final waiting =
                                            setSnap.connectionState !=
                                            ConnectionState.done;
                                        final setCount = setSnap.data ??
                                            metaSnap.data?.setCount;

                                        if (waiting) {
                                          return _CartBadge(
                                            numberText: inferredDigits,
                                            countText: '... ใบ',
                                            priceText: '... บาท',
                                          );
                                        }

                                        if (setCount == null) {
                                          return _CartBadge(
                                            numberText: inferredDigits,
                                            countText: '- ใบ',
                                            priceText: '- บาท',
                                          );
                                        }

                                        final tickets =
                                            setCount.clamp(1, 999999);
                                        final price =
                                            tickets * _pricePerTicketBaht;

                                        return _CartBadge(
                                          numberText: inferredDigits,
                                          countText: '$tickets ใบ',
                                          priceText:
                                              '${_formatBaht(price)} บาท',
                                        );
                                      },
                                    );
                                  },
                                ),
                                const SizedBox(width: 4),
                                IconButton(
                                  onPressed: () => cart.remove(item.id),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 36,
                                    minHeight: 36,
                                  ),
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: _OptionButton(
                                label: 'เช่าตู้เซฟ',
                                selected:
                                    _option == _CartDeliveryOption.safeBox,
                                onTap: () => setState(
                                  () => _option = _CartDeliveryOption.safeBox,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _OptionButton(
                                label: 'ส่งตามที่อยู่',
                                selected:
                                    _option == _CartDeliveryOption.address,
                                onTap: () => setState(
                                  () => _option = _CartDeliveryOption.address,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _OptionButton extends StatelessWidget {
  const _OptionButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 46,
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
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
    );
  }
}

class _TicketThumbnail extends StatelessWidget {
  const _TicketThumbnail({required this.path});

  final String? path;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Make the thumbnail larger (per spec) but keep it capped to avoid overflow.
    const baseWidth = 110.0;
    const baseHeight = 70.0;
    const scale = 2.8;
    const aspect = baseWidth / baseHeight;

    final screenWidth = MediaQuery.sizeOf(context).width;
    final targetHeight = baseHeight * scale;
    final safeHeightCap = screenWidth * 0.32;
    final height = math.min(targetHeight, safeHeightCap);
    final width = height * aspect;

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: width,
        height: height,
        child: path == null
            ? Container(
                color: Colors.grey.shade200,
                alignment: Alignment.center,
                child: Icon(
                  Icons.image_outlined,
                  color: theme.iconTheme.color?.withValues(alpha: 0.6),
                ),
              )
            : _StorageImage(path: path!),
      ),
    );
  }
}

class _StorageImage extends StatefulWidget {
  const _StorageImage({required this.path});

  final String path;

  @override
  State<_StorageImage> createState() => _StorageImageState();
}

class _StorageImageState extends State<_StorageImage> {
  late final Future<String> _urlFuture;

  @override
  void initState() {
    super.initState();
    _urlFuture = FirebaseStorage.instance.ref(widget.path).getDownloadURL();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _urlFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Container(
            color: Colors.grey.shade200,
            alignment: Alignment.center,
            child: const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }

        final url = snapshot.data;
        if (url == null || snapshot.hasError) {
          return Container(
            color: Colors.grey.shade200,
            alignment: Alignment.center,
            child: const Icon(Icons.broken_image_outlined),
          );
        }

        // Use `contain` so every part of the ticket is visible (no cropping),
        // and keep a consistent frame size across items.
        return Container(
          color: Colors.white,
          alignment: Alignment.center,
          child: Image.network(
            url,
            fit: BoxFit.contain,
            alignment: Alignment.center,
            filterQuality: FilterQuality.medium,
            errorBuilder: (context, _, __) {
              return Container(
                color: Colors.grey.shade200,
                alignment: Alignment.center,
                child: const Icon(Icons.broken_image_outlined),
              );
            },
          ),
        );
      },
    );
  }
}

class _LotteryMeta {
  const _LotteryMeta({required this.digits, required this.setCount});

  final String digits;
  final int setCount;
}

class _CartBadge extends StatelessWidget {
  const _CartBadge({
    required this.numberText,
    required this.countText,
    required this.priceText,
  });

  final String numberText;
  final String countText;
  final String priceText;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 84,
      height: 84,
      decoration: const BoxDecoration(
        color: Colors.red,
        shape: BoxShape.circle,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              numberText,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            countText,
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              color: Colors.white,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            priceText,
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              color: Colors.white,
              fontSize: 12,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
