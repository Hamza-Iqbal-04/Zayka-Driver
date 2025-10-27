// lib/AssignmentOffer.dart

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:firebase_auth/firebase_auth.dart';

import 'package:geolocator/geolocator.dart';

class AssignmentOfferBanner extends StatefulWidget {
  final String orderId;
  final VoidCallback onResolvedExternally;
  final Future<void> Function() onAccept;
  final Future<void> Function() onReject;
  final Future<void> Function() onTimeout;
  final int? initialSeconds;
  final Color? cardColor;

  const AssignmentOfferBanner({
    super.key,
    required this.orderId,
    required this.onAccept,
    required this.onReject,
    required this.onTimeout,
    required this.onResolvedExternally,
    this.initialSeconds,
    this.cardColor,
  });

  @override
  State<AssignmentOfferBanner> createState() => _AssignmentOfferBannerState();
}

class _AssignmentOfferBannerState extends State<AssignmentOfferBanner> {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  Map<String, dynamic>? _order;
  int _secondsLeft = 30;
  Timer? _timer;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _assignSub;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final seed = (widget.initialSeconds ?? 120);
    _secondsLeft = seed > 0 ? seed.clamp(1, 600) : 120;
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
    final snap = await _db.collection('Orders').doc(widget.orderId).get();
    if (!mounted) return;
    _order = snap.data();
    if (mounted) setState(() {});
  }

  void _startCountdown() {
    _timer = Timer.periodic(const Duration(seconds: 1), (t) async {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_secondsLeft <= 1) {
        t.cancel();
        // --- FIX ---
        // Instead of calling onTimeout, we call onReject.
        // This ensures the offer is explicitly rejected and the UI updates,
        // resolving the "stuck" state.
        await _safeRun(widget.onReject);
      } else {
        setState(() => _secondsLeft--);
      }
    });
  }

  void _watchResolution() {
    _assignSub = _db
        .collection('rider_assignments')
        .doc(widget.orderId)
        .snapshots()
        .listen((snap) {
      if (!snap.exists || !mounted) return;
      final status = snap.data()?['status'] as String?;
      if (status == 'accepted' || status == 'rejected' || status == 'timeout') {
        widget.onResolvedExternally();
      }
    });
  }

  Future<void> _safeRun(Future<void> Function() fn) async {
    if (_busy) return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      await fn();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<double?> _distanceMeters() async {
    final o = _order;
    if (o == null) return null;
    final drop = o['deliveryAddress']?['geolocation'];
    if (drop == null) return null;
    final pos = await Geolocator.getCurrentPosition();
    return Geolocator.distanceBetween(
        pos.latitude, pos.longitude, drop.latitude, drop.longitude);
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
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                _CountdownPill(seconds: _secondsLeft),
              ],
            ),
            const SizedBox(height: 10),

            if (o == null)
              Row(
                children: [
                  const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text('Loading order details...',
                      style: theme.textTheme.bodyMedium),
                ],
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Order #${o['dailyOrderNumber'] ?? widget.orderId}',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.location_pin, size: 18),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          o['deliveryAddress']?['fullAddress'] ??
                              'Delivery address in details',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Builder(builder: (context) {
                    final addr =
                        (o['deliveryAddress'] as Map<String, dynamic>?) ??
                            const {};
                    final street = (addr['street'] as String?)?.trim() ?? '';
                    final streetToShow =
                    street.isNotEmpty ? street : 'Street not specified';
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.home, size: 18),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            streetToShow,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
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
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
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
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
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
          Text('$seconds s',
              style: TextStyle(fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }
}
