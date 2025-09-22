import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../theme/app_theme.dart'; // Make sure this path is correct
import '../widgets/delivery_card.dart'; // Make sure this path is correct
import '../utils/string_extensions.dart'; // Make sure this path is correct

class DeliveryHistoryScreen extends StatefulWidget {
  const DeliveryHistoryScreen({super.key});
  @override
  State createState() => _DeliveryHistoryScreenState();
}

class _DeliveryHistoryScreenState extends State<DeliveryHistoryScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  String? _currentRiderIdentifier;
  String? _errorMessage;
  String selectedStatus = 'All'; // Default to 'All'
  String searchQuery = '';
  DateTimeRange? selectedRange;

  // Pagination related variables
  final ScrollController _scrollController = ScrollController();
  List<Map<String, dynamic>> _allRawDeliveries = []; // Stores all fetched raw data for client-side filtering
  List<Map<String, dynamic>> _filteredAndProcessedDeliveries = []; // Stores data after client-side filtering and processing
  DocumentSnapshot? _lastDocument; // Last document from the previous Firestore fetch
  bool _hasMore = true; // True if there are more documents in Firestore beyond _lastDocument
  bool _isFetchingMore = false; // To prevent multiple simultaneous pagination fetches
  bool _isLoadingInitial = true; // For initial full-screen loading
  final int _pageSize = 3; // Fetch and show 3 orders at a time

  @override
  void initState() {
    super.initState();
    _loadCurrentRiderInfo();
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
      if (_hasMore && !_isFetchingMore) {
        _fetchDeliveries(isInitialLoad: false);
      }
    }
  }

  Future<void> _loadCurrentRiderInfo() async {
    User? currentUser = _auth.currentUser;
    if (currentUser != null) {
      setState(() {
        _currentRiderIdentifier = currentUser.email;
      });
      // After getting rider ID, fetch initial data
      _fetchDeliveries(isInitialLoad: true);
    } else {
      setState(() {
        _isLoadingInitial = false;
        // Optionally show an error or redirect if rider not logged in
      });
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

  void _pickDateRange() async {
    final today = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime(today.year + 1),
      initialDateRange: selectedRange ?? DateTimeRange(start: today.subtract(const Duration(days: 7)), end: today),
    );
    if (picked != null) {
      setState(() {
        selectedRange = picked;
        _clearAndFetchNewData(); // Refresh data with new date range
      });
    }
  }

  void _clearFilters() {
    setState(() {
      selectedStatus = 'All';
      searchQuery = '';
      selectedRange = null;
      _clearAndFetchNewData(); // Refresh data after clearing filters
    });
  }

  void _clearAndFetchNewData() {
    _allRawDeliveries.clear();
    _filteredAndProcessedDeliveries.clear();
    _lastDocument = null;
    _hasMore = true;
    _isFetchingMore = false;
    _isLoadingInitial = true; // Show loading for new data fetch
    _fetchDeliveries(isInitialLoad: true);
  }

  // Helper to get the most relevant date for a history item (delivered, cancelled, or placed)
  DateTime? _getRelevantDateTime(Map<String, dynamic> orderData) {
    final Timestamp? deliveredTimestamp = orderData['timestamps']?['delivered'] as Timestamp?;
    final Timestamp? cancelledTimestamp = orderData['timestamps']?['cancelledAt'] as Timestamp?;
    final Timestamp? placedTimestamp = orderData['timestamps']?['placed'] as Timestamp?;
    final String currentStatus = orderData['status']?.toLowerCase() ?? 'unknown';

    if (currentStatus == 'delivered' && deliveredTimestamp != null) {
      return deliveredTimestamp.toDate();
    } else if (currentStatus == 'cancelled' && cancelledTimestamp != null) {
      return cancelledTimestamp.toDate();
    }
    return placedTimestamp?.toDate(); // Fallback to placed date
  }

  // Helper to format the label based on status
  String _getEventLabel(String status) {
    switch (status.toLowerCase()) {
      case 'delivered':
        return "Delivered";
      case 'cancelled':
        return "Cancelled";
      default:
        return "Placed";
    }
  }

  // Helper to check if two DateTimes are on the same day
  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  Future<void> _fetchDeliveries({required bool isInitialLoad}) async {
    if (_currentRiderIdentifier == null || (_isFetchingMore && !isInitialLoad)) {
      return;
    }

    setState(() {
      if (isInitialLoad) {
        _isLoadingInitial = true;
      } else {
        _isFetchingMore = true;
      }
    });

    try {
      Query query = _firestore
          .collection('Orders')
          .where('riderId', isEqualTo: _currentRiderIdentifier);

      // --- Server-side STATUS filter ---
      if (selectedStatus == 'Delivered') {
        query = query.where('status', isEqualTo: 'delivered');
      } else if (selectedStatus == 'Cancelled') {
        query = query.where('status', isEqualTo: 'cancelled');
      } else {
        query = query.where('status', whereIn: ['delivered', 'cancelled']);
      }

      // --- Server-side DATE filter (on 'timestamps.placed') ---
      if (selectedRange != null) {
        final serverQueryStart = selectedRange!.start;
        final serverQueryEnd = DateTime(selectedRange!.end.year, selectedRange!.end.month, selectedRange!.end.day, 23, 59, 59);
        query = query
            .where('timestamps.delivered', isGreaterThanOrEqualTo: Timestamp.fromDate(serverQueryStart))
            .where('timestamps.delivered', isLessThanOrEqualTo: Timestamp.fromDate(serverQueryEnd));
      }

      // Order by placed timestamp for consistent pagination
      query = query.orderBy('timestamps.delivered', descending: true);

      // Apply pagination logic
      if (!isInitialLoad && _lastDocument != null) {
        query = query.startAfterDocument(_lastDocument!);
      }

      query = query.limit(_pageSize);
      final QuerySnapshot snapshot = await query.get();

      final newRawDeliveries = snapshot.docs.map((doc) => {
        ...doc.data() as Map<String, dynamic>,
        'docId': doc.id,
      }).toList();

      if (snapshot.docs.isEmpty) {
        _hasMore = false;
        _lastDocument = null;
      } else {
        _lastDocument = snapshot.docs.last;
        _hasMore = snapshot.docs.length == _pageSize;
      }

      setState(() {
        if (isInitialLoad) {
          _allRawDeliveries = newRawDeliveries;
        } else {
          _allRawDeliveries.addAll(newRawDeliveries);
        }
        _applyClientSideFiltersAndProcess(); // Apply client-side filters and prepare for display
      });
    } catch (e) {
      setState(() {
        _errorMessage = "Failed to load deliveries: $e";
      });
    } finally {
      setState(() {
        _isLoadingInitial = false;
        _isFetchingMore = false;
      });
    }
  }

  // Applies client-side filters (search, precise date range) and sorts data
  void _applyClientSideFiltersAndProcess() {
    List<Map<String, dynamic>> tempFiltered = List.from(_allRawDeliveries);

    // --- CLIENT-SIDE DATE RANGE FILTERING (applied to the event date) ---
    if (selectedRange != null) {
      final rangeStart = DateTime(selectedRange!.start.year, selectedRange!.start.month, selectedRange!.start.day);
      final rangeEnd = DateTime(selectedRange!.end.year, selectedRange!.end.month, selectedRange!.end.day, 23, 59, 59);
      tempFiltered = tempFiltered.where((orderData) {
        final DateTime? eventDate = _getRelevantDateTime(orderData);
        if (eventDate == null) return false;
        final normalizedEventDate = DateTime(eventDate.year, eventDate.month, eventDate.day);
        return !normalizedEventDate.isBefore(rangeStart) && normalizedEventDate.isBefore(rangeEnd.add(const Duration(days: 1)));
      }).toList();
    }

    // --- CLIENT-SIDE SEARCH FILTERING ---
    if (searchQuery.isNotEmpty) {
      final searchLower = searchQuery.toLowerCase();
      tempFiltered = tempFiltered.where((orderData) {
        final name = orderData['customerName']?.toLowerCase() ?? '';
        final orderId = (orderData['orderId'] as String?)?.toLowerCase() ?? (orderData['docId'] as String?)?.toLowerCase() ?? '';
        final dailyNumber = orderData['dailyOrderNumber']?.toString().toLowerCase() ?? '';
        return name.contains(searchLower) || orderId.contains(searchLower) || dailyNumber.contains(searchLower);
      }).toList();
    }

    // Sort the final client-filtered list by event time descending
    tempFiltered.sort((aData, bData) {
      final DateTime? aTime = _getRelevantDateTime(aData);
      final DateTime? bTime = _getRelevantDateTime(bData);
      if (aTime == null && bTime == null) return 0;
      if (aTime == null) return 1; // Put nulls at the end
      if (bTime == null) return -1;
      return bTime.compareTo(aTime); // Newest time first
    });

    setState(() {
      _filteredAndProcessedDeliveries = tempFiltered;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_currentRiderIdentifier == null || _isLoadingInitial) {
      return Scaffold(
        appBar: AppBar(title: const Text("Delivery History")),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text("Delivery History"),
        backgroundColor: Theme.of(context).appBarTheme.backgroundColor,
      ),
      body: Column(
        children: [
          // --- FILTER WIDGETS ---
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              onChanged: (val) {
                setState(() => searchQuery = val.trim());
                _applyClientSideFiltersAndProcess(); // Re-apply client-side filters on search change
              },
              decoration: InputDecoration(
                hintText: "Search by name or order ID",
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Theme.of(context).cardColor,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: selectedStatus,
                    items: const [
                      DropdownMenuItem(value: 'All', child: Text("All History")),
                      DropdownMenuItem(value: 'Delivered', child: Text("Delivered")),
                      DropdownMenuItem(value: 'Cancelled', child: Text("Cancelled")),
                    ],
                    onChanged: (val) {
                      setState(() => selectedStatus = val!);
                      _clearAndFetchNewData(); // Fetch new data for server-side status filter
                    },
                    decoration: InputDecoration(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _pickDateRange,
                    icon: const Icon(Icons.calendar_today, size: 16),
                    label: Text(selectedRange == null
                        ? "Date Range"
                        : "${DateFormat.yMMMd().format(selectedRange!.start)} - ${DateFormat.yMMMd().format(selectedRange!.end)}"),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                IconButton(onPressed: _clearFilters, tooltip: "Clear filters", icon: const Icon(Icons.clear)),
              ],
            ),
          ),
          // --- DELIVERY LIST ---
          Expanded(
            child: _errorMessage != null
                ? Center(child: Text(_errorMessage!))
                : _filteredAndProcessedDeliveries.isEmpty && !_isFetchingMore // Show empty message only if no data and not actively fetching
                ? const Center(child: Text("No deliveries found matching your filters."))
                : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      "Displaying: ${_filteredAndProcessedDeliveries.length} deliveries",
                      style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    itemCount: _filteredAndProcessedDeliveries.length + (_isFetchingMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == _filteredAndProcessedDeliveries.length) {
                        return const Padding(
                          padding: EdgeInsets.all(8.0),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }

                      final Map<String, dynamic> orderData = _filteredAndProcessedDeliveries[index];
                      final DateTime? currentEventDateTime = _getRelevantDateTime(orderData);

                      // Determine if a date header should be shown
                      bool showDateHeader = false;
                      if (currentEventDateTime != null) {
                        if (index == 0) {
                          showDateHeader = true; // Always show for the first item
                        } else {
                          final Map<String, dynamic> prevOrderData = _filteredAndProcessedDeliveries[index - 1];
                          final DateTime? prevEventDateTime = _getRelevantDateTime(prevOrderData);
                          if (prevEventDateTime != null && !_isSameDay(currentEventDateTime, prevEventDateTime)) {
                            showDateHeader = true; // Show if the day changes
                          }
                        }
                      }

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (showDateHeader && currentEventDateTime != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 16.0, bottom: 8.0),
                              child: Text(
                                DateFormat.yMMMMd().format(currentEventDateTime),
                                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4.0, left: 2.0),
                            child: Text(
                              "${_getEventLabel(orderData['status']?.toLowerCase() ?? 'unknown')} at ${currentEventDateTime != null ? DateFormat.jm().format(currentEventDateTime) : 'Time N/A'}",
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade700, fontWeight: FontWeight.w500),
                            ),
                          ),
                          DeliveryCard(
                            orderId: orderData['dailyOrderNumber']?.toString() ?? 'N/A', // Updated: Display dailyOrderNumber (converted to string)
                            orderData: {
                              'customerName': orderData['customerName'] ?? 'Unknown Customer',
                              'deliveryAddress': orderData['deliveryAddress'],
                              'status': (orderData['status'] as String?)?.capitalize() ?? 'Unknown',
                            },
                            statusColor: _getStatusColor(orderData['status']?.toLowerCase() ?? 'unknown'),
                            onAccept: null,
                            onUpdateStatus: null,
                            actionButtonText: null,
                            nextStatus: null,
                            onCardTap: () => print("Tapped on order: ${orderData['orderId'] ?? orderData['docId'] ?? 'ID N/A'}"),
                          ),
                          if (index < _filteredAndProcessedDeliveries.length - 1)
                            const SizedBox(height: 12), // Separator between cards, not after last one
                        ],
                      );
                    },
                  ),
                ),
                if (!_hasMore && _filteredAndProcessedDeliveries.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.all(8.0),
                    child: Center(child: Text('No more deliveries.')),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

