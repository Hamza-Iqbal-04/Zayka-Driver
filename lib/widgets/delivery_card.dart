import 'package:flutter/material.dart';
import '../utils/string_extensions.dart';

class DeliveryCard extends StatelessWidget {
  final Map<String, dynamic> orderData;
  final String orderId;
  final Color statusColor;
  final Function(String)? onUpdateStatus;
  final VoidCallback? onAccept;
  final String? actionButtonText; // << MODIFIED: Make nullable
  final String? nextStatus;       // << MODIFIED: Make nullable
  final bool isAcceptAction;
  final VoidCallback? onCardTap;

  const DeliveryCard({
    super.key,
    required this.orderData,
    required this.orderId,
    required this.statusColor,
    this.onUpdateStatus,
    this.onAccept,
    this.actionButtonText, // << MODIFIED: No longer 'required' implicitly if default is not provided
    // but you can still mark it as 'required' if you always want a value UNLESS it's history
    // For now, let's assume it can be completely absent (null) for history
    this.nextStatus,       // << MODIFIED
    this.isAcceptAction = false,
    this.onCardTap,
  });

  @override
  Widget build(BuildContext context) {
    debugPrint('DeliveryCard being built for orderId: ${orderData['orderId']}');
    final theme = Theme.of(context);
    final customerName = orderData['customerName'] ?? 'Unknown';

    // Updated: Extract all address components with debug prints for verification
    final deliveryAddress = orderData['deliveryAddress'] as Map<String, dynamic>? ?? {};
    final flat = deliveryAddress['flat'] as String? ?? '';
    final floor = deliveryAddress['floor'] as String? ?? '';
    final building = deliveryAddress['building'] as String? ?? '';
    final street = deliveryAddress['street'] as String? ?? '';
    final city = deliveryAddress['city'] as String? ?? '';

    // Debug prints to check values in console (remove after testing)
    debugPrint('Flat: $flat');
    debugPrint('Floor: $floor');
    debugPrint('Building: $building');
    debugPrint('Street: $street');
    debugPrint('City: $city');

    // Updated: Build address string in specified order with labels for flat/floor/building, skipping empty parts
    final addressParts = <String>[];
    if (flat.isNotEmpty) addressParts.add('Flat $flat');
    if (floor.isNotEmpty) addressParts.add('Floor $floor');
    if (building.isNotEmpty) addressParts.add('Building $building');
    if (street.isNotEmpty) addressParts.add(street);
    if (city.isNotEmpty) addressParts.add(city);

    final address = addressParts.isNotEmpty ? addressParts.join(', ') : 'N/A';

    String displayStatus = (orderData['status'] as String?)?.replaceAll('_', ' ').capitalize() ?? 'Unknown';

    return InkWell(
      onTap: onCardTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        // margin: const EdgeInsets.only(bottom: 16), // Margin is often handled by ListView.separated
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey.withOpacity(0.2), width: 1),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: const Offset(0, 4))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    "Order #${orderData['dailyOrderNumber'] ?? orderId}",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: theme.colorScheme.onBackground),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: statusColor.withOpacity(0.15), borderRadius: BorderRadius.circular(20)),
                  child: Text(
                      displayStatus.toUpperCase(),
                      style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 10)
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            _buildInfoRow(Icons.person_outline, "Customer", customerName, theme),
            const SizedBox(height: 8),
            _buildInfoRow(Icons.location_on_outlined, "Delivery To", address, theme),  // Updated: Use the new address string
            // << MODIFIED: Conditionally build the button >>
            if (actionButtonText != null && actionButtonText!.isNotEmpty) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: isAcceptAction
                      ? onAccept
                      : (nextStatus != null ? () => onUpdateStatus?.call(nextStatus!) : null),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary, // Use theme.primaryColor if it's what you mean
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(actionButtonText!, style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }



  Widget _buildInfoRow(IconData icon, String label, String value, ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: theme.colorScheme.secondary, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(color: theme.colorScheme.secondary, fontSize: 12)),
              const SizedBox(height: 2),
              Text(value, style: TextStyle(fontWeight: FontWeight.w600, color: theme.colorScheme.onBackground)),
            ],
          ),
        ),
      ],
    );
  }
}

// Helper extension (if not already in a shared file)
