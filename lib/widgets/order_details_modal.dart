import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

// Imports required for OrderDetailsSheet

import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

import '../theme/app_theme.dart';
import '../widgets/delivery_card.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  String? _riderEmail;
  DocumentReference? _riderDocRef;

  @override
  void initState() {
    super.initState();
    _loadCurrentRiderInfo();
  }

  // --- Function to show the Order Details bottom sheet ---
  void _showOrderDetailsSheet(BuildContext context, Map<String, dynamic> orderData, String orderId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true, // Allows the sheet to be taller
      useSafeArea: true, // Respects safe areas (e.g., notch)
      backgroundColor: Colors.transparent, // Makes background of sheet transparent
      barrierColor: Colors.black.withOpacity(0.2), // Dim background behind sheet
      transitionAnimationController: AnimationController(
        duration: const Duration(milliseconds: 300), // Custom transition duration
        vsync: this, // Use 'this' because _HomeScreenState now has TickerProviderStateMixin
      ),
      builder: (context) {
        return OrderDetailsSheet(
          orderData: orderData,
          orderId: orderId,
          onUpdateStatus: (newStatus) { // Pass the status update function to the modal
            _updateOrderStatus(orderId, newStatus);
            // Modal will pop itself after update
            Navigator.pop(context); // Manually pop the sheet after update
          },
        );
      },
    );
  }

  Future<void> _loadCurrentRiderInfo() async {
    User? currentUser = _auth.currentUser;
    if (currentUser != null && currentUser.email != null) {
      setState(() {
        _riderEmail = currentUser.email;
        _riderDocRef = _firestore.collection('Drivers').doc(_riderEmail);
      });
    }
  }

  Future<void> _updateRiderStatus(bool isOnline) async {
    if (_riderDocRef == null) return;
    try {
      await _riderDocRef!.update({'status': isOnline ? 'online' : 'offline'});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Status updated to ${isOnline ? "Online" : "Offline"}')),
      );
    } catch (e) {
      print("Error updating rider status: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update status: $e')),
      );
    }
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
          if (riderSnapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (riderSnapshot.hasError) {
            print('Rider Stream Error: ${riderSnapshot.error}');
            return Center(child: Text('Error loading rider data: ${riderSnapshot.error}'));
          }
          if (!riderSnapshot.hasData || !riderSnapshot.data!.exists) {
            return const Center(child: Text("Rider profile not found."));
          }

          final riderData = riderSnapshot.data!.data() as Map<String, dynamic>;
          final bool isOnline = riderData['status'] == 'online';
          final String riderName = riderData['name']?.split(' ').first ?? 'Rider';

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

  // Header and Status Toggle widgets (unchanged)
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


  // --- Stream Builders with corrected DeliveryCard parameters and onTap ---
  Widget _buildAssignedOrderStream() {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore.collection('Orders').where('riderId', isEqualTo: _riderEmail).where('status', whereNotIn: ['delivered', 'cancelled']).limit(1).snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) return const Center(child: Text("No active assigned orders."));
        if (snapshot.hasError) {
          print('Assigned Order Stream Error: ${snapshot.error}');
          return Center(child: Text('Error: ${snapshot.error}'));
        }

        final orderDoc = snapshot.data!.docs.first;
        final orderData = orderDoc.data() as Map<String, dynamic>;

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: DeliveryCard(
            orderData: orderData, // Correctly passing the full orderData map
            orderId: orderData['orderId'] ?? orderDoc.id,
            statusColor: _getStatusColor(orderData['status'] ?? 'unknown'),
            onAccept: null, // No accept button for assigned orders
            onUpdateStatus: null, // Removed: Status update handled in modal
            actionButtonText: null, // Removed: No action button on home screen
            nextStatus: null, // Removed: No next status on home screen
            onCardTap: () {
              print('Tapping DeliveryCard for orderId: ${orderDoc.id}. Opening OrderDetailsModal.');
              _showOrderDetailsSheet(context, orderData, orderDoc.id);
            },
          ),
        );
      },
    );
  }

  Widget _buildAvailableOrdersStream() {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore.collection('Orders').where('status', isEqualTo: 'prepared').where('riderId', isEqualTo: "").snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) return const Center(child: Text("No new orders available."));
        if (snapshot.hasError) {
          print('Available Order Stream Error: ${snapshot.error}');
          return Center(child: Text('Error: ${snapshot.error}'));
        }

        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: snapshot.data!.docs.length,
          itemBuilder: (context, index) {
            final orderDoc = snapshot.data!.docs[index];
            final orderData = orderDoc.data() as Map<String, dynamic>;

            return DeliveryCard(
              orderData: orderData, // Correctly passing the full orderData map
              orderId: orderData['orderId'] ?? orderDoc.id,
              statusColor: _getStatusColor(orderData['status'] ?? 'unknown'),
              onAccept: () => _acceptOrder(orderDoc.id),
              onUpdateStatus: null, // No status update button for available orders
              actionButtonText: 'Accept Order',
              nextStatus: 'accepted',
              isAcceptAction: true,
              onCardTap: () {
                print('Tapping DeliveryCard for orderId: ${orderDoc.id}. Opening OrderDetailsModal.');
                _showOrderDetailsSheet(context, orderData, orderDoc.id);
              },
            );
          },
        );
      },
    );
  }

  // Database Interaction Methods
  Future<void> _acceptOrder(String orderDocId) async {
    if (_riderEmail == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Rider not logged in or info not loaded.')),
      );
      return;
    }

    try {
      await _firestore.runTransaction((transaction) async {
        final orderRef = _firestore.collection('Orders').doc(orderDocId);
        final orderSnapshot = await transaction.get(orderRef);

        if (!orderSnapshot.exists) {
          throw Exception("Order does not exist!");
        }

        final currentRiderIdInDb = orderSnapshot.data()?['riderId'];
        final currentStatus = orderSnapshot.data()?['status'];

        if (currentRiderIdInDb == "" && currentStatus == 'prepared') {
          transaction.update(orderRef, {
            'riderId': _riderEmail,
            'status': 'rider_assigned', // Store as 'rider_assigned' in DB
            'timestamps.accepted': FieldValue.serverTimestamp(),
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Order ${orderDocId} accepted!')),
          );
        } else {
          String message;
          if (currentRiderIdInDb != "") {
            message = 'Order has already been assigned to another rider.';
          } else if (currentStatus != 'prepared') {
            message = 'Order is not yet prepared for pickup.';
          } else {
            message = 'Order cannot be accepted due to an unknown state.';
          }
          throw Exception(message);
        }
      });
    } catch (e, stackTrace) {
      print('Error accepting order: $e');
      print('Error type: ${e.runtimeType}');
      print('Stack trace: $stackTrace');

      String errorMessage = 'Failed to accept order.';
      if (e is FirebaseException) {
        errorMessage = e.message ?? errorMessage;
      } else if (e is Exception) {
        errorMessage = e.toString().replaceFirst('Exception: ', '');
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorMessage)));
    }
  }

  Future<void> _updateOrderStatus(String orderDocId, String newStatus) async {
    try {
      await _firestore.collection('Orders').doc(orderDocId).update({
        'status': newStatus,
        'timestamps.$newStatus': FieldValue.serverTimestamp(),
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Order marked as $newStatus!')),
      );
    } catch (e) {
      print('Error updating order status: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update status: ${e.toString().split(':')[1].trim()}')),
      );
    }
  }
}

