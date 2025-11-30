import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

// Firebase core + messaging
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

// Local notifications
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// Screens and theme
import 'screens/home_screen.dart';
import 'screens/earnings_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/delivery_history_screen.dart';
import 'theme/app_theme.dart';
import 'theme/theme_provider.dart';

// Firebase options
import 'firebase_options.dart';

// Auth gate and assignment offer
import 'widgets/models/auth_gate.dart';
import 'utils/AssignmentOffer.dart';

// Global navigatorKey so taps from system notifications can navigate without BuildContext
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// Local notifications plugin and Android channel
final FlutterLocalNotificationsPlugin _flnp = FlutterLocalNotificationsPlugin();

const AndroidNotificationChannel _assignChannel = AndroidNotificationChannel(
  'rider-assignment',
  'Rider Assignment',
  description: 'Heads-up assignment requests',
  importance: Importance.high,
);

// Race-safe initializer that tolerates hot-restart overlap
Future<FirebaseApp> ensureFirebaseInitialized() async {
  if (Firebase.apps.isNotEmpty) {
    return Firebase.app();
  }
  try {
    return await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } on FirebaseException catch (e) {
    if (e.code == 'duplicate-app') {
      return Firebase.app();
    }
    rethrow;
  }
}

// Background handler for FCM (must be a top-level function)
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await ensureFirebaseInitialized();
  // Do minimal, isolate-safe work here (avoid navigation/UI in background isolate)
}

Future<void> _initLocalNotifications() async {
  const initSettings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(),
  );

  await _flnp.initialize(
    initSettings,
    onDidReceiveNotificationResponse: (resp) {
      final payload = resp.payload;
      if (payload != null && payload.isNotEmpty) {
        navigatorKey.currentState?.pushNamed(
          '/assignment-offer',
          arguments: payload,
        );
      }
    },
  );

  final android = _flnp
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  await android?.createNotificationChannel(_assignChannel);
}

// 1. Add this helper function to handle navigation logic centrally
void _handleMessage(RemoteMessage message) {
  final data = message.data;

  // Check for 'assignment_request' type which matches your Cloud Function payload
  if (data['type'] == 'assignment_request' && data['orderId'] != null) {

    // Use a small delay to ensure the navigator is mounted and ready
    Future.delayed(const Duration(milliseconds: 200), () {
      navigatorKey.currentState?.pushNamed(
        '/assignment-offer',
        arguments: data['orderId'],
      );
    });
  }
}

// 2. Replace your existing _initFirebaseMessaging with this updated version
Future<void> _initFirebaseMessaging() async {
  // Request permissions
  await FirebaseMessaging.instance.requestPermission(
    alert: true,
    badge: true,
    sound: true,
    provisional: false,
  );

  // Configure options for iOS foreground presentation
  await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
    alert: true,
    badge: true,
    sound: true,
  );

  // --- CRITICAL FIX FOR KILLED APPS ---
  // Check if the app was opened from a terminated state by a notification
  final RemoteMessage? initialMessage = await FirebaseMessaging.instance.getInitialMessage();
  if (initialMessage != null) {
    _handleMessage(initialMessage);
  }

  // --- HANDLE BACKGROUND TAPS ---
  // Listen for when the app is opened from the background
  FirebaseMessaging.onMessageOpenedApp.listen(_handleMessage);

  // --- HANDLE FOREGROUND MESSAGES ---
  // When the app is already open, show a local notification banner
  FirebaseMessaging.onMessage.listen((message) async {
    final data = message.data;

    if (data['type'] == 'assignment_request' && data['orderId'] != null) {
      final orderId = data['orderId'] as String;

      await _flnp.show(
        orderId.hashCode,
        message.notification?.title ?? 'New delivery offer',
        message.notification?.body ?? 'Tap to review and accept within 2 minutes',
        NotificationDetails(
          android: AndroidNotificationDetails(
            _assignChannel.id,
            _assignChannel.name,
            channelDescription: _assignChannel.description,
            importance: Importance.max, // Maximum importance for heads-up display
            priority: Priority.high,
            // Ensure this sound file exists in android/app/src/main/res/raw/
            sound: const RawResourceAndroidNotificationSound('new_order'),
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
            sound: 'new_order.aiff', // Ensure this file is in your iOS assets
          ),
        ),
        payload: orderId,
      );
    }
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase in the main/UI isolate (race-safe)
  await ensureFirebaseInitialized();

  // Register the background handler before using messaging features
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  // Capture initial message before runApp so it can be handled after first frame
  final initialMessageFuture = FirebaseMessaging.instance.getInitialMessage();

  // Render the first frame immediately
  runApp(
    ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: const SpeedDeliveryApp(),
    ),
  );

  // Do the heavy setup right after first frame
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    await _initLocalNotifications();
    await _initFirebaseMessaging();

    // Handle app launched from terminated by tapping the FCM
    final initial = await initialMessageFuture;
    if (initial != null) {
      final data = initial.data;
      if (data['type'] == 'assignment_request' && data['orderId'] != null) {
        navigatorKey.currentState?.pushNamed(
          '/assignment-offer',
          arguments: data['orderId'],
        );
      }
    }
  });
}

class SpeedDeliveryApp extends StatelessWidget {
  const SpeedDeliveryApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'SpeedDelivery Driver',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeProvider.themeMode,
      debugShowCheckedModeBanner: false,
      home: const AuthGate(),
      routes: {
        '/home': (_) => const HomeScreen(),
        '/earnings': (_) => const EarningsScreen(),
        '/profile': (_) => const ProfileScreen(),
        '/history': (_) => const DeliveryHistoryScreen(),
      },
    );
  }
}


class MainNavigation extends StatefulWidget {
  const MainNavigation({super.key});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _currentIndex = 0;

  final List<Widget> _screens = const [
    HomeScreen(),
    EarningsScreen(),
    ProfileScreen(),
    DeliveryHistoryScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(child: _screens[_currentIndex]),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        selectedItemColor: AppTheme.primaryColor,
        unselectedItemColor: Colors.grey,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(
            icon: Icon(Icons.attach_money),
            label: 'Earnings',
          ),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
        ],
      ),
    );
  }
}
