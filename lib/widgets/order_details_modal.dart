import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../theme/app_theme.dart';

// ============================================================================
// MODERNIZED ORDER DETAILS SHEET
// ============================================================================

class OrderDetailsSheet extends StatelessWidget {
  final Map<String, dynamic> orderData;
  final String orderId;
  final ScrollController scrollController;
  final Function(String newStatus)? onUpdateStatus;

  const OrderDetailsSheet({
    super.key,
    required this.orderData,
    required this.orderId,
    required this.scrollController,
    this.onUpdateStatus,
  });

  Future _makePhoneCall(BuildContext context, String phoneNumber) async {
    if (phoneNumber == 'N/A' || phoneNumber.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Phone number not available.')),
      );
      return;
    }

    final Uri launchUri = Uri(scheme: 'tel', path: phoneNumber);

    if (await canLaunchUrl(launchUri)) {
      await launchUrl(launchUri);
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not launch $phoneNumber')));
    }
  }

  Future _navigateToDestination(
    BuildContext context,
    LatLng destination,
  ) async {
    try {
      LocationPermission permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Location permission denied. Cannot navigate."),
          ),
        );
        return;
      }

      Position currentPosition = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      final Uri url = Uri.parse(
        'https://www.google.com/maps/dir/${currentPosition.latitude},${currentPosition.longitude}/${destination.latitude},${destination.longitude}',
      );

      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Could not open Google Maps for navigation."),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error navigating: $e');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Error during navigation: $e")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    debugPrint('OrderDetailsModal received data: $orderData');

    // Data extraction
    final String customerName = orderData['customerName'] ?? 'N/A';
    final String customerPhone = orderData['customerPhone'] ?? 'N/A';
    final String restaurantPhone = orderData['restaurantPhone'] ?? 'N/A';
    final String specialInstructions =
        orderData['customerNotes'] ?? 'No special instructions.';

    // Address construction
    final Map deliveryAddressMap = orderData['deliveryAddress'] ?? {};
    final String flat = deliveryAddressMap['flat'] ?? '';
    final String floor = deliveryAddressMap['floor'] ?? '';
    final String building = deliveryAddressMap['building'] ?? '';
    final String street = deliveryAddressMap['street'] ?? '';
    final String city = deliveryAddressMap['city'] ?? '';
    final String zip = (deliveryAddressMap['zipCode'] as String?) ?? '';

    final addressParts = [];
    if (flat.isNotEmpty) addressParts.add('Flat $flat');
    if (floor.isNotEmpty) addressParts.add('Floor $floor');
    if (building.isNotEmpty) addressParts.add('Building $building');
    if (street.isNotEmpty) addressParts.add(street);
    if (city.isNotEmpty) addressParts.add(city);
    if (zip.isNotEmpty) addressParts.add(zip);
    final String customerAddress =
        addressParts.isNotEmpty ? addressParts.join(', ') : 'N/A';

    final List orderItems = orderData['items'] ?? [];
    final double totalAmount =
        (orderData['totalAmount'] as num?)?.toDouble() ?? 0.0;

    // Delivery Time
    DateTime displayTime = DateTime.now();
    final Map timestampsMap = orderData['timestamps'] ?? {};
    if (timestampsMap['placed'] is Timestamp) {
      displayTime = (timestampsMap['placed'] as Timestamp).toDate();
    } else if (orderData['timestamp'] is Timestamp) {
      displayTime = (orderData['timestamp'] as Timestamp).toDate();
    }

    // Destination for Map
    LatLng destination = const LatLng(25.286106, 51.533308);
    if (deliveryAddressMap['geolocation'] is GeoPoint) {
      final GeoPoint geoPoint = deliveryAddressMap['geolocation'];
      destination = LatLng(geoPoint.latitude, geoPoint.longitude);
    } else {
      debugPrint(
        'Warning: geolocation is not a GeoPoint or is missing for map. Using default Doha coordinates.',
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: SingleChildScrollView(
          controller: scrollController,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag Handle - modernized
              Center(
                child: Container(
                  width: 48,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Google Map - modernized with elevated shadow
              Container(
                height: 180,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.15),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: destination,
                      zoom: 14,
                    ),
                    markers: {
                      Marker(
                        markerId: const MarkerId('destination'),
                        position: destination,
                        infoWindow: InfoWindow(
                          title: customerName,
                          snippet: customerAddress,
                        ),
                      ),
                    },
                    zoomControlsEnabled: false,
                    myLocationButtonEnabled: false,
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Order Header - modernized
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      "Order #${orderData['dailyOrderNumber'] ?? orderId}",
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: theme.primaryColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      DateFormat.jm().format(displayTime),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: theme.primaryColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Customer Info Card - modernized
              _buildModernInfoCard(
                context,
                icon: Icons.person_outline_rounded,
                label: "Customer",
                value: customerName,
                theme: theme,
              ),
              const SizedBox(height: 12),

              // Address Info Card - modernized
              _buildModernInfoCard(
                context,
                icon: Icons.location_on_outlined,
                label: "Delivery Address",
                value: customerAddress,
                theme: theme,
              ),
              const SizedBox(height: 12),

              // Phone Info Card - modernized
              _buildModernInfoCard(
                context,
                icon: Icons.phone_outlined,
                label: "Customer Phone",
                value: customerPhone,
                theme: theme,
              ),
              const SizedBox(height: 24),

              // Order Items Section - modernized
              Text(
                "Order Items",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 17,
                  color: theme.colorScheme.onBackground,
                ),
              ),
              const SizedBox(height: 12),

              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.cardColor,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.grey.withOpacity(0.15),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.04),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    if (orderItems.isEmpty)
                      const Text('No items listed for this order.')
                    else
                      ...orderItems.asMap().entries.map((entry) {
                        final index = entry.key;
                        final item = entry.value;
                        String itemNotes = '';
                        if (item['options'] is List &&
                            item['options'].isNotEmpty) {
                          itemNotes += (item['options'] as List)
                              .map((option) => option['name'] ?? '')
                              .where((name) => name.isNotEmpty)
                              .join(', ');
                        }

                        return Column(
                          children: [
                            if (index > 0)
                              const Divider(height: 20, thickness: 1),
                            _modernItemRow(
                              item['name'] ?? 'Unknown Item',
                              itemNotes,
                              'x${item['quantity'] ?? 1}',
                              theme,
                            ),
                          ],
                        );
                      }).toList(),
                    const Divider(height: 24, thickness: 1),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.monetization_on_outlined,
                              size: 20,
                              color: theme.primaryColor,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              "Total",
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.onBackground,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          "QR ${totalAmount.toStringAsFixed(2)}",
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: theme.primaryColor,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Special Instructions - modernized
              Text(
                "Special Instructions",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 17,
                  color: theme.colorScheme.onBackground,
                ),
              ),
              const SizedBox(height: 12),

              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.amber.shade50, Colors.orange.shade50],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  border: Border.all(color: Colors.amber.shade200, width: 1.5),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.amber.withOpacity(0.1),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      color: Colors.amber.shade800,
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        specialInstructions.isNotEmpty
                            ? specialInstructions
                            : "No special instructions.",
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.amber.shade900,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Action Buttons - modernized with gradient and elevation
              Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 50,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: theme.primaryColor, width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: theme.primaryColor.withOpacity(0.2),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.call_outlined, size: 20),
                        label: const Text(
                          "Call",
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        onPressed: () => _makePhoneCall(context, customerPhone),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: theme.primaryColor,
                          side: BorderSide.none,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Container(
                      height: 50,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            theme.primaryColor,
                            theme.primaryColor.withOpacity(0.8),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                            color: theme.primaryColor.withOpacity(0.4),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.navigation_outlined, size: 20),
                        label: const Text(
                          "Navigate",
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        onPressed:
                            () => _navigateToDestination(context, destination),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          foregroundColor: Colors.white,
                          shadowColor: Colors.transparent,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  // Modern Info Card Widget
  Widget _buildModernInfoCard(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required ThemeData theme,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.withOpacity(0.15), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.primaryColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: theme.primaryColor, size: 22),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: theme.colorScheme.secondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    color: theme.colorScheme.onBackground,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Modern Item Row Widget
  Widget _modernItemRow(
    String title,
    String note,
    String count,
    ThemeData theme,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                  color: theme.colorScheme.onBackground,
                ),
              ),
              if (note.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    note,
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                      height: 1.3,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: theme.primaryColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            count,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: theme.primaryColor,
            ),
          ),
        ),
      ],
    );
  }
}