class OrderDetailsSheet extends StatelessWidget {
  final Map<String, dynamic> orderData;
  final String orderId;
  final Function(String newStatus)? onUpdateStatus; // Callback for status updates

  const OrderDetailsSheet({
    super.key,
    required this.orderData,
    required this.orderId,
    this.onUpdateStatus,
  });

  // Function to launch phone dialer
  Future<void> _makePhoneCall(BuildContext context, String phoneNumber) async {
    if (phoneNumber == 'N/A' || phoneNumber.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Phone number not available.')),
      );
      return;
    }
    final Uri launchUri = Uri(
      scheme: 'tel',
      path: phoneNumber,
    );
    if (await canLaunchUrl(launchUri)) {
      await launchUrl(launchUri);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not launch $phoneNumber')),
      );
    }
  }

  // Function to launch navigation to a destination
  Future<void> _navigateToDestination(BuildContext context, LatLng destination) async {
    try {
      // 1. Request location permissions
      LocationPermission permission = await Geolocator.requestPermission();

      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Location permission denied. Cannot navigate.")),
        );
        return;
      }

      // 2. Get current position
      Position currentPosition = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);

      // 3. Construct Google Maps URL
      // saddr = source address/coordinates, daddr = destination address/coordinates
      final Uri url = Uri.parse(
        'https://www.google.com/maps/dir/${currentPosition.latitude},${currentPosition.longitude}/${destination.latitude},${destination.longitude}',
      );

      // 4. Launch the URL
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Could not open Google Maps for navigation.")),
        );
      }
    } catch (e) {
      print('Error navigating: $e');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error during navigation: $e")));
    }
  }


  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    print('OrderDetailsModal received data: $orderData'); // Debug print

    // --- Dynamic Data Extraction from orderData ---
    final String customerName = orderData['customerName'] ?? 'N/A';
    final String customerPhone = orderData['customerPhone'] ?? 'N/A';
    final String restaurantPhone = orderData['restaurantPhone'] ?? 'N/A';
    final String specialInstructions = orderData['customerNotes'] ?? 'No special instructions.';

    // Address construction - ONLY street, city, zipcode
    // Address construction - ONLY street, city, zipcode
    // Updated: Extract all address components
    final Map deliveryAddressMap = orderData['deliveryAddress'] ?? {};
    final String flat = deliveryAddressMap['flat'] ?? '';
    final String floor = deliveryAddressMap['floor'] ?? '';
    final String building = deliveryAddressMap['building'] ?? '';
    final String street = deliveryAddressMap['street'] ?? '';
    final String city = deliveryAddressMap['city'] ?? '';
    final String zip = (deliveryAddressMap['zipCode'] as String?) ?? '';

