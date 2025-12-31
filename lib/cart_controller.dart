import 'package:flutter/foundation.dart';

import 'dart:async';

class CartItem {
  CartItem({
    required this.id,
    required this.displayName,
    this.imagePath,
    this.quantity = 1,
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();

  final String id;
  final String displayName;
  final String? imagePath;
  final int quantity;
  final DateTime addedAt;

  CartItem copyWith({
    String? id,
    String? displayName,
    String? imagePath,
    int? quantity,
    DateTime? addedAt,
  }) {
    return CartItem(
      id: id ?? this.id,
      displayName: displayName ?? this.displayName,
      imagePath: imagePath ?? this.imagePath,
      quantity: quantity ?? this.quantity,
      addedAt: addedAt ?? this.addedAt,
    );
  }
}

class CartController extends ChangeNotifier {
  final Map<String, CartItem> _itemsById = <String, CartItem>{};
  DateTime? _cartStartedAt;

  static const Duration checkoutTimeout = Duration(minutes: 15);

  bool _storeOpen = true;
  Timer? _expiryTimer;
  DateTime? _scheduledExpiresAt;
  bool _expiring = false;

  Future<void> Function(CartController cart)? _onExpired;

  void setOnExpired(Future<void> Function(CartController cart)? handler) {
    _onExpired = handler;
    _scheduleExpiryIfNeeded();
  }

  /// Allows the app to pause the 15-minute expiry while the store is closed
  /// (store-close grace countdown overrides the cart timer).
  void setStoreOpen(bool open) {
    if (_storeOpen == open) return;
    _storeOpen = open;
    _scheduleExpiryIfNeeded();
  }

  DateTime? get cartExpiresAt {
    final startedAt = _cartStartedAt;
    if (startedAt == null) return null;
    return startedAt.add(checkoutTimeout);
  }

  void _cancelExpiryTimer() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _scheduledExpiresAt = null;
  }

  void _scheduleExpiryIfNeeded() {
    if (!_storeOpen) {
      _cancelExpiryTimer();
      return;
    }

    if (_itemsById.isEmpty || _cartStartedAt == null) {
      _cancelExpiryTimer();
      return;
    }

    final expiresAt = cartExpiresAt;
    if (expiresAt == null) {
      _cancelExpiryTimer();
      return;
    }

    // If already scheduled for this exact deadline, keep it.
    if (_scheduledExpiresAt != null &&
        _scheduledExpiresAt!.millisecondsSinceEpoch ==
            expiresAt.millisecondsSinceEpoch &&
        _expiryTimer != null) {
      return;
    }

    _cancelExpiryTimer();
    _scheduledExpiresAt = expiresAt;

    final ms = expiresAt.difference(DateTime.now()).inMilliseconds;
    if (ms <= 0) {
      // Expire ASAP.
      scheduleMicrotask(() {
        unawaited(expireNow(force: false));
      });
      return;
    }

    _expiryTimer = Timer(Duration(milliseconds: ms), () {
      unawaited(expireNow(force: false));
    });
  }

  Future<void> expireNow({required bool force}) async {
    if (_expiring) return;
    if (!_storeOpen) return;
    if (_itemsById.isEmpty || _cartStartedAt == null) {
      _cancelExpiryTimer();
      return;
    }

    final expiresAt = cartExpiresAt;
    if (expiresAt == null) {
      _cancelExpiryTimer();
      return;
    }

    if (!force && DateTime.now().isBefore(expiresAt)) {
      _scheduleExpiryIfNeeded();
      return;
    }

    _expiring = true;
    _cancelExpiryTimer();
    try {
      final handler = _onExpired;
      if (handler != null) {
        await handler(this);
      } else {
        // Fallback: clear cart locally.
        clear();
      }
    } catch (_) {
      // Best-effort only.
    } finally {
      _expiring = false;
      // If items are still present (handler didn't clear), schedule again.
      _scheduleExpiryIfNeeded();
    }
  }

  /// When the first ticket was added to an empty cart.
  ///
  /// Used to compute the 15-minute checkout timeout even if the user opens the
  /// cart screen later.
  DateTime? get cartStartedAt => _cartStartedAt;

  List<CartItem> get items {
    final list = _itemsById.values.toList(growable: false);
    list.sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return list;
  }

  int get count =>
      _itemsById.values.fold<int>(0, (sum, item) => sum + item.quantity);

  bool contains(String id) => _itemsById.containsKey(id);

  /// Adds one unit of [item]. If the item already exists, increments quantity.
  /// Returns the new quantity for this item.
  int add(CartItem item) {
    final wasEmpty = _itemsById.isEmpty;
    final existing = _itemsById[item.id];
    if (existing == null) {
      _itemsById[item.id] = item.copyWith(
        quantity: item.quantity.clamp(1, 9999),
      );
      if (wasEmpty) {
        _cartStartedAt = item.addedAt;
      }
      notifyListeners();
      _scheduleExpiryIfNeeded();
      return _itemsById[item.id]!.quantity;
    }

    final newQty = (existing.quantity + item.quantity).clamp(1, 9999);
    _itemsById[item.id] = existing.copyWith(
      quantity: newQty,
      addedAt: DateTime.now(),
    );
    if (wasEmpty) {
      // Should be rare, but keep the invariant.
      _cartStartedAt = DateTime.now();
    }
    notifyListeners();
    _scheduleExpiryIfNeeded();
    return newQty;
  }

  void remove(String id) {
    if (_itemsById.remove(id) != null) {
      if (_itemsById.isEmpty) {
        _cartStartedAt = null;
        _cancelExpiryTimer();
      }
      notifyListeners();
      _scheduleExpiryIfNeeded();
    }
  }

  bool toggle(CartItem item) {
    if (contains(item.id)) {
      remove(item.id);
      return false;
    }
    add(item);
    return true;
  }

  void clear() {
    if (_itemsById.isEmpty) return;
    _itemsById.clear();
    _cartStartedAt = null;
    _cancelExpiryTimer();
    notifyListeners();
  }
}
