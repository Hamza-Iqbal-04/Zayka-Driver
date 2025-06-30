class Delivery {
  final String id;
  final String customerName;
  final String address;
  final String status;
  final String deliveryTime;
  final double distance;
  final double earnings;
  final List<OrderItem> items;
  final String? specialInstructions;

  Delivery({
    required this.id,
    required this.customerName,
    required this.address,
    required this.status,
    required this.deliveryTime,
    required this.distance,
    required this.earnings,
    required this.items,
    this.specialInstructions,
  });
}

class OrderItem {
  final String name;
  final int quantity;
  final String? specialInstructions;

  OrderItem({
    required this.name,
    required this.quantity,
    this.specialInstructions,
  });
}