// Updated: Build address string in specified order with labels for flat/floor/building, skipping empty parts
    final addressParts = <String>[];
    if (flat.isNotEmpty) addressParts.add('Flat $flat');
    if (floor.isNotEmpty) addressParts.add('Floor $floor');
    if (building.isNotEmpty) addressParts.add('Building $building');
    if (street.isNotEmpty) addressParts.add(street);
    if (city.isNotEmpty) addressParts.add(city);
    if (zip.isNotEmpty) addressParts.add(zip);

    final String customerAddress = addressParts.isNotEmpty ? addressParts.join(', ') : 'N/A';



    // Order Items from 'items' List
    final List<dynamic> orderItems = orderData['items'] ?? [];

    // Total Amount
    final double totalAmount = (orderData['totalAmount'] as num?)?.toDouble() ?? 0.0;

    // Delivery Time (Using 'timestamps.placed' or 'timestamp')
    DateTime displayTime = DateTime.now(); // Default
    final Map<String, dynamic> timestampsMap = orderData['timestamps'] ?? {};
    if (timestampsMap['placed'] is Timestamp) {
      displayTime = (timestampsMap['placed'] as Timestamp).toDate();
    } else if (orderData['timestamp'] is Timestamp) {
      displayTime = (orderData['timestamp'] as Timestamp).toDate();
    }

    // Destination for Map from GeoPoint
    LatLng destination = const LatLng(25.286106, 51.533308); // Default: Souq Waqif, Doha
    if (deliveryAddressMap['geolocation'] is GeoPoint) {
      final GeoPoint geoPoint = deliveryAddressMap['geolocation'];
      destination = LatLng(geoPoint.latitude, geoPoint.longitude);
    } else {
      print('Warning: geolocation is not a GeoPoint or is missing for map. Using default Doha coordinates.');
    }


    return Container(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        // Wrap the Column with SingleChildScrollView to enable scrolling
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min, // Use min size for the column inside SingleChildScrollView
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle
              Center(
                child: Container(
                  width: 40,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade400,
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Google Map View (Miniature, at top)
              SizedBox(
                height: 160,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: destination, // Use actual delivery location
                      zoom: 14,
                    ),
                    markers: {
                      Marker(
                        markerId: const MarkerId('destination'),
                        position: destination, // Marker at delivery location
                        infoWindow: InfoWindow(title: customerName, snippet: customerAddress),
                      ),
                    },
                    zoomControlsEnabled: false,
                    myLocationButtonEnabled: false,
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Order Info Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text("Order #${orderData['dailyOrderNumber'] ?? orderId}", style: theme.textTheme.headlineSmall),
                  Text(
                    DateFormat.jm().format(displayTime), // Display order placed time
                    style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
                  ),
                ],
              ),

              const SizedBox(height: 16),
              _buildDetailInfoRow(Icons.person_outline, "Customer", customerName, theme),
              const Divider(height: 24),
              _buildDetailInfoRow(Icons.location_on_outlined, "Delivery Address", customerAddress, theme),
              const Divider(height: 24),
              _buildDetailInfoRow(Icons.phone_outlined, "Customer Phone", customerPhone, theme),
              // Removed Restaurant Phone row as the Call Restaurant button is removed.
              // const Divider(height: 24),
              // _buildDetailInfoRow(Icons.restaurant_menu_outlined, "Restaurant Phone", restaurantPhone, theme),
              const Divider(height: 24), // Keep one divider for spacing if needed after removing a row.

              const SizedBox(height: 16),
              const Text(
                "Order Items",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              // Dynamically build order items
              if (orderItems.isEmpty)
                const Text('No items listed for this order.')
              else
                ...orderItems.map((item) {
                  // Combine 'options' into a note string if they exist
                  String itemNotes = '';
                  if (item['options'] is List && item['options'].isNotEmpty) {
                    itemNotes += (item['options'] as List)
                        .map((option) => option['name'] ?? '')
                        .where((name) => name.isNotEmpty)
                        .join(', ');
                  }

                  return _itemRow(
                    item['name'] ?? 'Unknown Item', // Use 'name' from the item map
                    itemNotes,
                    'x${item['quantity'] ?? 1}',
                  );
                }).toList(),
              const Divider(),
              _infoRow(Icons.monetization_on, "Total: QR ${totalAmount.toStringAsFixed(2)}"),

              const SizedBox(height: 16),
              const Text(
                "Special Instructions",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.yellow.shade50,
                  border: Border.all(color: Colors.yellow.shade200),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  specialInstructions.isNotEmpty ? specialInstructions : "No special instructions.",
                  style: const TextStyle(fontSize: 13, color: Colors.black),
                ),
              ),

              const SizedBox(height: 12), // Adjusted spacing

              // Action Buttons (Call Customer, Navigate)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.call_outlined),
                      label: const Text("Call Customer"),
                      onPressed: () => _makePhoneCall(context, customerPhone),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        foregroundColor: theme.primaryColor,
                        side: BorderSide(color: theme.primaryColor),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.navigation_outlined),
                      label: const Text("Navigate"),
                      onPressed: () => _navigateToDestination(context, destination),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        backgroundColor: theme.primaryColor,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  )
                ],
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }

  // Helper widget for information rows
  Widget _buildDetailInfoRow(IconData icon, String label, String value, ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: theme.colorScheme.secondary, size: 24),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(color: theme.colorScheme.secondary, fontSize: 14)),
              const SizedBox(height: 4),
              Text(value, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: theme.colorScheme.onBackground)),
            ],
          ),
        ),
      ],
    );
  }

  // Helper widget for information rows
  Widget _infoRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.grey),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  // Helper widget for order item rows
  Widget _itemRow(String title, String note, String count) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                if (note.isNotEmpty)
                  Text(
                    note,
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
              ],
            ),
          ),
          Text(count, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  // Modified status button to use the callback
  Widget _statusButton(BuildContext context, String label, Color color, String newStatus) {
    return Expanded(
      child: ElevatedButton(
        onPressed: () {
          if (onUpdateStatus != null) {
            onUpdateStatus!(newStatus); // Call the provided callback
            // The modal will pop itself after the update is attempted
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Status update function not provided.')),
            );
          }
        },
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 12, color: Colors.white),
        ),
      ),
    );
  }
}