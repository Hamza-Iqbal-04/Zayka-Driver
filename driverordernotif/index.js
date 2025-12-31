// driverordernotif/index.js
const { onDocumentCreated, onDocumentUpdated } = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");

admin.initializeApp();

/**
 * Resolve an FCM token:
 * 1) prefer token supplied in doc,
 * 2) otherwise lookup Drivers/{riderId} for token.
 */
async function resolveFcmToken(riderId, possibleTokenFromDoc) {
  if (possibleTokenFromDoc) return possibleTokenFromDoc;
  if (!riderId) return null;
  try {
    const driverDoc = await admin.firestore().collection("Drivers").doc(riderId).get();
    if (!driverDoc.exists) return null;
    const d = driverDoc.data() || {};
    // try common token field names
    return d.fcmToken || d.riderFcmToken || d.fcm || null;
  } catch (err) {
    console.error("resolveFcmToken: lookup error", err);
    return null;
  }
}

/** Build a standard notification payload (used for auto-offer notifications) */
function buildOfferPayload(fcmToken, orderId) {
  return {
    token: fcmToken,
    notification: {
      title: "🚨 New Order Offer!",
      body: "Tap quickly! You have 2 minutes to accept."
    },
    data: {
      type: "assignment_request",
      orderId: String(orderId),
      click_action: "FLUTTER_NOTIFICATION_CLICK"
    },
    android: {
      priority: "high",
      ttl: 0,
      notification: {
        channelId: "rider-assignment",
        priority: "max",
        visibility: "public",
        defaultSound: true
      }
    },
    apns: {
      headers: {
        "apns-priority": "10",
        "apns-expiration": "0",
        "apns-push-type": "alert"
      },
      payload: {
        aps: {
          alert: { title: "New Order Offer!", body: "Tap to accept — 2 min" },
          sound: "default"
        }
      }
    }
  };
}

/**
 * Trigger: new assignment document created in rider_assignments collection
 * Uses riderFcmToken from doc if present; otherwise resolves from Drivers/{riderId}
 */
exports.sendAssignmentNotification = onDocumentCreated(
  "rider_assignments/{assignmentId}",
  async (event) => {
    try {
      const snapshot = event.data;                 // DocumentSnapshot
      const data = (snapshot && snapshot.data && snapshot.data()) ? snapshot.data() : {};
      const orderId = data?.orderId;
      const riderId = data?.riderId;
      const tokenFromDoc = data?.riderFcmToken || data?.riderToken || data?.riderFCM || null;

      if (!orderId) {
        console.log("sendAssignmentNotification: missing orderId", { docId: snapshot ? snapshot.id : null });
        return null;
      }

      const fcmToken = await resolveFcmToken(riderId, tokenFromDoc);
      if (!fcmToken) {
        console.log("sendAssignmentNotification: no fcm token available", { riderId, docId: snapshot ? snapshot.id : null });
        return null;
      }

      const payload = buildOfferPayload(fcmToken, orderId);
      await admin.messaging().send(payload);
      console.log("sendAssignmentNotification: notification sent", { docId: snapshot ? snapshot.id : null, orderId });
      return null;
    } catch (err) {
      console.error("sendAssignmentNotification: error", err);
      return null;
    }
  }
);

/**
 * Trigger: orders/{orderId} updated
 * Detects when an order becomes assigned (riderId / assignedTo / driverId changed)
 * and sends a notification to the newly assigned rider using a custom manual-assignment message.
 */
exports.sendManualAssignmentNotification = onDocumentUpdated(
  "Orders/{orderId}",
  async (event) => {
    try {
      const beforeSnap = event.data.before || null;
      const afterSnap = event.data.after || null;
      const before = beforeSnap && beforeSnap.data ? (beforeSnap.data() || {}) : {};
      const after = afterSnap && afterSnap.data ? (afterSnap.data() || {}) : {};
      const orderId = event.params?.orderId || (afterSnap ? afterSnap.id : null);

      // check possible assignment fields (add more keys here if your app uses different names)
      const prevRider =
        before?.assignedTo || before?.riderId || before?.assignedRider || before?.driverId || before?.assigned_driver_email || null;
      const newRider =
        after?.assignedTo || after?.riderId || after?.assignedRider || after?.driverId || after?.assigned_driver_email || null;

      // if no change or no new rider, do nothing
      if (!newRider || newRider === prevRider) {
        return null;
      }

      // prefer any fcm token written on the order doc
      const tokenFromDoc = after?.riderFcmToken || after?.assignedRiderFcmToken || after?.riderToken || null;
      const fcmToken = await resolveFcmToken(newRider, tokenFromDoc);

      if (!fcmToken) {
        console.log("sendManualAssignmentNotification: no fcm token for new rider", { newRider, orderId });
        return null;
      }

      // CUSTOM MESSAGE FOR MANUAL ASSIGNMENT
      const payload = {
        token: fcmToken,
        notification: {
          title: "You’ve been assigned an order!",
          body: "A new delivery is now assigned to you."
        },
        data: {
          type: "manual_assignment",
          orderId: String(orderId),
          click_action: "FLUTTER_NOTIFICATION_CLICK"
        },
        android: {
          priority: "high",
          ttl: 0,
          notification: {
            channelId: "rider-assignment",
            priority: "max",
            visibility: "public",
            defaultSound: true
          }
        },
        apns: {
          headers: {
            "apns-priority": "10",
            "apns-expiration": "0",
            "apns-push-type": "alert"
          },
          payload: {
            aps: {
              alert: {
                title: "You’ve been assigned an order!",
                body: "A new delivery is now assigned to you."
              },
              sound: "default"
            }
          }
        }
      };

      await admin.messaging().send(payload);
      console.log("sendManualAssignmentNotification: notification sent", { orderId, newRider });
      return null;
    } catch (err) {
      console.error("sendManualAssignmentNotification: error", err);
      return null;
    }
  }
);
