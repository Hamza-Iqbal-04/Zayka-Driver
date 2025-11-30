import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geolocator_android/geolocator_android.dart';
import 'package:geolocator_apple/geolocator_apple.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:myapp/theme/app_theme.dart';
import 'package:myapp/widgets/delivery_card.dart';
import 'package:myapp/widgets/order_details_modal.dart';
import '../utils/AssignmentOffer.dart';
import 'package:permission_handler/permission_handler.dart'; // Add this

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // --- Firebase & Rider Info ---
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  String? _riderEmail;
  DocumentReference<Map<String, dynamic>>? _riderDocRef;

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _assignedOrdersSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _pendingAssignSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _acceptedAssignSub;

  // --- Location Monitoring State ---
  StreamSubscription<Position>? _locSub;
  String? _monitoringOrderId;
  static const double _ARRIVAL_RADIUS_METERS = 50;

  // --- Notification & Sound State ---
  final FlutterLocalNotificationsPlugin _notifier = FlutterLocalNotificationsPlugin();
  final AudioPlayer _player = AudioPlayer();

  bool _initialAssignedSnapshotDone = false;
  final Set<String> _selfAccepted = {};

  // --- Assignment Offer Overlay State ---
  OverlayEntry? _offerOverlay;
  // queue item = { 'assignmentId': '...', 'orderId': '...' }
  final List<Map<String, String>> _offerQueue = <Map<String, String>>[];
  bool _offerShowing = false;

  // --- Branch filtering helpers ---
  final Set<String> _riderBranchIds = {};
  String _normalizeBranch(String s) => s.trim().toLowerCase();
  bool _orderMatchesBranches(List<dynamic>? orderBranches, Iterable<String> riderBranches) {
    final orderSet = (orderBranches ?? const [])
        .map((e) => _normalizeBranch(e.toString()))
        .toSet();
    final riderSet = riderBranches.map(_normalizeBranch).toSet();
    return orderSet.intersection(riderSet).isNotEmpty;
  }

  // ------------- Offer queue helpers -------------
  void _enqueueOffer(String assignmentId, String orderId) {
    // Prevent duplicates of the same assignment id in queue
    final exists = _offerQueue.any((e) => e['assignmentId'] == assignmentId);
    if (!exists) {
      _offerQueue.add({'assignmentId': assignmentId, 'orderId': orderId});
      if (!_offerShowing) _dequeueAndShow();
    }
  }

  void _dequeueAndShow() {
    if (_offerQueue.isEmpty || !mounted) return;
    final item = _offerQueue.removeAt(0);
    final assignmentId = item['assignmentId']!;
    final orderId = item['orderId']!;
    _showAssignmentOfferOverlay(assignmentId, orderId);
  }

  void _removeOfferOverlay() {
    _offerOverlay?.remove();
    _offerOverlay = null;
    _offerShowing = false;
    WidgetsBinding.instance.addPostFrameCallback((_) => _dequeueAndShow());
  }

  // ------------- Lifecycle -------------
  @override
  void initState() {
    super.initState();
    _initLocalNotifications();
    _loadCurrentRiderInfo();
    _checkBatteryOptimizations();
  }

  @override
  void dispose() {
    _assignedOrdersSub?.cancel();
    _pendingAssignSub?.cancel();
    _acceptedAssignSub?.cancel();
    _locSub?.cancel();
    _player.dispose();
    _removeOfferOverlay();
    super.dispose();
  }

  // ------------- Location Logic -------------
  Future<bool> _ensureBgLocationPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Location services are disabled. Please enable them.')),
        );
      }
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location permission is required.')),
          );
        }
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Go to settings to enable location permissions.')),
        );
      }
      await Geolocator.openAppSettings();
      return false;
    }

    return true;
  }

  LocationSettings _bgLocationSettings() {
    const distanceFilter = 10;
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: distanceFilter,
        intervalDuration: const Duration(seconds: 5),
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Delivery in Progress',
          notificationText: 'Sharing live location for your active order',
          enableWakeLock: true,
          setOngoing: true,
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
      return const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: distanceFilter,
      );
    }
  }

  Future<void> _checkBatteryOptimizations() async {
    // This permission is critical for receiving notifications when screen is off
    var status = await Permission.ignoreBatteryOptimizations.status;
    if (status.isDenied) {
      // Request the user to disable battery optimizations
      await Permission.ignoreBatteryOptimizations.request();
    }
  }

  Future<void> _startArrivalMonitor(Map<String, dynamic> orderData, String orderId) async {
    // If already monitoring this order, do nothing.
    if (_monitoringOrderId == orderId && _locSub != null) {
      debugPrint("Already monitoring order $orderId. Skipping.");
      return;
    }

    debugPrint("Starting arrival monitor for order $orderId...");
    await _stopArrivalMonitor();
    _monitoringOrderId = orderId;

    final GeoPoint? drop = orderData['deliveryAddress']?['geolocation'];
    if (drop == null) {
      debugPrint("! No drop-off location found for order $orderId.");
      _monitoringOrderId = null;
      return;
    }

    final hasPermission = await _ensureBgLocationPermission();
    if (!mounted || !hasPermission) {
      debugPrint("! Permission denied or widget not mounted. Aborting monitor.");
      _monitoringOrderId = null;
      return;
    }

    bool arrivalNotified = orderData['arrivalNotified'] == true;
    final settings = _bgLocationSettings();

    _locSub = Geolocator.getPositionStream(locationSettings: settings).listen(
          (pos) async {
        debugPrint("--> Location Update: ${pos.latitude}, ${pos.longitude}");
        if (!mounted || _riderDocRef == null) return;

        // Update rider live location
        try {
          await _riderDocRef!.update({'currentLocation': GeoPoint(pos.latitude, pos.longitude)});
        } catch (e) {
          debugPrint("! Failed to update rider location: $e");
        }

        // Distance to destination
        final dist = Geolocator.distanceBetween(
          pos.latitude,
          pos.longitude,
          drop.latitude,
          drop.longitude,
        );
        debugPrint(" Distance to destination: ${dist.toStringAsFixed(2)} m.");

        if (dist <= _ARRIVAL_RADIUS_METERS && !arrivalNotified) {
          arrivalNotified = true;
          debugPrint("!!! Arrival threshold reached for order $orderId. Notifying.");
          try {
            await _firestore.collection('Orders').doc(orderId).set({
              'arrivalNotified': true,
              'arrivedAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
          } catch (e) {
            debugPrint("! Failed to set arrivalNotified: $e");
          }
        }
      },
      onError: (error) async {
        debugPrint("!!! Location Stream Error: $error");
        await _stopArrivalMonitor();
      },
      onDone: () {
        debugPrint("Location stream closed.");
        _monitoringOrderId = null;
      },
    );

    debugPrint("Location stream listening for order $orderId.");
  }

  Future<void> _stopArrivalMonitor() async {
    if (_locSub != null) {
      debugPrint("Stopping active location monitor for order $_monitoringOrderId.");
      await _locSub?.cancel();
      _locSub = null;
    }
    _monitoringOrderId = null;
  }

  // ------------- Notifications & Rider Info -------------
  Future<void> _initLocalNotifications() async {
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

  // ------------- Assignment Offer Overlay -------------
  Future<void> _showAssignmentOfferOverlay(String assignmentDocId, String orderId) async {
    if (!mounted) return;
    if (_offerShowing) return;
    _offerShowing = true;

    try {
      final docRef = _firestore.collection('rider_assignments').doc(assignmentDocId);
      final snap = await docRef.get();
      if (!snap.exists) {
        _offerShowing = false;
        WidgetsBinding.instance.addPostFrameCallback((_) => _dequeueAndShow());
        return;
      }

      final data = snap.data() as Map<String, dynamic>? ?? {};
      final status = (data['status'] as String?) ?? 'pending';
      if (status != 'pending') {
        _offerShowing = false;
        WidgetsBinding.instance.addPostFrameCallback((_) => _dequeueAndShow());
        return;
      }

      // Compute initial countdown
      int initialSeconds = 120;
      final tsVal = data['timeoutSeconds'];
      if (tsVal is int && tsVal > 0) {
        initialSeconds = tsVal;
      }

      DateTime? expiresAt;
      final expiresTs = data['expiresAt'];
      if (expiresTs is Timestamp) {
        expiresAt = expiresTs.toDate();
        final remaining = expiresAt.difference(DateTime.now()).inSeconds;
        if (remaining > 0) {
          initialSeconds = remaining.clamp(1, 600);
        } else {
          // already expired
          await docRef.set({
            'status': 'timeout',
            'respondedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
          _offerShowing = false;
          WidgetsBinding.instance.addPostFrameCallback((_) => _dequeueAndShow());
          return;
        }
      }

      _offerOverlay = OverlayEntry(
        builder: (context) {
          final theme = Theme.of(context);
          return SafeArea(
            child: Stack(
              children: [
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: AssignmentOfferBanner(
                    assignmentDocId: assignmentDocId,
                    orderId: orderId,
                    initialSeconds: initialSeconds,
                    expiresAt: expiresAt,
                    onAccept: () async {
                      _selfAccepted.add(orderId);
                      try {
                        // Branch guard on accept
                        final orderSnap = await _firestore.collection('Orders').doc(orderId).get();
                        final orderBranches = orderSnap.data()?['branchIds'] as List<dynamic>?;

                        // Ensure local rider branches are available
                        List<String> riderBranches = _riderBranchIds.toList();
                        if (riderBranches.isEmpty && _riderDocRef != null) {
                          final riderSnap = await _riderDocRef!.get();
                          riderBranches = (riderSnap.data()?['branchIds'] as List?)
                              ?.map((e) => e.toString())
                              .toList() ??
                              [];
                        }

                        if (!_orderMatchesBranches(orderBranches, riderBranches)) {
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('This order is from another branch.')),
                            );
                          }
                          await docRef.set({
                            'status': 'rejected',
                            'respondedAt': FieldValue.serverTimestamp(),
                          }, SetOptions(merge: true));
                          return;
                        }

                        await docRef.set({
                          'status': 'accepted',
                          'respondedAt': FieldValue.serverTimestamp(),
                        }, SetOptions(merge: true));

                        if (mounted) setState(() {});
                      } finally {
                        _removeOfferOverlay();
                      }
                    },
                    onReject: () async {
                      try {
                        await docRef.set({
                          'status': 'rejected',
                          'respondedAt': FieldValue.serverTimestamp(),
                        }, SetOptions(merge: true));
                      } finally {
                        _removeOfferOverlay();
                      }
                    },
                    onTimeout: () async {
                      try {
                        await docRef.set({
                          'status': 'timeout',
                          'respondedAt': FieldValue.serverTimestamp(),
                        }, SetOptions(merge: true));
                      } finally {
                        _removeOfferOverlay();
                      }
                    },
                    onResolvedExternally: _removeOfferOverlay,
                    cardColor: theme.cardColor,
                  ),
                ),
              ],
            ),
          );
        },
      );

      Overlay.of(context).insert(_offerOverlay!);
    } catch (e) {
      debugPrint('Failed to show assignment offer overlay for $orderId: $e');
      _offerShowing = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _dequeueAndShow());
    }
  }

  // ------------- Rider bootstrap -------------
  Future<void> _loadCurrentRiderInfo() async {
    final User? currentUser = _auth.currentUser;
    if (currentUser == null || currentUser.email == null) return;
    final email = currentUser.email!;
    setState(() {
      _riderEmail = email;
      _riderDocRef = _firestore.collection('Drivers').doc(email);
    });

    await _saveFcmToken();
    _listenForAssignedOrders();
    _listenForAssignmentOffers();
  }

  Future<void> _saveFcmToken() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null && _riderDocRef != null) {
        await _riderDocRef!.set({'fcmToken': token}, SetOptions(merge: true));
      }
      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
        if (_riderDocRef != null) {
          await _riderDocRef!.set({'fcmToken': newToken}, SetOptions(merge: true));
        }
      });
    } catch (e) {
      debugPrint('Failed to save token: $e');
    }
  }

  // ------------- Streams -------------
  void _listenForAssignedOrders() {
    if (_riderEmail == null) return;
    _assignedOrdersSub = _firestore
        .collection('Orders')
        .where('riderId', isEqualTo: _riderEmail)
        .where('status', whereIn: ['assigned', 'rider_assigned', 'accepted'])
        .snapshots()
        .listen((snapshot) {
      if (!_initialAssignedSnapshotDone) {
        _initialAssignedSnapshotDone = true;
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

  void _listenForAssignmentOffers() {
    if (_riderEmail == null) return;

    // Listen for pending assignment offers for this rider
    _pendingAssignSub = _firestore
        .collection('rider_assignments')
        .where('riderId', isEqualTo: _riderEmail)
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .listen((snap) {
      for (final change in snap.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final assignmentId = change.doc.id;
          final data = change.doc.data();
          final orderId = (data?['orderId'] as String?) ?? '';
          if (orderId.isEmpty) continue;
          _filterAndEnqueueOffer(assignmentId, orderId);
        }
      }
    });

    // Optional: react when an assignment is accepted anywhere (refresh UI)
    _acceptedAssignSub = _firestore
        .collection('rider_assignments')
        .where('riderId', isEqualTo: _riderEmail)
        .where('status', isEqualTo: 'accepted')
        .snapshots()
        .listen((snap) {
      for (final change in snap.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final data = change.doc.data();
          final orderId = (data?['orderId'] as String?) ?? '';
          if (orderId.isNotEmpty) {
            _selfAccepted.add(orderId);
            if (mounted) setState(() {});
          }
        }
      }
    });
  }

  Future<void> _filterAndEnqueueOffer(String assignmentId, String orderId) async {
    try {
      final orderSnap = await _firestore.collection('Orders').doc(orderId).get();
      if (!orderSnap.exists) return;

      // Ensure we have driver's branches
      if (_riderBranchIds.isEmpty && _riderDocRef != null) {
        final riderSnap = await _riderDocRef!.get();
        final rb = (riderSnap.data()?['branchIds'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
            [];
        _riderBranchIds
          ..clear()
          ..addAll(rb);
      }

      final orderBranches = orderSnap.data()?['branchIds'] as List<dynamic>?;
      if (_orderMatchesBranches(orderBranches, _riderBranchIds)) {
        _enqueueOffer(assignmentId, orderId);
      } else {
        // Optionally auto-reject; currently ignored.
      }
    } catch (_) {
      // Not critical
    }
  }

  // ------------- Alerts & Sounds -------------
  Future<void> _alertAndSound(Map<String, dynamic> orderData, String orderId) async {
    final orderLabel = orderData['dailyOrderNumber']?.toString() ?? orderId;

    if (mounted) {
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('New Order Assigned'),
          content: Text('Order #$orderLabel has just been assigned to you.'),
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
      'new-orders-v2',
      'New Orders',
      importance: Importance.max,
      priority: Priority.high,
      sound: RawResourceAndroidNotificationSound('new_order'),
    );
    const iosDetails = DarwinNotificationDetails(sound: 'new_order.aiff');

    await _notifier.show(
      orderId.hashCode,
      'New order assigned',
      'Order #$orderLabel has just been assigned to you.',
      const NotificationDetails(android: androidDetails, iOS: iosDetails),
      payload: orderId,
    );

    await _player.play(AssetSource('sounds/new_order.mp3'));
  }

  // ------------- UI Helpers -------------
  void _showOrderDetailsSheet(BuildContext context, Map<String, dynamic> orderData, String orderId) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.5),
      isDismissible: true,
      enableDrag: true,
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.5,
          maxChildSize: 0.9,
          builder: (context, scrollController) {
            return OrderDetailsSheet(
              orderData: orderData,
              orderId: orderId,
              scrollController: scrollController,
            );
          },
        );
      },
    );
  }


  Future<void> _updateRiderStatus(bool isOnline) async {
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
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          backgroundColor: theme.cardColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20.0)),
          title: Text(title, style: theme.textTheme.titleLarge),
          content: Text(content, style: theme.textTheme.bodyMedium),
          actions: [
            TextButton(
              child: Text('Cancel', style: TextStyle(color: theme.colorScheme.secondary)),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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

  // ------------- Build -------------
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
          final String riderName = riderData['name']?.toString().split(' ').first ?? 'Rider';

          final List<String> riderBranches = (riderData['branchIds'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
              [];
          _riderBranchIds
            ..clear()
            ..addAll(riderBranches);

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
                Expanded(child: _buildAvailableOrdersStream(riderBranches))
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
              Text(
                isOnline ? "Online" : "Offline",
                style: TextStyle(
                  color: isOnline ? Colors.green : Colors.red,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
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
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.withOpacity(0.2), width: 1),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text("My Status", style: Theme.of(context).textTheme.titleMedium),
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

  // --- Streams for orders ---
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
          _stopArrivalMonitor();
          return const Center(child: Text("Something went wrong."));
        }
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          _stopArrivalMonitor();
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16.0),
              child: Text("No active assigned orders."),
            ),
          );
        }

        final orderDoc = snapshot.data!.docs.first;
        final orderData = orderDoc.data();
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
                content: 'Mark this order as ${newStatus == 'pickedUp' ? 'Picked Up' : 'Delivered'}?',
                onConfirm: () => _updateOrderStatus(orderDoc.id, newStatus),
              );
            },
            onCardTap: () => _showOrderDetailsSheet(context, orderData, orderDoc.id),
            actionButtonText: orderData['status'] == 'accepted' || orderData['status'] == 'rider_assigned'
                ? 'Mark Picked Up'
                : 'Mark Delivered',
            nextStatus: orderData['status'] == 'accepted' || orderData['status'] == 'rider_assigned'
                ? 'pickedUp'
                : 'delivered',
            isAcceptAction: false,
          ),
        );
      },
    );
  }

  Widget _buildAvailableOrdersStream(List<String> riderBranches) {
    // If the driver has no branches configured, show a friendly message.
    if (riderBranches.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text("No branch configured on your profile. Please contact support."),
        ),
      );
    }

    // Server-side filter for any matching branch (up to 10 values per Firestore constraint).
    final List<String> branchFilter = riderBranches.take(10).toList();

    Query<Map<String, dynamic>> q = _firestore
        .collection('Orders')
        .where('status', isEqualTo: 'prepared')
        .where('riderId', isEqualTo: "");

    // Apply branchIds filter
    q = q.where('branchIds', arrayContainsAny: branchFilter);

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: q.snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Text("Something went wrong."));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        // Client-side safety filter (also handles if more than 10 branches exist).
        final filtered = snapshot.data!.docs.where((doc) {
          final orderBranches = doc.data()['branchIds'] as List<dynamic>?;
          return _orderMatchesBranches(orderBranches, riderBranches);
        }).toList();

        if (filtered.isEmpty) {
          return const Center(child: Text("No new orders available."));
        }

        return ListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: filtered.length,
          itemBuilder: (context, index) {
            final orderDoc = filtered[index];
            final orderData = orderDoc.data();
            return Padding(
              padding: const EdgeInsets.only(bottom: 12.0),
              child: DeliveryCard(
                orderData: orderData,
                orderId: orderDoc.id,
                statusColor: _getStatusColor(orderData['status']),
                onAccept: () {
                  _showConfirmationDialog(
                    context: context,
                    title: 'Accept Order?',
                    content: 'Are you sure you want to accept this delivery?',
                    onConfirm: () => _acceptOrder(orderDoc.id),
                  );
                },
                onCardTap: () => _showOrderDetailsSheet(context, orderData, orderDoc.id),
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

  // ------------- Order actions -------------
  Future<void> _acceptOrder(String orderDocId) async {
    if (_riderEmail == null || _riderDocRef == null) return;
    try {
      await _firestore.runTransaction((tx) async {
        final orderRef = _firestore.collection('Orders').doc(orderDocId);
        final orderSnap = await tx.get(orderRef);
        if (!orderSnap.exists) {
          throw Exception("Order not found.");
        }

        final orderData = orderSnap.data() as Map<String, dynamic>? ?? {};
        final String riderId = (orderData['riderId'] as String?) ?? "";
        final String status = (orderData['status'] as String?) ?? "";
        final bool assignmentPending = (orderData['assignmentPending'] as bool?) == true;

        // Load driver's branches inside the transaction for consistency
        final riderSnap = await tx.get(_riderDocRef!);
        final List<String> riderBranches = (riderSnap.data()?['branchIds'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
            [];
        final List<dynamic>? orderBranches = orderData['branchIds'] as List<dynamic>?;

        // Enforce branch match
        if (!_orderMatchesBranches(orderBranches, riderBranches)) {
          throw Exception("This order belongs to another branch.");
        }

        if (riderId.isEmpty && status == 'prepared' && !assignmentPending) {
          tx.update(orderRef, {
            'riderId': _riderEmail,
            'status': 'rider_assigned',
            'timestamps.accepted': FieldValue.serverTimestamp(),
          });
        } else {
          throw Exception("Order already taken or being assigned.");
        }
      });

      _selfAccepted.add(orderDocId);

      if (_riderDocRef != null) {
        await _riderDocRef!.set(
          {
            'assignedOrderId': orderDocId,
            'isAvailable': false,
          },
          SetOptions(merge: true),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: ${e.toString()}")),
        );
      }
    }
  }

  Future<void> _updateOrderStatus(String orderDocId, String newStatus) async {
    try {
      await _firestore.collection('Orders').doc(orderDocId).update({
        'status': newStatus,
        'timestamps.$newStatus': FieldValue.serverTimestamp(),
      });

      if (newStatus == 'delivered') {
        await _stopArrivalMonitor();
        if (_riderDocRef != null) {
          await _riderDocRef!.set(
            {
              'isAvailable': true,
              'assignedOrderId': '',
            },
            SetOptions(merge: true),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: ${e.toString()}")),
        );
      }
    }
  }
}