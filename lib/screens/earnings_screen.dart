import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../theme/app_theme.dart';

class EarningsScreen extends StatefulWidget {
  const EarningsScreen({super.key});

  @override
  State<EarningsScreen> createState() => _EarningsScreenState();
}

class _EarningsScreenState extends State<EarningsScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  String? _riderEmail;
  bool _isLoading = true;
  String? _errorMessage;

  // Earnings Summary data
  double _todayEarnings = 0.0;
  int _todayDeliveries = 0;
  double _weekEarnings = 0.0;
  int _weekDeliveries = 0;

  // Weekly Performance Chart data
  List<double> _weeklyHeights = List.filled(7, 0.0);
  final List<String> _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  // Recent Transactions data for pagination
  List<Map<String, dynamic>> _recentTransactions = [];
  final ScrollController _scrollController = ScrollController();
  DocumentSnapshot? _lastDocument; // Last document from the previous fetch
  bool _hasMoreTransactions = true; // True if there are more transactions to load
  bool _isFetchingMoreTransactions = false; // To prevent multiple simultaneous fetches
  final int _transactionsPageSize = 10; // Number of transactions to fetch per page

  @override
  void initState() {
    super.initState();
    _loadRiderAndFetchData();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels == _scrollController.position.maxScrollExtent) {
      // User has scrolled to the end
      if (_hasMoreTransactions && !_isFetchingMoreTransactions) {
        _fetchMoreTransactions();
      }
    }
  }

  Future<void> _loadRiderAndFetchData() async {
    User? currentUser = _auth.currentUser;
    if (currentUser != null && currentUser.email != null) {
      _riderEmail = currentUser.email;
      await _fetchSummaryAndWeeklyData(); // Fetch summary and weekly data first
      await _fetchFirstPageTransactions(); // Then fetch the first page of transactions
    } else {
      setState(() {
        _isLoading = false;
        _errorMessage = "Rider not logged in.";
      });
    }
  }

  Future<void> _fetchSummaryAndWeeklyData() async {
    if (_riderEmail == null) return;

    setState(() {
      _isLoading = true; // Show loading for initial fetch
      _errorMessage = null;
    });

    try {
      DateTime now = DateTime.now();
      DateTime todayStart = DateTime(now.year, now.month, now.day);
      DateTime todayEnd = DateTime(now.year, now.month, now.day, 23, 59, 59);

      int currentDayOfWeek = now.weekday;
      DateTime startOfWeek = todayStart.subtract(Duration(days: currentDayOfWeek - 1));
      DateTime endOfWeek = startOfWeek.add(const Duration(days: 6, hours: 23, minutes: 59, seconds: 59));

      final QuerySnapshot deliveredOrdersSnapshot = await _firestore
          .collection('Orders')
          .where('riderId', isEqualTo: _riderEmail)
          .where('status', isEqualTo: 'delivered')
      // No limit here as we need all for aggregation within the week
          .get();

      double tempTodayEarnings = 0.0;
      int tempTodayDeliveries = 0;
      double tempWeekEarnings = 0.0;
      int tempWeekDeliveries = 0;
      List<double> tempWeeklyHeights = List.filled(7, 0.0);

      for (var doc in deliveredOrdersSnapshot.docs) {
        final orderData = doc.data() as Map<String, dynamic>;
        final double payment = (orderData['riderPaymentAmount'] as num?)?.toDouble() ?? 0.0;
        final Timestamp? deliveredTimestamp = orderData['timestamps']?['delivered'] as Timestamp?;
        final DateTime? deliveredDate = deliveredTimestamp?.toDate();

        if (deliveredDate != null) {
          if (deliveredDate.isAfter(todayStart) && deliveredDate.isBefore(todayEnd)) {
            tempTodayEarnings += payment;
            tempTodayDeliveries++;
          }

          if (deliveredDate.isAfter(startOfWeek.subtract(const Duration(seconds: 1))) && deliveredDate.isBefore(endOfWeek.add(const Duration(seconds: 1)))) {
            tempWeekEarnings += payment;
            tempWeekDeliveries++;
            int dayIndex = deliveredDate.weekday - 1;
            tempWeeklyHeights[dayIndex] += payment;
          }
        }
      }

      double maxWeeklyEarnings = tempWeeklyHeights.reduce((a, b) => a > b ? a : b);
      if (maxWeeklyEarnings > 0) {
        _weeklyHeights = tempWeeklyHeights.map((e) => (e / maxWeeklyEarnings) * 90).toList();
      } else {
        _weeklyHeights = List.filled(7, 0.0);
      }

      setState(() {
        _todayEarnings = tempTodayEarnings;
        _todayDeliveries = tempTodayDeliveries;
        _weekEarnings = tempWeekEarnings;
        _weekDeliveries = tempWeekDeliveries;
      });
    } catch (e) {
      print("Error fetching summary and weekly data: $e");
      setState(() {
        _errorMessage = "Failed to load summary data: $e";
      });
    } finally {
      // Keep isLoading true until transactions are also fetched, or set false if only summary fails
      // For now, _fetchFirstPageTransactions will set isLoading to false finally.
    }
  }


  Future<void> _fetchFirstPageTransactions() async {
    if (_riderEmail == null) return;

    setState(() {
      _isLoading = true; // Keep loading for initial data
      _errorMessage = null;
    });

    try {
      Query query = _firestore
          .collection('Orders')
          .where('riderId', isEqualTo: _riderEmail)
          .where('status', isEqualTo: 'delivered')
          .orderBy('timestamps.delivered', descending: true)
          .limit(_transactionsPageSize);

      final QuerySnapshot firstPageSnapshot = await query.get();

      if (firstPageSnapshot.docs.isEmpty) {
        _hasMoreTransactions = false;
        _lastDocument = null;
      } else {
        _lastDocument = firstPageSnapshot.docs.last;
        _hasMoreTransactions = firstPageSnapshot.docs.length == _transactionsPageSize;
      }

      _recentTransactions = firstPageSnapshot.docs.map((doc) {
        final orderData = doc.data() as Map<String, dynamic>;
        final double payment = (orderData['riderPaymentAmount'] as num?)?.toDouble() ?? 0.0;
        final Timestamp? deliveredTimestamp = orderData['timestamps']?['delivered'] as Timestamp?;
        final DateTime? deliveredDate = deliveredTimestamp?.toDate();

        return {
          'time': deliveredDate,
          'order': '#${orderData['orderId'] ?? doc.id.substring(0, 7)} • ${orderData['customerName'] ?? 'Unknown'}',
          'amount': '+QR ${payment.toStringAsFixed(2)}',
        };
      }).toList();

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      print("Error fetching first page transactions: $e");
      setState(() {
        _isLoading = false;
        _errorMessage = "Failed to load transactions: $e";
      });
    }
  }

  Future<void> _fetchMoreTransactions() async {
    if (_riderEmail == null || !_hasMoreTransactions || _isFetchingMoreTransactions || _lastDocument == null) {
      return;
    }

    setState(() {
      _isFetchingMoreTransactions = true;
    });

    try {
      Query query = _firestore
          .collection('Orders')
          .where('riderId', isEqualTo: _riderEmail)
          .where('status', isEqualTo: 'delivered')
          .orderBy('timestamps.delivered', descending: true)
          .startAfterDocument(_lastDocument!)
          .limit(_transactionsPageSize);

      final QuerySnapshot nextPageSnapshot = await query.get();

      if (nextPageSnapshot.docs.isEmpty) {
        _hasMoreTransactions = false;
      } else {
        _lastDocument = nextPageSnapshot.docs.last;
        _hasMoreTransactions = nextPageSnapshot.docs.length == _transactionsPageSize;

        final newTransactions = nextPageSnapshot.docs.map((doc) {
          final orderData = doc.data() as Map<String, dynamic>;
          final double payment = (orderData['riderPaymentAmount'] as num?)?.toDouble() ?? 0.0;
          final Timestamp? deliveredTimestamp = orderData['timestamps']?['delivered'] as Timestamp?;
          final DateTime? deliveredDate = deliveredTimestamp?.toDate();

          return {
            'time': deliveredDate,
            'order': '#${orderData['orderId'] ?? doc.id.substring(0, 7)} • ${orderData['customerName'] ?? 'Unknown'}',
            'amount': '+QR ${payment.toStringAsFixed(2)}',
          };
        }).toList();

        setState(() {
          _recentTransactions.addAll(newTransactions);
        });
      }
    } catch (e) {
      print("Error fetching more transactions: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load more transactions: $e')),
      );
    } finally {
      setState(() {
        _isFetchingMoreTransactions = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _isLoading
        ? const Center(child: CircularProgressIndicator())
        : _errorMessage != null
        ? Center(child: Text(_errorMessage!))
        : ListView(
      controller: _scrollController, // Attach the scroll controller
      padding: const EdgeInsets.all(16),
      children: [
        // Earnings Summary
        Card(
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Earnings Summary',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    _earningsBox(
                      "Today",
                      "QR ${_todayEarnings.toStringAsFixed(2)}",
                      "${_todayDeliveries} deliveries",
                      bgColor: Colors.red.shade50,
                      color: AppTheme.primaryColor,
                    ),
                    const SizedBox(width: 16),
                    _earningsBox(
                      "This Week",
                      "QR ${_weekEarnings.toStringAsFixed(2)}",
                      "${_weekDeliveries} deliveries",
                      bgColor: Colors.green.shade50,
                      color: AppTheme.successColor,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),

        // Weekly Performance Chart
        Card(
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      "Weekly Performance",
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      "Week of ${DateFormat.MMMEd().format(DateTime.now().subtract(Duration(days: DateTime.now().weekday -1)))}", // Show start of current week
                      style: const TextStyle(color: AppTheme.primaryColor),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: List.generate(7, (index) {
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Container(
                          height: _weeklyHeights[index].clamp(5.0, 90.0), // Ensure min height for visibility
                          width: 16,
                          decoration: BoxDecoration(
                            color: AppTheme.primaryColor,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(_days[index], style: const TextStyle(fontSize: 12)),
                      ],
                    );
                  }),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),

        // Recent Transactions
        Card(
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Recent Transactions',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                if (_recentTransactions.isEmpty && !_isLoading && !_isFetchingMoreTransactions) // Only show if genuinely empty after load
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text('No recent transactions.'),
                    ),
                  )
                else
                  ..._recentTransactions.map((t) {
                    DateTime? transactionTime = t['time'] as DateTime?;

                    return Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  transactionTime != null
                                      ? DateFormat.yMMMd().add_jm().format(transactionTime)
                                      : 'N/A',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                Text(
                                  t['order'],
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              t['amount'],
                              style: const TextStyle(
                                color: AppTheme.successColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const Divider(height: 20),
                      ],
                    );
                  }).toList(),
                if (_isFetchingMoreTransactions)
                  const Padding(
                    padding: EdgeInsets.all(8.0),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (!_hasMoreTransactions && _recentTransactions.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.all(8.0),
                    child: Center(child: Text('No more transactions.')),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _earningsBox(
      String label,
      String amount,
      String subtext, {
        Color? bgColor,
        Color? color,
      }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: bgColor ?? Colors.grey.shade100,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Text(
              amount,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            Text(
              subtext,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}