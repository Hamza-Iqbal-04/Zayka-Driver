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

  Future<DocumentSnapshot?> _fetchRiderProfile() async {
    final email = FirebaseAuth.instance.currentUser?.email;
    if (email == null) return null;

    final snapshot = await FirebaseFirestore.instance
        .collection('Drivers') // Collection name is correct
        .where('email', isEqualTo: email)
        .limit(1)
        .get();

    return snapshot.docs.isNotEmpty ? snapshot.docs.first : null;
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final theme = Theme.of(context);
    const accentColor = Colors.blue; // Or AppTheme.accentColor if you have one
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: FutureBuilder<DocumentSnapshot?>(
        future: _riderProfileFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || !snapshot.data!.exists) {
            return Center(
              child: Text(
                "Driver profile not found.",
                style: TextStyle(color: theme.colorScheme.onBackground),
              ),
            );
          }

          final data = snapshot.data!.data() as Map<String, dynamic>;
          final name = data['name'] ?? "No Name";
          final email = data['email'] ?? "no.email@example.com";
          // Fetch the profile image URL
          final String? profileImageUrl = data['profileImageUrl'] as String?;

          // Safely access nested vehicle data
          final Map<String, dynamic>? vehicleData = data['vehicle'] as Map<String, dynamic>?;
          final String vehicleType = vehicleData?['type'] ?? 'N/A';
          final String vehicleNumber = vehicleData?['number'] ?? 'N/A';


          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 24.0),
            children: [
              // Pass profileImageUrl to _buildHeader
              _buildHeader(name, email, profileImageUrl, theme),
              const SizedBox(height: 20),
              _buildSectionHeader("Account Information", accentColor, theme),
              _buildSettingsList(theme.cardColor, [
                _buildInfoItem(
                  icon: Icons.star_border,
                  title: "Rating",
                  value: (data['rating'] ?? '0.0').toString(),
                  theme: theme,
                ),
                _buildInfoItem(
                  icon: Icons.phone_outlined,
                  title: "Phone",
                  value: (data['phone'] ?? 'N/A').toString(), // Ensure phone is treated as string
                  theme: theme,
                ),
                _buildInfoItem(
                  icon: Icons.drive_eta_outlined,
                  title: "Vehicle",
                  value: vehicleType, // Correctly access nested field
                  theme: theme,
                ),
                _buildInfoItem(
                  icon: Icons.pin_outlined,
                  title: "License Plate",
                  value: vehicleNumber, // Correctly access nested field
                  theme: theme,
                ),
              ]),
              _buildSectionHeader("Notifications", accentColor, theme),
              _buildSettingsList(theme.cardColor, [
                _buildToggleItem(
                  icon: Icons.assignment_turned_in_outlined,
                  title: "New Delivery Assignments",
                  value: true, // Replace with actual value from data if available
                  onChanged: (val) {},
                  theme: theme,
                ),
                _buildToggleItem(
                  icon: Icons.track_changes_outlined,
                  title: "Status Updates",
                  value: true, // Replace with actual value from data if available
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
                    icon: Icons.battery_alert_outlined, // Use a relevant icon
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
                      // Optionally navigate to login screen or update UI
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

  Widget _buildHeader(String name, String email, String? profileImageUrl, ThemeData theme) {
    // Determine the child for CircleAvatar based on profileImageUrl
    Widget avatarChild;
    if (profileImageUrl != null && profileImageUrl.isNotEmpty) {
      // Using CachedNetworkImage (add dependency: cached_network_image)
      // This provides caching and better loading/error states.
      avatarChild = ClipOval(
        child: CachedNetworkImage(
          imageUrl: profileImageUrl,
          placeholder: (context, url) => const SizedBox(
            width: 30, // Smaller indicator inside the avatar space
            height: 30,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          errorWidget: (context, url, error) {
            print('Error loading profile image with CachedNetworkImage: $error');
            return _buildInitialsAvatar(name); // Fallback to initials
          },
          fit: BoxFit.cover,
          width: 60,
          height: 60,
        ),
      );

    } else {
      // Fallback to initials if no profileImageUrl
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
                    ? Colors.transparent // Transparent if image is shown
                    : Colors.blue.shade700, // Background color for initials
                child: avatarChild,
              ),
              const SizedBox(width: 16),
              Expanded( // Use Expanded to prevent overflow for long names/emails
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
              // If EditProfileScreen pops with true, it means data was saved, so refresh.
              if (result == true) {
                setState(() {
                  _riderProfileFuture = _fetchRiderProfile(); // Re-fetch data
                });
              }
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  "Edit Profile", // Or "Edit Profile"
                  style: TextStyle(
                    color: Colors.red[400], // Or theme.colorScheme.primary
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.arrow_forward_ios,
                  size: 14,
                  color: Colors.red[400], // Or theme.colorScheme.primary
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Helper widget for initials fallback
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
          Text(
            title,
            style: theme.textTheme.titleMedium,
          ),
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
            height: 1,
            indent: 16,
            endIndent: 16,
            color: Colors.black26, // Consider using theme.dividerColor
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
      title: Text(
        title,
        style: TextStyle(color: color, fontWeight: FontWeight.w500),
      ),
      trailing: isDestructive
          ? null
          : Icon(
        Icons.arrow_forward_ios,
        size: 16,
        color: theme.colorScheme.secondary,
      ),
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
      title: Text(
        title,
        style: TextStyle(
          color: theme.colorScheme.onBackground,
          fontWeight: FontWeight.w500,
        ),
      ),
      trailing: Text(
        value,
        style: TextStyle(
          color: theme.colorScheme.secondary,
          fontSize: 14,
        ),
      ),
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
      title: Text(
        title,
        style: TextStyle(
          color: theme.colorScheme.onBackground,
          fontWeight: FontWeight.w500,
        ),
      ),
      trailing: Switch(
        value: value,
        onChanged: onChanged,
        activeColor: AppTheme.primaryColor, // Ensure AppTheme.primaryColor is defined
      ),
    );
  }
}