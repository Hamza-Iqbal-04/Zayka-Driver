const functions = require("firebase-functions");
const admin = require("firebase-admin");
admin.initializeApp();

// 1. Listen for NEW assignments in the 'rider_assignments' collection
exports.sendAssignmentNotification = functions.firestore
  .document("rider_assignments/{assignmentId}")
  .onCreate(async (snapshot, context) => {
    const data = snapshot.data();
    const riderId = data?.riderId;
    const orderId = data?.orderId;

    if (!riderId || !orderId) return null;

    try {
      // Fetch the Driver's FCM Token
      const driverDocRef = admin.firestore().collection("Drivers").doc(riderId);
      const driverDoc = await driverDocRef.get();

      if (!driverDoc.exists) {
        console.log(`Driver doc not found: ${riderId}`);
        return null;
      }

      const fcmToken = driverDoc.data()?.fcmToken;
      if (!fcmToken) {
        console.log(`No FCM token found for driver: ${riderId}`);
        return null;
      }

      // Construct the Instant-Delivery Payload (visible notification + data)
      const payload = {
        token: fcmToken, // use "topic": `rider_${riderId}` if you switch to topics
        notification: {
          title: "🚨 New Order Offer!",
          body: "Tap quickly! You have 2 minutes to accept.",
          // note: sound for Android is controlled via android.notification or native channel
        },
        data: {
          type: "assignment_request",
          orderId: orderId,
          click_action: "FLUTTER_NOTIFICATION_CLICK"
        },
        android: {
          priority: "high",
          ttl: 0, // immediate or drop
          notification: {
            channelId: "rider-assignment", // ensure this channel is created on the client
            priority: "max",
            visibility: "public",
            defaultSound: true,
            // optionally add icon, color, etc. if needed
          }
        },
        apns: {
          headers: {
            "apns-priority": "10",
            "apns-expiration": "0",
            "apns-push-type": "alert" // critical for iOS immediate alert delivery
          },
          payload: {
            aps: {
              alert: {
                title: "New Order Offer!",
                body: "Tap to accept — 2 min"
              },
              sound: "default",
              content-available: 1
            }
          }
        }
      };

      // Send the message
      return admin.messaging().send(payload);

    } catch (error) {
      console.error("Error sending notification:", error);
      return null;
    }
  });
