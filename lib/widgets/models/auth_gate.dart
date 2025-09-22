import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:myapp/screens/login_screen.dart';
import 'package:myapp/main.dart'; // MainNavigation

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  Future<bool> _isRider(String email) async {
    final snap =
        await FirebaseFirestore.instance
            .collection('Drivers')
            .where('email', isEqualTo: email)
            .limit(1)
            .get();

    return snap.docs.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnap) {
        if (authSnap.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final user = authSnap.data;

        if (user == null) {
          return const LoginScreen();
        }

        return FutureBuilder<bool>(
          future: _isRider(user.email ?? ""),
          builder: (context, riderSnap) {
            if (riderSnap.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }

            if (riderSnap.hasData && riderSnap.data == true) {
              return const MainNavigation(); // ✅ verified Rider
            } else {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text("No Driver account found."),
                    backgroundColor: Colors.red,
                  ),
                );
              });
              FirebaseAuth.instance.signOut(); // ❌ force logout
              return const LoginScreen();
            }
          },
        );
      },
    );
  }
}
