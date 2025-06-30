import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart'; // Import for call and navigation
// import 'package:Maps_flutter/Maps_flutter.dart'; // Original comment retained

import '../theme/app_theme.dart';
import '../widgets/delivery_card.dart';
// Assuming OrderDetailsSheet is in a separate file, adjust path if needed
import 'package:myapp/widgets/order_details_modal.dart'; // Placeholder import for OrderDetailsSheet

// Main Screen (code from previous step, with additions)
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  String? _riderEmail;
  DocumentReference? _riderDocRef;

  @override
  void initState() {
    super.initState();
    _loadCurrentRiderInfo();
  }

  // --- ADDITION: Function to show the new Order Details bottom sheet ---
  void _showOrderDetailsSheet(BuildContext context, Map<String, dynamic> orderData, String orderId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true, // Allows the sheet to be taller
      backgroundColor: Colors.transparent,
      builder: (context) {
        // Ensure OrderDetailsSheet correctly handles orderData and orderId
        return OrderDetailsSheet(orderData: orderData, orderId: orderId);
      },
    );
  }

  Future<void> _loadCurrentRiderInfo() async {
    User? currentUser = _auth.currentUser;
    if (currentUser != null && currentUser.email != null) {
      setState(() {
        _riderEmail = currentUser.email;
        _riderDocRef = _firestore.collection('Riders').doc(_riderEmail);
      });
    }
  }

  Future<void> _updateRiderStatus(bool isOnline) async {
    if (_riderDocRef == null) return;
    await _riderDocRef!.update({'status': isOnline ? 'online' : 'offline'});
  }

  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'assigned':
      case 'rider_assigned':
      case 'on way':
      case 'accepted':
        return AppTheme.warningColor;
      case 'picked up':
        return AppTheme.dangerColor;
      case 'delivered':
        return Colors.green;
      case 'cancelled':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_riderEmail == null || _riderDocRef == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Loading Dashboard')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: StreamBuilder<DocumentSnapshot>(
        stream: _riderDocRef!.snapshots(),
        builder: (context, riderSnapshot) {
          if (!riderSnapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final riderData = riderSnapshot.data!.data() as Map<String, dynamic>?;
          final bool isOnline = riderData?['status'] == 'online';
          final String riderName = riderData?['name']?.split(' ').first ?? 'Rider';

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(context, riderName, isOnline),
              _buildStatusToggle(isOnline),
              const SizedBox(height: 24),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.0),
                child: Text('My Current Delivery', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
              ),
              const SizedBox(height: 10),
              _buildAssignedOrderStream(),
              const SizedBox(height: 20),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.0),
                child: Text('Available Orders', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
              ),
              const SizedBox(height: 10),
              if (isOnline)
                Expanded(child: _buildAvailableOrdersStream())
              else
                const Expanded(
                  child: Center(
                    child: Text("You are offline.", style: TextStyle(color: Colors.grey, fontSize: 16)),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  // Header and Status Toggle widgets remain the same
  Widget _buildHeader(BuildContext context, String name, bool isOnline) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.only(top: 50, left: 16, right: 16, bottom: 16),
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.cardColor,
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10, offset: const Offset(0, 4))],
        borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(24), bottomRight: Radius.circular(24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Welcome, $name", style: theme.textTheme.headlineSmall),
          const SizedBox(height: 4),
          Row(
            children: [
              Text("You are currently ", style: TextStyle(color: theme.colorScheme.secondary, fontSize: 16)),
              Text(isOnline ? "Online" : "Offline", style: TextStyle(color: isOnline ? Colors.green : Colors.red, fontWeight: FontWeight.bold, fontSize: 16)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusToggle(bool isOnline) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 16.0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.withOpacity(0.2), width: 1),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text("My Status", style: Theme.of(context).textTheme.titleMedium),
            Switch(value: isOnline, onChanged: _updateRiderStatus, activeColor: Colors.green, inactiveTrackColor: Colors.grey.shade600),
          ],
        ),
      ),
    );
  }

  // --- Stream Builders now call _showOrderDetailsSheet on tap ---
  Widget _buildAssignedOrderStream() {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore.collection('Orders').where('riderId', isEqualTo: _riderEmail).where('status', whereNotIn: ['delivered', 'cancelled']).limit(1).snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Center(child: Text("No active assigned orders."));
        if (snapshot.data!.docs.isEmpty) return const Center(child: Text("No active assigned orders."));
        final orderDoc = snapshot.data!.docs.first;
        final orderData = orderDoc.data() as Map<String, dynamic>;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: DeliveryCard(
            orderData: orderData, // Correctly passing orderData as expected by DeliveryCard
            orderId: orderDoc.id,
            statusColor: _getStatusColor(orderData['status']),
            onUpdateStatus: (newStatus) => _updateOrderStatus(orderDoc.id, newStatus),
            actionButtonText: orderData['status'] == 'accepted' || orderData['status'] == 'rider_assigned' ? 'Mark Picked Up' : 'Mark Delivered',
            nextStatus: orderData['status'] == 'accepted' || orderData['status'] == 'rider_assigned' ? 'pickedUp' : 'delivered',
            isAcceptAction: false,
            // ADDED: onTap callback to show order details
            onCardTap: () => _showOrderDetailsSheet(context, orderData, orderDoc.id),
          ),
        );
      },
    );
  }

  Widget _buildAvailableOrdersStream() {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore.collection('Orders').where('status', isEqualTo: 'prepared').where('riderId', isEqualTo: "").snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Center(child: Text("No new orders available."));
        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: snapshot.data!.docs.length,
          itemBuilder: (context, index) {
            final orderDoc = snapshot.data!.docs[index];
            final orderData = orderDoc.data() as Map<String, dynamic>;
            return DeliveryCard(
              orderData: orderData, // Correctly passing orderData as expected by DeliveryCard
              orderId: orderDoc.id,
              statusColor: _getStatusColor(orderData['status']),
              onAccept: () => _acceptOrder(orderDoc.id),
              actionButtonText: 'Accept Order',
              nextStatus: 'accepted',
              isAcceptAction: true,
              // ADDED: onTap callback to show order details
              onCardTap: () => _showOrderDetailsSheet(context, orderData, orderDoc.id),
            );
          },
        );
      },
    );
  }

  // Database Interaction Methods remain the same
  Future<void> _acceptOrder(String orderDocId) async {
    if (_riderEmail == null) return;
    await _firestore.runTransaction((transaction) async {
      final orderRef = _firestore.collection('Orders').doc(orderDocId);
      final orderSnapshot = await transaction.get(orderRef);
      if (orderSnapshot.data()?['riderId'] == "" && orderSnapshot.data()?['status'] == 'prepared') {
        transaction.update(orderRef, {'riderId': _riderEmail, 'status': 'rider_assigned', 'timestamps.accepted': FieldValue.serverTimestamp()});
      } else { throw Exception("Order already taken."); }
    });
  }

  Future<void> _updateOrderStatus(String orderDocId, String newStatus) async {
    await _firestore.collection('Orders').doc(orderDocId).update({'status': newStatus, 'timestamps.$newStatus': FieldValue.serverTimestamp()});
  }
}

// The OrderDetailsSheet class definition is NOT included here.
// It is assumed to be in a separate file (e.g., '../modals/order_details_sheet.dart')
// If you encounter errors about OrderDetailsSheet not being found,
// please ensure that file exists and the import path above is correct.