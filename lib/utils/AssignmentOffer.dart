// lib/AssignmentOffer.dart

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:geolocator/geolocator.dart';

class AssignmentOfferBanner extends StatefulWidget {
  // NEW: assignment document id in rider_assignments
  final String assignmentDocId;

  // Existing: order document id in Orders
  final String orderId;

  // Callbacks
  final VoidCallback onResolvedExternally;
  final Future Function() onAccept;
  final Future Function() onReject;
  final Future Function() onTimeout;

  // Countdown seeds
  final int? initialSeconds;
  final DateTime? expiresAt;

  // Styling
  final Color? cardColor;

  const AssignmentOfferBanner({
    super.key,
    required this.assignmentDocId,
    required this.orderId,
    required this.onAccept,
    required this.onReject,
    required this.onTimeout,
    required this.onResolvedExternally,
    this.initialSeconds,
    this.expiresAt,
    this.cardColor,
  });

  @override
  State<AssignmentOfferBanner> createState() => _AssignmentOfferBannerState();
}

class _AssignmentOfferBannerState extends State<AssignmentOfferBanner> {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  Map<String, dynamic>? _order;

  // Countdown state
  int _secondsLeft = 0;
  DateTime? _expiresAt;
  Timer? _timer;

  // Assignment watcher
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _assignSub;

  bool _busy = false;

  @override
  void initState() {
    super.initState();

    _expiresAt = widget.expiresAt;

    if (_expiresAt != null) {
      _secondsLeft = _remainingSeconds();
    } else {
      final seed = (widget.initialSeconds ?? 120);
      _secondsLeft = seed > 0 ? seed.clamp(1, 600) : 120;
    }

    _load();
    _startCountdown();
    _watchResolution();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _assignSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final snap = await _db.collection('Orders').doc(widget.orderId).get();
      if (!mounted) return;
      _order = snap.data();
      if (mounted) setState(() {});
    } catch (e) {
      // Ignore UI errors here
    }
  }

  int _remainingSeconds() {
    if (_expiresAt == null) return _secondsLeft;
    final now = DateTime.now();
    final secs = _expiresAt!.difference(now).inSeconds;
    return secs.clamp(0, 600);
  }

  void _startCountdown() {
    _timer = Timer.periodic(const Duration(seconds: 1), (t) async {
      if (!mounted) {
        t.cancel();
        return;
      }

      final next = _expiresAt != null ? _remainingSeconds() : (_secondsLeft - 1);

      if (next <= 0) {
        t.cancel();
        await _safeRun(widget.onTimeout);
      } else {
        setState(() => _secondsLeft = next);
      }
    });
  }

  void _watchResolution() {
    // IMPORTANT: watch by assignmentDocId (not orderId) because rider_assignments doc ids are random
    _assignSub = _db
        .collection('rider_assignments')
        .doc(widget.assignmentDocId)
        .snapshots()
        .listen((snap) {
      if (!snap.exists || !mounted) return;
      final status = snap.data()?['status'] as String?;
      // Close the banner when offer is resolved elsewhere
      if (status == 'accepted' || status == 'rejected' || status == 'timeout') {
        widget.onResolvedExternally();
      }

      // Optional: if backend extends the offer, update expiresAt live
      final expiresTs = snap.data()?['expiresAt'];
      if (expiresTs is Timestamp) {
        final newExpiry = expiresTs.toDate();
        if (_expiresAt == null || newExpiry.isAfter(_expiresAt!)) {
          setState(() {
            _expiresAt = newExpiry;
            _secondsLeft = _remainingSeconds();
          });
        }
      }
    });
  }

  Future<void> _safeRun(Future Function() fn) async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);

    // FIX: Cancel the listener immediately when user takes action
    // This prevents the 'watchResolution' from firing while we process the rejection
    await _assignSub?.cancel();
    _assignSub = null;

    try {
      await fn();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<double?> _distanceMeters() async {
    final o = _order;
    if (o == null) return null;
    final drop = o['deliveryAddress']?['geolocation'];
    if (drop == null) return null;
    try {
      final pos = await Geolocator.getCurrentPosition();
      return Geolocator.distanceBetween(
        pos.latitude,
        pos.longitude,
        drop.latitude,
        drop.longitude,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final o = _order;

    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: widget.cardColor ?? theme.cardColor,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.15),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              (widget.cardColor ?? theme.cardColor).withOpacity(0.98),
              (widget.cardColor ?? theme.cardColor).withOpacity(0.92),
            ],
          ),
          border: Border.all(color: Colors.black.withOpacity(0.06)),
        ),
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Row(
              children: [
                const Icon(Icons.delivery_dining, size: 22),
                const SizedBox(width: 8),
                Text(
                  'Delivery Offer',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                _CountdownPill(seconds: _secondsLeft),
              ],
            ),
            const SizedBox(height: 10),

            // Body
            if (o == null)
              Row(
                children: [
                  const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text('Loading order details...', style: theme.textTheme.bodyMedium),
                ],
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Order #${o['dailyOrderNumber'] ?? widget.orderId}',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.location_pin, size: 18),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          o['deliveryAddress']?['fullAddress'] ?? 'Delivery address in details',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Builder(builder: (context) {
                    final addr = (o['deliveryAddress'] as Map?) ?? const {};
                    final street = (addr['street'] as String?)?.trim() ?? '';
                    final streetToShow = street.isNotEmpty ? street : 'Street not specified';
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.home, size: 18),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            streetToShow,
                            style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    );
                  }),
                  const SizedBox(height: 6),
                  FutureBuilder<double?>(
                    future: _distanceMeters(),
                    builder: (context, snap) {
                      final txt = !snap.hasData
                          ? 'Calculating distance...'
                          : 'Approx. ${(snap.data! / 1000).toStringAsFixed(1)} km';
                      return Row(
                        children: [
                          const Icon(Icons.route, size: 18),
                          const SizedBox(width: 6),
                          Text(txt, style: theme.textTheme.bodyMedium),
                        ],
                      );
                    },
                  ),
                ],
              ),

            const SizedBox(height: 12),

            // Actions
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : () => _safeRun(widget.onReject),
                    icon: const Icon(Icons.close),
                    label: const Text('Reject'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: const BorderSide(color: Colors.red),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _busy ? null : () => _safeRun(widget.onAccept),
                    icon: const Icon(Icons.check),
                    label: const Text('Accept'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CountdownPill extends StatelessWidget {
  final int seconds;
  const _CountdownPill({required this.seconds});

  @override
  Widget build(BuildContext context) {
    final color = seconds <= 10
        ? Colors.red
        : (seconds <= 20 ? Colors.orange : Colors.blue);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.timer, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            '$seconds s',
            style: TextStyle(fontWeight: FontWeight.w700, color: color),
          ),
        ],
      ),
    );
  }
}
