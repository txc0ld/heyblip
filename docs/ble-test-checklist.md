# BLE Mesh Real-Device Test Checklist

**Date:** _______________
**Tester:** _______________
**Phone A:** _______________  (model, iOS version)
**Phone B:** _______________  (model, iOS version)
**Build:** _______________ (commit SHA)

---

## Pre-flight

- [ ] Both phones have Blip installed and launched
- [ ] Both phones completed onboarding (bypass code: 000000)
- [ ] Bluetooth enabled on both phones
- [ ] Location services enabled on both phones
- [ ] Debug overlay accessible (triple-tap Nearby tab title)
- [ ] Phones start within 1 meter of each other

---

## Test 1: Discovery

**Goal:** Both phones discover each other via BLE within 10 seconds.

| Field | Value |
|-------|-------|
| Pass / Fail | |
| Time to discovery (Phone A sees B) | |
| Time to discovery (Phone B sees A) | |
| Service UUID correct (FC000001...)? | |
| Notes | |

**Steps:**
1. Open Blip on both phones
2. Navigate to Nearby tab on both
3. Open debug overlay (triple-tap title)
4. Wait for peer to appear in the peer list
5. Record time from app open to peer appearing

---

## Test 2: Noise XX Handshake

**Goal:** Encrypted channel established between both devices.

| Field | Value |
|-------|-------|
| Pass / Fail | |
| Time from discovery to encrypted | |
| Handshake status shows "encrypted"? | |
| Notes | |

**Steps:**
1. After discovery, watch debug overlay handshake status
2. Status should progress: `pending` -> `established` -> `encrypted`
3. Record total time

---

## Test 3: Chat Message (A -> B)

**Goal:** Text message delivers from Phone A to Phone B.

| Field | Value |
|-------|-------|
| Pass / Fail | |
| Send-to-receive latency | |
| Message content matches exactly? | |
| Delivery ack received on Phone A? | |
| Notes | |

**Steps:**
1. On Phone A, open Chats tab, create DM to Phone B's peer
2. Type "Hello from Phone A — test message 1" and send
3. On Phone B, confirm message appears in chat
4. Record latency from debug overlay

---

## Test 4: Bidirectional Messaging

**Goal:** Both phones send and receive messages simultaneously without drops.

| Field | Value |
|-------|-------|
| Pass / Fail | |
| Messages sent from A | |
| Messages received by B | |
| Messages sent from B | |
| Messages received by A | |
| Any drops? | |
| Notes | |

**Steps:**
1. Both phones open the DM conversation
2. Phone A sends 5 messages rapidly
3. Phone B sends 5 messages rapidly (at the same time)
4. Count received messages on both sides
5. Verify ordering is correct

---

## Test 5: Range Test

**Goal:** Determine maximum reliable BLE range.

| Field | Value |
|-------|-------|
| Pass / Fail | |
| Distance: first message failure | |
| Distance: BLE disconnect | |
| Indoor / outdoor | |
| Obstructions? | |
| Notes | |

**Steps:**
1. Start with phones together, sending messages every 5 seconds
2. Slowly walk Phone B away from Phone A
3. Monitor debug overlay for RSSI drop
4. Note the distance when first message fails to deliver
5. Note the distance when BLE disconnects entirely
6. Record RSSI at each distance marker (5m, 10m, 20m, 30m, 50m)

| Distance | RSSI (A->B) | RSSI (B->A) | Message delivered? |
|----------|-------------|-------------|-------------------|
| 5m | | | |
| 10m | | | |
| 20m | | | |
| 30m | | | |
| 50m | | | |

---

## Test 6: Reconnection

**Goal:** Phones automatically reconnect after going out of range and returning.

| Field | Value |
|-------|-------|
| Pass / Fail | |
| Time to reconnect | |
| Handshake re-established? | |
| Queued messages delivered? | |
| Notes | |

**Steps:**
1. Walk phones apart until BLE disconnects
2. Wait 10 seconds
3. Bring phones back within 2 meters
4. Monitor debug overlay for reconnection
5. Send a test message to confirm channel works

---

## Test 7: SOS Broadcast

**Goal:** SOS alert from Phone A is received and actionable on Phone B.

| Field | Value |
|-------|-------|
| Pass / Fail | |
| Alert appears on Phone B? | |
| Severity level correct? | |
| Accept/resolve flow works? | |
| Latency (send to receive) | |
| Notes | |

**Steps:**
1. On Phone A, trigger SOS (long-press SOS button, select severity)
2. On Phone B, confirm alert notification appears
3. On Phone B, accept the SOS alert
4. On Phone A, confirm acceptance notification
5. On Phone A, resolve the SOS
6. On Phone B, confirm resolution

---

## Test 8: Location Beacon

**Goal:** Friend Finder map shows peer locations in real time.

| Field | Value |
|-------|-------|
| Pass / Fail | |
| Phone A visible on Phone B's map? | |
| Phone B visible on Phone A's map? | |
| Accuracy ring color correct? | |
| Location updates within 30s? | |
| "I'm Here" beacon appears? | |
| Notes | |

**Steps:**
1. On both phones, open Friend Finder map
2. Enable location sharing on both
3. Confirm friend pins appear on each other's maps
4. Drop an "I'm Here" beacon on Phone A
5. Confirm beacon appears on Phone B's map
6. Check accuracy ring color matches GPS precision

---

## Test 9: WebSocket Relay Fallback

**Goal:** Messages route through WebSocket when BLE is unavailable.

| Field | Value |
|-------|-------|
| Pass / Fail | |
| BLE latency (before disable) | |
| WebSocket latency | |
| Fallback automatic? | |
| Messages arrive via relay? | |
| Notes | |

**Steps:**
1. Send a test message over BLE, note latency
2. On Phone A, disable Bluetooth in Settings
3. On Phone A, send another message
4. Debug overlay should show "WS: Connected" and "BLE: Stopped"
5. Confirm Phone B receives the message (via relay)
6. Note latency difference
7. Re-enable Bluetooth, confirm BLE reconnects

---

## Test 10: Stress Test (50 Messages)

**Goal:** 50 rapid-fire messages all arrive without drops or reordering.

| Field | Value |
|-------|-------|
| Pass / Fail | |
| Messages sent | 50 |
| Messages received | |
| Messages dropped | |
| Ordering correct? | |
| Time for all 50 to arrive | |
| Notes | |

**Steps:**
1. On Phone A, send 50 messages as fast as possible (copy-paste "Test N" for N=1..50)
2. On Phone B, count received messages in the chat
3. Verify no messages are missing
4. Verify ordering is 1, 2, 3, ..., 50
5. Note total time from first send to last receive

---

## Summary

| Test | Result | Key Finding |
|------|--------|-------------|
| 1. Discovery | | |
| 2. Handshake | | |
| 3. Chat message | | |
| 4. Bidirectional | | |
| 5. Range | | |
| 6. Reconnection | | |
| 7. SOS broadcast | | |
| 8. Location beacon | | |
| 9. Relay fallback | | |
| 10. Stress test | | |

**Overall assessment:** _______________

**Blocking issues found:** _______________

**Action items:** _______________
