import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:myapp/theme/app_theme.dart';
import 'package:myapp/widgets/delivery_card.dart';
import 'package:myapp/widgets/order_details_modal.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:geolocator_android/geolocator_android.dart';
import 'package:geolocator_apple/geolocator_apple.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // --- Firebase & Rider Info ---
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  String? _riderEmail;
  DocumentReference<Map<String, dynamic>>? _riderDocRef;

  // --- Location Monitoring State ---
  StreamSubscription<Position>? _locSub;
  String? _monitoringOrderId;
  static const double _ARRIVAL_RADIUS_METERS = 50;

  // --- Notification & Sound State ---
  final FlutterLocalNotificationsPlugin _notifier = FlutterLocalNotificationsPlugin();
  final AudioPlayer _player = AudioPlayer();
  StreamSubscription? _assignSub;
  bool _initialSnapshotDone = false;
  final Set<String> _selfAccepted = {};

  @override
  void initState() {
    super.initState();
    _initLocalNotifications();
    _loadCurrentRiderInfo();
  }

  @override
  void dispose() {
    _assignSub?.cancel();
    _locSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  // --- Location Logic ---
  Future<bool> _ensureBgLocationPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Location services are disabled. Please enable them.')));
      }
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text('Location permission is required.')));
        }
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Go to settings to enable location permissions.')));
        await Geolocator.openAppSettings();
      }
      return false;
    }
    return true;
  }

  LocationSettings _bgLocationSettings() {
    final distanceFilter = 10; // Reduced for more frequent updates during testing
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: distanceFilter,
        intervalDuration: const Duration(seconds: 5), // More frequent interval
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Delivery in Progress',
          notificationText: 'Sharing live location for your active order',
          enableWakeLock: true, setOngoing: true,
        ),
      );
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        activityType: ActivityType.automotiveNavigation,
        distanceFilter: distanceFilter,
        pauseLocationUpdatesAutomatically: true,
        showBackgroundLocationIndicator: true,
      );
    } else {
      return LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: distanceFilter,
      );
    }
  }

  void _startArrivalMonitor(Map<String, dynamic> orderData, String orderId) async {
    // If we are already monitoring this exact order, do nothing.
    if (_monitoringOrderId == orderId && _locSub != null) {
      debugPrint("Already monitoring order $orderId. Skipping.");
      return;
    }

    debugPrint("Starting arrival monitor for order $orderId...");
    await _stopArrivalMonitor(); // Stop any previous monitor before starting a new one.
    _monitoringOrderId = orderId;

    // Extract drop-off location.
    final GeoPoint? drop = orderData['deliveryAddress']?['geolocation'];
    if (drop == null) {
      debugPrint("! No drop-off location found for order $orderId.");
      _monitoringOrderId = null;
      return;
    }

    // Ensure permissions and services are OK.
    final hasPermission = await _ensureBgLocationPermission();
    if (!mounted || !hasPermission) {
      debugPrint("! Permission denied or widget not mounted. Aborting monitor.");
      _monitoringOrderId = null;
      return;
    }

    // Keep tracking even if arrival was already notified; only use this to prevent duplicate writes.
    bool arrivalNotified = orderData['arrivalNotified'] == true;

    final settings = _bgLocationSettings();

    _locSub = Geolocator.getPositionStream(locationSettings: settings).listen(
          (pos) async {
        debugPrint("--> Location Update Received: ${pos.latitude}, ${pos.longitude}");
        if (!mounted || _riderDocRef == null) return;

        // Update rider's live location.
        try {
          await _riderDocRef!.update(
            {'currentLocation': GeoPoint(pos.latitude, pos.longitude)},
          );
        } catch (e) {
          debugPrint("! Failed to update rider location: $e");
        }

        // Compute distance to destination.
        final dist = Geolocator.distanceBetween(
          pos.latitude, pos.longitude, drop.latitude, drop.longitude,
        );
        debugPrint(" Distance to destination: ${dist.toStringAsFixed(2)} meters.");

        // When within the radius, notify once but DO NOT stop monitoring.
        if (dist <= _ARRIVAL_RADIUS_METERS && !arrivalNotified) {
          arrivalNotified = true;
          debugPrint("!!! Arrival threshold reached for order $orderId. Notifying (continuing tracking).");
          try {
            await _firestore.collection('Orders').doc(orderId).set({
              'arrivalNotified': true,
              'arrivedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
          } catch (e) {
            debugPrint("! Failed to set arrivalNotified: $e");
          }
          // Intentionally keep streaming; stop only when delivered or when there is no active order.
        }
      },
      onError: (error) async {
        debugPrint("!!! Location Stream Error: $error");
        await _stopArrivalMonitor();
      },
      onDone: () {
        debugPrint("Location stream was closed.");
        _monitoringOrderId = null;
      },
    );

    debugPrint("Location stream is now listening for order $orderId.");
  }

  Future<void> _stopArrivalMonitor() async {
    if (_locSub != null) {
      debugPrint(
          "Stopping active location monitor for order $_monitoringOrderId.");
      await _locSub?.cancel();
      _locSub = null;
    }
    _monitoringOrderId = null;
  }

  /* -------------------------------------------------------------------------
   * Notification & Rider Info Load
   * ---------------------------------------------------------------------- */
  Future _initLocalNotifications() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();
    await _notifier.initialize(
      const InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: _handleNotificationTap,
    );
  }

  void _handleNotificationTap(NotificationResponse response) {
    if (!mounted) return;
    final orderId = response.payload;
    if (orderId == null || _riderEmail == null) return;
    _firestore.collection('Orders').doc(orderId).get().then((snap) {
      if (snap.exists) {
        _showOrderDetailsSheet(context, snap.data()!, orderId);
      }
    });
  }

  Future _loadCurrentRiderInfo() async {
    final User? currentUser = _auth.currentUser;
    if (currentUser != null && currentUser.email != null) {
      setState(() {
        _riderEmail = currentUser.email;
        _riderDocRef = _firestore.collection('Drivers').doc(_riderEmail);
      });
      _listenForAssignedOrders();
    }
  }

  void _listenForAssignedOrders() {
    if (_riderEmail == null) return;
    _assignSub = _firestore
        .collection('Orders')
        .where('riderId', isEqualTo: _riderEmail)
        .where('status', whereIn: ['assigned', 'rider_assigned', 'accepted'])
        .snapshots()
        .listen((snapshot) {
      if (!_initialSnapshotDone) {
        _initialSnapshotDone = true;
        return;
      }
      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final orderId = change.doc.id;
          if (!_selfAccepted.remove(orderId)) {
            _alertAndSound(change.doc.data() as Map<String, dynamic>, orderId);
          }
        }
      }
    });
  }

  Future _alertAndSound(Map<String, dynamic> orderData, String orderId) async {
    final orderLabel = orderData['dailyOrderNumber']?.toString() ?? orderId;
    if (mounted) {
      showDialog(
        context: context,
        builder: (_) =>
            AlertDialog(
              title: const Text('New Order Assigned'),
              content: Text(
                  'Order #$orderLabel has just been assigned to you.'),
              actions: [
                TextButton(
                  child: const Text('View'),
                  onPressed: () {
                    Navigator.of(context).pop();
                    _showOrderDetailsSheet(context, orderData, orderId);
                  },
                ),
                TextButton(
                  child: const Text('Dismiss'),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
      );
    }
    const androidDetails = AndroidNotificationDetails(
      'new-orders-v2', 'New Orders',
      importance: Importance.max, priority: Priority.high,
      sound: RawResourceAndroidNotificationSound('new_order'),
    );
    const iosDetails = DarwinNotificationDetails(sound: 'new_order.aiff');
    await _notifier.show(
      orderId.hashCode, 'New order assigned',
      'Order #$orderLabel has just been assigned to you.',
      const NotificationDetails(android: androidDetails, iOS: iosDetails),
      payload: orderId,
    );
    await _player.play(AssetSource('sounds/new_order.mp3'));
  }

  /* -------------------------------------------------------------------------
   * UI Helpers
   * ---------------------------------------------------------------------- */
  void _showOrderDetailsSheet(BuildContext context,
      Map<String, dynamic> orderData, String orderId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) =>
          OrderDetailsSheet(orderData: orderData, orderId: orderId),
    );
  }

  Future _updateRiderStatus(bool isOnline) async {
    if (_riderDocRef != null) {
      await _riderDocRef!.update({'status': isOnline ? 'online' : 'offline'});
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

  Future<void> _showConfirmationDialog({
    required BuildContext context,
    required String title,
    required String content,
    required VoidCallback onConfirm,
  }) async {
    final theme = Theme.of(context);
    return showDialog(
      context: context, barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: theme.cardColor,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20.0)),
          title: Text(title, style: theme.textTheme.titleLarge),
          content: Text(content, style: theme.textTheme.bodyMedium),
          actions: [
            TextButton(
              child: Text('Cancel',
                  style: TextStyle(color: theme.colorScheme.secondary)),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.dangerColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: () {
                Navigator.of(dialogContext).pop();
                onConfirm();
              },
              child: const Text('Confirm'),
            ),
          ],
        );
      },
    );
  }

  /* -------------------------------------------------------------------------
   * BUILD
   * ---------------------------------------------------------------------- */
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_riderEmail == null || _riderDocRef == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Loading Dashboard...')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: _riderDocRef!.snapshots(),
        builder: (context, riderSnapshot) {
          if (riderSnapshot.hasError) {
            return const Center(child: Text("Error loading rider data."));
          }
          if (!riderSnapshot.hasData || !riderSnapshot.data!.exists) {
            return const Center(child: CircularProgressIndicator());
          }

          final riderData = riderSnapshot.data!.data()!;
          final bool isOnline = riderData['status'] == 'online';
          final String riderName = riderData['name']
              ?.split(' ')
              .first ?? 'Rider';

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(context, riderName, isOnline),
              _buildStatusToggle(isOnline),
              const SizedBox(height: 24),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.0),
                child: Text('My Current Delivery',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 20)),
              ),
              const SizedBox(height: 10),
              _buildAssignedOrderStream(),
              const SizedBox(height: 20),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.0),
                child: Text('Available Orders',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 20)),
              ),
              const SizedBox(height: 10),
              if (isOnline)
                Expanded(child: _buildAvailableOrdersStream())
              else
                const Expanded(
                  child: Center(
                    child: Text("You are offline.",
                        style: TextStyle(color: Colors.grey, fontSize: 16)),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /* -------------------------------------------------------------------------
   * Small widget builders
   * ---------------------------------------------------------------------- */
  Widget _buildHeader(BuildContext context, String name, bool isOnline) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.only(top: 50, left: 16, right: 16, bottom: 16),
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.cardColor,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 10,
              offset: const Offset(0, 4))
        ],
        borderRadius: const BorderRadius.only(
            bottomLeft: Radius.circular(24), bottomRight: Radius.circular(24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("Welcome, $name", style: theme.textTheme.headlineSmall),
          const SizedBox(height: 4),
          Row(
            children: [
              Text("You are currently ",
                  style: TextStyle(
                      color: theme.colorScheme.secondary, fontSize: 16)),
              Text(
                isOnline ? "Online" : "Offline",
                style: TextStyle(
                    color: isOnline ? Colors.green : Colors.red,
                    fontWeight: FontWeight.bold,
                    fontSize: 16),
              ),
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
          color: Theme
              .of(context)
              .cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.withOpacity(0.2), width: 1),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text("My Status", style: Theme
                .of(context)
                .textTheme
                .titleMedium),
            Switch(
              value: isOnline,
              onChanged: _updateRiderStatus,
              activeColor: Colors.green,
              inactiveTrackColor: Colors.grey.shade600,
            ),
          ],
        ),
      ),
    );
  }

  /* -------------------------------------------------------------------------
   * Streams
   * ---------------------------------------------------------------------- */
  Widget _buildAssignedOrderStream() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _firestore
          .collection('Orders')
          .where('riderId', isEqualTo: _riderEmail)
          .where('status', whereNotIn: ['delivered', 'cancelled'])
          .limit(1)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          _stopArrivalMonitor(); // Stop if there's an error
          return const Center(child: Text("Something went wrong."));
        }

        // If there is no active order, ensure the monitor is stopped.
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          _stopArrivalMonitor();
          return const Center(
              child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text("No active assigned orders.")));
        }

        final orderDoc = snapshot.data!.docs.first;
        final orderData = orderDoc.data();

        // This is the crucial call that triggers the monitoring logic
        _startArrivalMonitor(orderData, orderDoc.id);

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: DeliveryCard(
            orderData: orderData,
            orderId: orderDoc.id,
            statusColor: _getStatusColor(orderData['status']),
            onUpdateStatus: (newStatus) {
              _showConfirmationDialog(
                context: context,
                title: 'Confirm Status Change',
                content: 'Mark this order as ${newStatus == 'pickedUp'
                    ? 'Picked Up'
                    : 'Delivered'}?',
                onConfirm: () => _updateOrderStatus(orderDoc.id, newStatus),
              );
            },
            onCardTap: () =>
                _showOrderDetailsSheet(context, orderData, orderDoc.id),
            actionButtonText: orderData['status'] == 'accepted' ||
                orderData['status'] == 'rider_assigned'
                ? 'Mark Picked Up' : 'Mark Delivered',
            nextStatus: orderData['status'] == 'accepted' ||
                orderData['status'] == 'rider_assigned'
                ? 'pickedUp' : 'delivered',
            isAcceptAction: false,
          ),
        );
      },
    );
  }

  Widget _buildAvailableOrdersStream() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _firestore
          .collection('Orders')
          .where('status', isEqualTo: 'prepared')
          .where('riderId', isEqualTo: "")
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Text("Something went wrong."));
        }
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return const Center(child: Text("No new orders available."));
        }
        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: snapshot.data!.docs.length,
          itemBuilder: (context, index) {
            final orderDoc = snapshot.data!.docs[index];
            final orderData = orderDoc.data();
            return Padding(
              padding: const EdgeInsets.only(bottom: 12.0),
              child: DeliveryCard(
                orderData: orderData,
                orderId: orderDoc.id,
                statusColor: _getStatusColor(orderData['status']),
                onAccept: () {
                  _showConfirmationDialog(
                    context: context, title: 'Accept Order?',
                    content: 'Are you sure you want to accept this delivery?',
                    onConfirm: () => _acceptOrder(orderDoc.id),
                  );
                },
                onCardTap: () =>
                    _showOrderDetailsSheet(context, orderData, orderDoc.id),
                actionButtonText: 'Accept Order',
                nextStatus: 'accepted',
                isAcceptAction: true,
              ),
            );
          },
        );
      },
    );
  }

  /* -------------------------------------------------------------------------
   * Order actions
   * ---------------------------------------------------------------------- */
  Future _acceptOrder(String orderDocId) async {
    if (_riderEmail == null) return;
    try {
      await _firestore.runTransaction((tx) async {
        final ref = _firestore.collection('Orders').doc(orderDocId);
        final snap = await tx.get(ref);
        if (snap.exists && snap.data()?['riderId'] == "" &&
            snap.data()?['status'] == 'prepared') {
          tx.update(ref, {
            'riderId': _riderEmail,
            'status': 'rider_assigned',
            'timestamps.accepted': FieldValue.serverTimestamp(),
          });
        } else {
          throw Exception("Order already taken or not available.");
        }
      });
      _selfAccepted.add(orderDocId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Error: ${e.toString()}")));
      }
    }
  }

  Future _updateOrderStatus(String orderDocId, String newStatus) async {
    await _firestore.collection('Orders').doc(orderDocId).update({
      'status': newStatus,
      'timestamps.$newStatus': FieldValue.serverTimestamp(),
    });
    if (newStatus == 'delivered') {
      // When an order is delivered, stop the monitor.
      _stopArrivalMonitor();
      if (_riderDocRef != null) {
        await _riderDocRef!.update({'isAvailable': true});
      }
    }
  }
}