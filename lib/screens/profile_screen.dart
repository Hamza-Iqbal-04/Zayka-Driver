import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:myapp/screens/edit_profile_screen.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../theme/app_theme.dart';
import '../theme/theme_provider.dart';
import 'delivery_history_screen.dart';
import 'package:permission_handler/permission_handler.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late Future<DocumentSnapshot?> _riderProfileFuture;

  @override
  void initState() {
    super.initState();
    _riderProfileFuture = _fetchRiderProfile();
  }

  // FIX: Fetch directly by Document ID (which is the email)
  Future<DocumentSnapshot?> _fetchRiderProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.email == null) return null;

    final email = user.email!;
    print("Fetching profile for Doc ID: $email"); // Debug print

    try {
      // Since the Document ID is the email, we access it directly.
      // This is faster and avoids issues where the 'email' field inside
      // the document might have different capitalization (e.g. John@ vs john@).
      final docSnapshot = await FirebaseFirestore.instance
          .collection('Drivers')
          .doc(email)
          .get();

      if (docSnapshot.exists) {
        return docSnapshot;
      } else {
        print("Document for $email does not exist in Drivers collection.");
      }
    } catch (e) {
      debugPrint("Error fetching profile: $e");
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final theme = Theme.of(context);
    const accentColor = Colors.blue;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: FutureBuilder<DocumentSnapshot?>(
        future: _riderProfileFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(child: Text("Error: ${snapshot.error}"));
          }

          if (!snapshot.hasData || !snapshot.data!.exists) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  "Driver profile not found.\nLogged in as: ${FirebaseAuth.instance.currentUser?.email}",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.onBackground),
                ),
              ),
            );
          }

          final data = snapshot.data!.data() as Map<String, dynamic>;

          // Data Parsing
          final name = data['name'] ?? "No Name";
          final email = data['email'] ?? "no.email@example.com";
          final String? profileImageUrl = data['profileImageUrl'] as String?;

          // Parsing Phone (Handle Number or String)
          final String phone = (data['phone'] ?? 'N/A').toString();
          final String rating = (data['rating'] ?? '0.0').toString();

          // FIX: Parsing Vehicle (Handle Nested Map safely)
          // Based on your JSON: vehicle is a Map {number: "...", type: "..."}
          String vehicleType = 'N/A';
          String vehicleNumber = 'N/A';

          if (data['vehicle'] is Map) {
            final vMap = data['vehicle'] as Map<String, dynamic>;
            vehicleType = vMap['type'] ?? 'N/A';
            vehicleNumber = vMap['number'] ?? 'N/A';
          }

          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 24.0),
            children: [
              _buildHeader(name, email, profileImageUrl, theme),
              const SizedBox(height: 20),

              _buildSectionHeader("Account Information", accentColor, theme),
              _buildSettingsList(theme.cardColor, [
                _buildInfoItem(
                  icon: Icons.star_border,
                  title: "Rating",
                  value: rating,
                  theme: theme,
                ),
                _buildInfoItem(
                  icon: Icons.phone_outlined,
                  title: "Phone",
                  value: phone,
                  theme: theme,
                ),
                _buildInfoItem(
                  icon: Icons.drive_eta_outlined,
                  title: "Vehicle",
                  value: vehicleType,
                  theme: theme,
                ),
                _buildInfoItem(
                  icon: Icons.pin_outlined,
                  title: "License Plate",
                  value: vehicleNumber,
                  theme: theme,
                ),
              ]),

              _buildSectionHeader("Notifications", accentColor, theme),
              _buildSettingsList(theme.cardColor, [
                _buildToggleItem(
                  icon: Icons.assignment_turned_in_outlined,
                  title: "New Delivery Assignments",
                  value: true,
                  onChanged: (val) {},
                  theme: theme,
                ),
                _buildToggleItem(
                  icon: Icons.track_changes_outlined,
                  title: "Status Updates",
                  value: true,
                  onChanged: (val) {},
                  theme: theme,
                ),
              ]),

              _buildSectionHeader("More", accentColor, theme),
              _buildSettingsList(
                theme.cardColor,
                [
                  _buildSettingsItem(
                    icon: Icons.history,
                    title: "Delivery History",
                    theme: theme,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const DeliveryHistoryScreen(),
                        ),
                      );
                    },
                  ),
                  _buildSettingsItem(
                    icon: Icons.feedback_outlined,
                    title: "Send feedback",
                    theme: theme,
                    onTap: () {},
                  ),
                  _buildSettingsItem(
                    icon: Icons.battery_alert_outlined,
                    title: "Ignore Battery Optimization",
                    theme: theme,
                    onTap: () async {
                      await Permission.ignoreBatteryOptimizations.request();
                    },
                  ),
                  _buildToggleItem(
                    icon: Icons.brightness_6_outlined,
                    title: "Dark Mode",
                    value: themeProvider.isDarkMode,
                    onChanged: (val) => themeProvider.toggleTheme(val),
                    theme: theme,
                  ),
                  _buildSettingsItem(
                    icon: Icons.logout,
                    title: "Log out",
                    theme: theme,
                    isDestructive: true,
                    onTap: () async {
                      await FirebaseAuth.instance.signOut();
                    },
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  // --- Widgets ---

  Widget _buildHeader(String name, String email, String? profileImageUrl, ThemeData theme) {
    Widget avatarChild;
    if (profileImageUrl != null && profileImageUrl.isNotEmpty) {
      avatarChild = ClipOval(
        child: CachedNetworkImage(
          imageUrl: profileImageUrl,
          placeholder: (context, url) => const SizedBox(
            width: 30, height: 30,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          errorWidget: (context, url, error) => _buildInitialsAvatar(name),
          fit: BoxFit.cover,
          width: 60,
          height: 60,
        ),
      );
    } else {
      avatarChild = _buildInitialsAvatar(name);
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.withOpacity(0.2), width: 1),
      ),
      child: Column(
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 30,
                backgroundColor: profileImageUrl != null && profileImageUrl.isNotEmpty
                    ? Colors.transparent
                    : Colors.blue.shade700,
                child: avatarChild,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        color: theme.colorScheme.onBackground,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      email,
                      style: TextStyle(
                        color: theme.colorScheme.secondary,
                        fontSize: 14,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          TextButton(
            onPressed: () async {
              final result = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => const EditProfileScreen(),
                ),
              );
              if (result == true) {
                setState(() {
                  _riderProfileFuture = _fetchRiderProfile();
                });
              }
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "Edit Profile",
                  style: TextStyle(
                    color: Colors.red[400],
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.arrow_forward_ios, size: 14, color: Colors.red[400]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInitialsAvatar(String name) {
    return Text(
      name.isNotEmpty ? name[0].toUpperCase() : 'U',
      style: const TextStyle(
        color: Colors.white,
        fontSize: 28,
        fontWeight: FontWeight.bold,
      ),
    );
  }

  Widget _buildSectionHeader(String title, Color accentColor, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(left: 8.0, bottom: 8.0, top: 16.0),
      child: Row(
        children: [
          Container(width: 4, height: 20, color: accentColor),
          const SizedBox(width: 8),
          Text(title, style: theme.textTheme.titleMedium),
        ],
      ),
    );
  }

  Widget _buildSettingsList(Color cardColor, List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.withOpacity(0.2), width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ListView.separated(
          physics: const NeverScrollableScrollPhysics(),
          shrinkWrap: true,
          itemCount: children.length,
          itemBuilder: (context, index) => children[index],
          separatorBuilder: (context, index) => const Divider(
            height: 1, indent: 16, endIndent: 16, color: Colors.black26,
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsItem({
    required IconData icon,
    required String title,
    required ThemeData theme,
    VoidCallback? onTap,
    bool isDestructive = false,
  }) {
    final color = isDestructive ? Colors.red : theme.colorScheme.onBackground;
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: theme.colorScheme.secondary),
      title: Text(title, style: TextStyle(color: color, fontWeight: FontWeight.w500)),
      trailing: isDestructive ? null : Icon(Icons.arrow_forward_ios, size: 16, color: theme.colorScheme.secondary),
    );
  }

  Widget _buildInfoItem({
    required IconData icon,
    required String title,
    required String value,
    required ThemeData theme,
  }) {
    return ListTile(
      leading: Icon(icon, color: theme.colorScheme.secondary),
      title: Text(title, style: TextStyle(color: theme.colorScheme.onBackground, fontWeight: FontWeight.w500)),
      trailing: Text(value, style: TextStyle(color: theme.colorScheme.secondary, fontSize: 14)),
    );
  }

  Widget _buildToggleItem({
    required IconData icon,
    required String title,
    required bool value,
    required Function(bool) onChanged,
    required ThemeData theme,
  }) {
    return ListTile(
      onTap: () => onChanged(!value),
      leading: Icon(icon, color: theme.colorScheme.secondary),
      title: Text(title, style: TextStyle(color: theme.colorScheme.onBackground, fontWeight: FontWeight.w500)),
      trailing: Switch(value: value, onChanged: onChanged, activeColor: AppTheme.primaryColor),
    );
  }
}