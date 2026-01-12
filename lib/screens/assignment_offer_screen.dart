// lib/screens/assignment_offer_screen.dart
// Wrapper screen for AssignmentOfferBanner that handles FCM notification navigation

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../utils/AssignmentOffer.dart';

/// This screen is navigated to when a driver taps an FCM notification
/// for order assignment. It fetches the assignment document and displays
/// the AssignmentOfferBanner with proper callbacks.
class AssignmentOfferScreen extends StatefulWidget {
  final String orderId;

  const AssignmentOfferScreen({super.key, required this.orderId});

  @override
  State<AssignmentOfferScreen> createState() => _AssignmentOfferScreenState();
}

class _AssignmentOfferScreenState extends State<AssignmentOfferScreen> {
  final _db = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;

  String? _assignmentDocId;
  DateTime? _expiresAt;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _findAssignment();
  }

  /// Find the active assignment document for this order and driver
  Future<void> _findAssignment() async {
    try {
      // Use email instead of uid - assignments are stored with email as riderId
      final riderEmail = _auth.currentUser?.email;
      if (riderEmail == null) {
        setState(() {
          _error = 'Not logged in';
          _loading = false;
        });
        return;
      }

      // Query for the pending assignment for this order and driver
      final query =
          await _db
              .collection('rider_assignments')
              .where('orderId', isEqualTo: widget.orderId)
              .where('riderId', isEqualTo: riderEmail)
              .where('status', isEqualTo: 'pending')
              .limit(1)
              .get();

      if (query.docs.isEmpty) {
        if (mounted) _showUnavailableDialog();
        return;
      }

      final doc = query.docs.first;
      final data = doc.data();
      final expiresTs = data['expiresAt'];

      setState(() {
        _assignmentDocId = doc.id;
        _expiresAt = expiresTs is Timestamp ? expiresTs.toDate() : null;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Error loading assignment: $e';
        _loading = false;
      });
    }
  }

  Future<void> _handleAccept() async {
    // Use email instead of uid for consistency with the rest of the app
    final riderEmail = _auth.currentUser?.email;
    if (riderEmail == null || _assignmentDocId == null) return;

    await _db.collection('rider_assignments').doc(_assignmentDocId).update({
      'status': 'accepted',
      'respondedAt': FieldValue.serverTimestamp(),
    });

    // Update the order with rider assignment
    await _db.collection('Orders').doc(widget.orderId).update({
      'riderId': riderEmail,
      'riderAssignedAt': FieldValue.serverTimestamp(),
      'orderStatus': 'Rider Assigned',
    });

    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _handleReject() async {
    if (_assignmentDocId == null) return;

    await _db.collection('rider_assignments').doc(_assignmentDocId).update({
      'status': 'rejected',
      'respondedAt': FieldValue.serverTimestamp(),
    });

    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _handleTimeout() async {
    if (_assignmentDocId == null) return;

    await _db.collection('rider_assignments').doc(_assignmentDocId).update({
      'status': 'timeout',
      'respondedAt': FieldValue.serverTimestamp(),
    });

    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _handleResolvedExternally() {
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _showUnavailableDialog() async {
    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: const [
              Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 28),
              SizedBox(width: 10),
              Text('Offer Unavailable'),
            ],
          ),
          content: const Text(
            'This delivery offer is no longer available. It may have been assigned to another driver or expired.',
            style: TextStyle(fontSize: 16),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () {
                Navigator.of(ctx).pop(); // Close dialog
                if (mounted) {
                  Navigator.of(context).pop(); // Close screen
                }
              },
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Delivery Offer'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    // If error was set (legacy) or we are just waiting for dialog to pop us
    if (_error != null) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: AssignmentOfferBanner(
        assignmentDocId: _assignmentDocId!,
        orderId: widget.orderId,
        expiresAt: _expiresAt,
        onAccept: _handleAccept,
        onReject: _handleReject,
        onTimeout: _handleTimeout,
        onResolvedExternally: _handleResolvedExternally,
      ),
    );
  }
}
