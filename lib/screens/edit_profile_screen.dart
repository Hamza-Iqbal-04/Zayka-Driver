import 'dart:io'; // For File type
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart'; // For image upload
import 'package:image_picker/image_picker.dart'; // For picking images
import 'package:cached_network_image/cached_network_image.dart'; // For displaying network images
import 'package:provider/provider.dart'; // If you need themeProvider

import '../theme/app_theme.dart'; // Adjust path as needed
import '../theme/theme_provider.dart'; // Adjust path as needed


class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;

  // Text Editing Controllers for Name and Phone
  late TextEditingController _nameController;
  late TextEditingController _phoneController;

  String? _currentRiderDocumentId;
  Map<String, dynamic>? _currentRiderData;
  bool _isLoading = true;
  bool _isSaving = false;

  File? _imageFile; // For new profile image
  String? _currentProfileImageUrl; // To display current image

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _phoneController = TextEditingController();
    _loadRiderData();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _loadRiderData() async {
    setState(() => _isLoading = true);
    final email = _auth.currentUser?.email;
    if (email == null) {
      setState(() => _isLoading = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Error: Not logged in.")),
      );
      Navigator.of(context).pop();
      return;
    }

    try {
      final snapshot = await _firestore
          .collection('Drivers')
          .where('email', isEqualTo: email)
          .limit(1)
          .get();

      if (!mounted) return;
      if (snapshot.docs.isNotEmpty) {
        _currentRiderDocumentId = snapshot.docs.first.id;
        _currentRiderData = snapshot.docs.first.data();
        _nameController.text = _currentRiderData?['name'] ?? '';
        // FIX: Convert phone to String explicitly
        _phoneController.text = (_currentRiderData?['phone'] ?? '').toString();
        _currentProfileImageUrl = _currentRiderData?['profileImageUrl'];
        debugPrint("Loaded rider data: $_currentRiderData"); // ADDED PRINT
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Rider profile not found.")),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      debugPrint("Error loading rider data: $e");
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error loading data: ${e.toString()}")),
      );
      Navigator.of(context).pop();
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _pickImage() async {
    final ImagePicker picker = ImagePicker();
    final XFile? pickedFile = await picker.pickImage(source: ImageSource.gallery, imageQuality: 70);

    if (pickedFile != null) {
      setState(() {
        _imageFile = File(pickedFile.path);
      });
      debugPrint("Image picked from gallery: ${pickedFile.path}"); // ADDED PRINT
    } else {
      debugPrint("Image picking cancelled."); // ADDED PRINT
    }
  }

  Future<String?> _uploadImage(File imageFile) async {
    if (_auth.currentUser == null) {
      debugPrint("Upload failed: User not logged in."); // ADDED PRINT
      return null;
    }

    // Use current user's UID to make the path unique and associated with the user
    // Consider adding a unique timestamp or hash if multiple profile images per user are possible,
    // though typically one is overwritten.
    final String userId = _auth.currentUser!.uid;
    String fileName = 'profile_images/$userId.jpg'; // Simpler, user-specific filename
    // If you need a new file for every upload, keep the timestamp:
    // String fileName = 'profile_images/${userId}_${DateTime.now().millisecondsSinceEpoch}.jpg';


    debugPrint("Attempting to upload to Firebase Storage path: $fileName"); // ADDED PRINT

    try {
      Reference storageRef = _storage.ref().child(fileName);
      UploadTask uploadTask = storageRef.putFile(imageFile, SettableMetadata(contentType: 'image/jpeg'));

      // You can listen to the upload progress if needed
      uploadTask.snapshotEvents.listen((TaskSnapshot snapshot) {
        debugPrint('Upload progress: ${snapshot.bytesTransferred}/${snapshot.totalBytes}'); // ADDED PRINT
      });

      TaskSnapshot snapshot = await uploadTask;
      String downloadUrl = await snapshot.ref.getDownloadURL();
      debugPrint("Image uploaded successfully. Download URL: $downloadUrl"); // ADDED PRINT
      return downloadUrl;
    } catch (e) {
      debugPrint("Error uploading image: $e"); // Existing print
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Image upload failed: ${e.toString()}")),
      );
      return null;
    }
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) {
      debugPrint("Form validation failed."); // ADDED PRINT
      return;
    }
    if (_currentRiderDocumentId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Error: Rider profile not found.")),
      );
      debugPrint("Save failed: _currentRiderDocumentId is null."); // ADDED PRINT
      return;
    }

    setState(() => _isSaving = true);
    debugPrint("Starting profile save operation..."); // ADDED PRINT


    Map<String, dynamic> updatedData = {
      'name': _nameController.text.trim(),
      'phone': _phoneController.text.trim(),
    };

    String? newImageUrl;
    if (_imageFile != null) {
      debugPrint("New image selected, attempting upload."); // ADDED PRINT
      newImageUrl = await _uploadImage(_imageFile!);
      if (newImageUrl != null) {
        updatedData['profileImageUrl'] = newImageUrl;
        debugPrint("New image URL obtained: $newImageUrl"); // ADDED PRINT
      } else {
        debugPrint("Image upload failed, stopping profile save."); // ADDED PRINT
        setState(() => _isSaving = false);
        return; // Stop if image selected but upload failed
      }
    } else {
      debugPrint("No new image selected. Skipping image upload."); // ADDED PRINT
    }


    try {
      debugPrint("Updating Firestore document: Drivers/$_currentRiderDocumentId with data: $updatedData"); // ADDED PRINT
      await _firestore
          .collection('Drivers')
          .doc(_currentRiderDocumentId)
          .update(updatedData);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("Profile updated successfully!"),
            backgroundColor: Colors.green),
      );
      debugPrint("Profile updated successfully."); // ADDED PRINT
      Navigator.of(context).pop(true); // Pop and indicate success
    } catch (e) {
      debugPrint("Error updating profile: $e"); // Existing print
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error updating profile: ${e.toString()}")),
      );
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
        debugPrint("Profile save operation finished."); // ADDED PRINT
      }
    }
  }

  // A custom widget to replicate the input field style from the image
  Widget _buildStyledInputField({
    required TextEditingController controller,
    required String labelText,
    required ThemeData theme,
    String? Function(String?)? validator,
    TextInputType? keyboardType,
    bool readOnly = false,
  }) {
    // Determine fill color based on dark mode for the field background
    final Color fieldFillColor = Provider.of<ThemeProvider>(context).isDarkMode
        ? Colors.grey[800]! // Dark grey for dark mode
        : Colors.white; // White for light mode

    return Container(
      // The container acts as the visual box for the input field
      padding: const EdgeInsets.fromLTRB(16.0, 8.0, 8.0, 0.0), // Padding inside the box, less at bottom to snug up input
      decoration: BoxDecoration(
        color: fieldFillColor, // Use determined fill color
        borderRadius: BorderRadius.circular(10), // Rounded corners
        border: Border.all(color: Colors.grey.withOpacity(0.2), width: 1), // Subtle border
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min, // Keep column compact
        children: [
          // The label text, always visible at the top-left inside the box
          Text(
            labelText,
            style: TextStyle(
              color: theme.colorScheme.onSurface.withOpacity(0.7),
              fontSize: 12, // Smaller font for the label inside
            ),
          ),
          // The actual TextFormField for user input
          TextFormField(
            controller: controller,
            readOnly: readOnly, // Control editability
            keyboardType: keyboardType,
            validator: validator,
            style: TextStyle(
              color: theme.colorScheme.onSurface, // Text color
              fontWeight: FontWeight.w500, // Slightly bolder text
              fontSize: 16, // Standard input text size
            ),
            decoration: const InputDecoration(
              isDense: true, // Makes the input field slightly more compact
              contentPadding: EdgeInsets.zero, // Remove internal padding from TextFormField itself
              border: InputBorder.none, // Remove default border
              focusedBorder: InputBorder.none, // Remove default border on focus
              enabledBorder: InputBorder.none,
              errorBorder: InputBorder.none,
              focusedErrorBorder: InputBorder.none,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDarkMode = Provider.of<ThemeProvider>(context).isDarkMode;

    // Define colors to match the image's clean white/light grey theme in light mode
    final Color backgroundColor = isDarkMode ? Colors.grey[900]! : const Color(0xFFF0F0F0); // A very light grey background
    final Color appBarColor = isDarkMode ? Colors.grey[850]! : Colors.white; // White app bar
    final Color textColor = isDarkMode ? Colors.white : Colors.black87; // Dark text for light mode

    return Scaffold(
      backgroundColor: backgroundColor, // Consistent background
      appBar: AppBar(
        title: Text("Your Profile", style: TextStyle(color: textColor, fontWeight: FontWeight.w600)),
        backgroundColor: appBarColor,
        foregroundColor: textColor, // For back icon and any other foreground elements
        elevation: 0.0, // No elevation for a flat look
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: textColor), // Back arrow icon
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _currentRiderData == null
          ? const Center(child: Text("Could not load profile data."))
          : SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 0.0, vertical: 0.0), // Remove padding here as it's added to the container
        child: Container( // This is the new white box container
          margin: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 24.0), // Margin around the white box
          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 24.0), // Internal padding for the form content
          decoration: BoxDecoration(
            color: isDarkMode ? Colors.grey[850] : Colors.white, // White background for the main box
            borderRadius: BorderRadius.circular(15), // Rounded corners for the white box
            boxShadow: [ // Optional subtle shadow for the white box
              BoxShadow(
                color: Colors.grey.withOpacity(0.1),
                spreadRadius: 1,
                blurRadius: 5,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // Profile Image Picker Section
                Center(
                  child: Stack(
                    children: [
                      Container(
                        width: 100.0 + 8, // Slightly larger for border/shadow
                        height: 100.0 + 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isDarkMode ? Colors.grey[800] : Colors.white, // Background for the image circle
                          boxShadow: [
                            BoxShadow(
                              color: Colors.grey.withOpacity(0.2),
                              spreadRadius: 1,
                              blurRadius: 3,
                              offset: const Offset(0, 1),
                            ),
                          ],
                          border: Border.all(color: Colors.grey.withOpacity(0.2), width: 1), // Subtle border
                        ),
                        child: ClipOval(
                          child: _imageFile != null
                              ? Image.file(_imageFile!, width: 100.0, height: 100.0, fit: BoxFit.cover)
                              : (_currentProfileImageUrl != null && _currentProfileImageUrl!.isNotEmpty
                              ? CachedNetworkImage(
                            imageUrl: _currentProfileImageUrl!,
                            width: 100.0,
                            height: 100.0,
                            fit: BoxFit.cover,
                            placeholder: (context, url) => SizedBox(
                                width: 100.0,
                                height: 100.0,
                                child: Center(
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: theme.colorScheme.secondary))),
                            errorWidget: (context, url, error) =>
                                Icon(Icons.person_outline, size: 100.0, color: theme.colorScheme.secondary),
                          )
                              : Icon(Icons.person_outline, size: 100.0, color: theme.colorScheme.secondary.withOpacity(0.5))), // Faded icon
                        ),
                      ),
                      // Edit icon overlay
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: GestureDetector(
                          onTap: _pickImage,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: AppTheme.primaryColor, // Use your app's primary color
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2), // White border for contrast
                            ),
                            child: const Icon(Icons.edit, color: Colors.white, size: 18), // Smaller, white edit icon
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 30), // Spacing below profile image

                // Name Field (Editable)
                _buildStyledInputField(
                  controller: _nameController,
                  labelText: "Name",
                  theme: theme,
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Please enter your name';
                    }
                    if (value.trim().length < 3) {
                      return 'Name must be at least 3 characters';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16), // Spacing between fields

                // Phone Number Field (Editable)
                _buildStyledInputField(
                  controller: _phoneController,
                  labelText: "Mobile",
                  theme: theme,
                  keyboardType: TextInputType.phone,
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Please enter your phone number';
                    }
                    if (!RegExp(r'^\+?[0-9\s-]{7,15}$').hasMatch(value.trim())) {
                      return 'Enter a valid phone number';
                    }
                    return null;
                  },
                ),

                const SizedBox(height: 35), // Spacing above the button
                ElevatedButton(
                  onPressed: _isSaving ? null : _saveProfile,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor, // Your app's primary color
                    foregroundColor: Colors.white, // Text color
                    padding: const EdgeInsets.symmetric(vertical: 16), // Vertical padding
                    textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12), // Consistent border radius
                    ),
                    elevation: 0, // No elevation for a flat button
                  ),
                  child: _isSaving
                      ? const SizedBox(
                    width: 24, // Size of the loading indicator
                    height: 24,
                    child: CircularProgressIndicator(
                        strokeWidth: 3, color: Colors.white), // White loading indicator
                  )
                      : const Text("Update profile"), // Button text
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
