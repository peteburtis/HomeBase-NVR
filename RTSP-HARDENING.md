# Camera protocol hardening backlog

Recorded September 19, 2026, against the 0.18.2 executable and the corresponding
RTSP/stream coordinator implementation. All items below are open; this document
records an audit, not implemented fixes.

## Relationship to the camera outage

These deficiencies are worth addressing independently of the September 2026 camera
outage. **They are not established causes of that outage.** Most affect setup,
reconnection, configuration changes, or shutdown. The NVR was in a fairly static
state around the reported failures, making these transition-path defects poor
candidates for the immediate cause.

Read-only observations during the audit showed one established TCP stream per
camera, fresh frames, and empty socket queues. At about 16.6 hours of daemon uptime,
the current Bedroom stream counters showed zero reconnects and Living Room showed
three. Counters can reset on configuration edits; they are not a permanent session
history. Retrieved logs did not establish the causes of those three reconnects.
There was no observed NVR equivalent of HomeBase's ONVIF polling burst. That burst
remains a separate, stronger workload anomaly, not a proven cause either.

Stopping an otherwise healthy NVR stream could free camera resources and enable
recovery from a failure triggered elsewhere. Recovery after an NVR stop therefore
would not, by itself, establish that the NVR caused the problem. Do not interrupt
the production recorder merely to exercise these cases; use isolated local agents
and synthetic cameras unless live interruption is explicitly authorized.

## Open items

### RTSP-01 — Clean up known sessions on recoverable control errors

- [ ] Consolidate bounded session cleanup for failure, replacement, and shutdown.

**Evidence:** `RTSPClient.sendKeepalive` treats an unsuccessful OPTIONS as fatal.
`RTSPClient.fail` cancels TCP immediately without TEARDOWN, even when the socket
remains usable and the session ID is known. Closing TCP is not a guarantee of
releasing RTSP session resources on the server.

**Reproduced:** A fake camera continued sending video but answered one keepalive
with RTSP 500. The client closed without TEARDOWN and opened a replacement session.
The ordinary retry path did not overlap TCP connections.

**Acceptance:** Attempt bounded, authenticated cleanup when the transport is usable
and a session is known; do not try to send on a broken transport or add an unbounded
recovery loop. Distinguish control failures from transport loss. Retain conservative
retry pacing and explicitly record whether cleanup was acknowledged or abandoned.

### RTSP-02 — Process teardown status and authentication during shutdown

- [ ] Keep response/authentication handling active for TEARDOWN while stopping.

**Evidence:** `RTSPClient.receiveResponse` takes its `stopping` branch before status
and authentication processing. Any TEARDOWN response ends the stop, including 401
or 500; it is not necessarily a successful release.

**Reproduced:** Initial Digest authentication succeeded. A fresh-nonce challenge
on TEARDOWN produced one unauthenticated-to-the-new-nonce attempt, then closure
without retry. The normal request authentication retry was bypassed.

**Acceptance:** A valid teardown authentication challenge gets a bounded retry
within the overall cleanup deadline. Non-success responses are not reported as
acknowledged cleanup. Repeated challenges or errors cannot prevent termination.

### RTSP-03 — Retain allocated sessions before taking an exit path

- [ ] Capture a valid SETUP Session header before stopping or rejecting transport.

**Evidence/reproduction:** Hold a successful SETUP response, request shutdown, then
return the response with its new Session ID. The stopping branch skips normal SETUP
handling, so the session is never retained and no TEARDOWN is sent.

**Additional source finding:** `RTSPClient.sendSetup` validates Transport before
saving Session. An incompatible transport response can therefore also leave a
known-to-the-camera allocation without an explicit release. This variant was not
separately exercised in the audit.

**Acceptance:** Both delayed-SETUP-during-stop and invalid-transport-with-valid-session
fixtures attempt cleanup when possible, without starting PLAY or accepting an
unsupported transport. Malformed session identifiers remain rejected safely.

### RTSP-04 — Avoid unnecessary reconnection and replacement overlap

- [ ] Preserve the receiver for name-only edits; sequence real stream replacements.

**Evidence:** `StreamingCoordinator.add` special-cases recording intent, but not
display-name edits. It calls the old client's asynchronous `stop` and immediately
connects a replacement.

**Reproduced:** A name-only edit with a 650 ms delayed teardown reply caused two
simultaneous TCP streams. The new session reached PLAY before old-session cleanup
completed. Both sessions were eventually released.

**Acceptance:** A rename updates labels/recording metadata without another SETUP
or resetting stream-health counters. Necessary profile/endpoint replacements wait
for bounded old-client cleanup. Rapid edits coalesce to the latest desired state
without accumulating clients; stale callbacks cannot restart superseded streams.
Persistent recording start/stop must continue to leave the receiver connected.

### RTSP-05 — Use one coherent bounded cleanup deadline

- [ ] Reconcile the one-second stop cutoff and two-second teardown timeout.

**Source finding:** `RTSPClient.stopOnQueue` schedules forced closure after one
second, while `beginTeardownOrFinish` gives TEARDOWN two seconds. The first deadline
wins; a pending slow request can consume the entire budget before teardown begins.
The dedicated slow-timeout variant was not separately exercised.

**Acceptance:** Define an explicit total cleanup budget and use its remaining time
consistently for pending responses, authentication, and teardown. Test slow and
nonresponsive cameras, including a pending keepalive. Coordinate any adjustment
with `StreamingCoordinator.stop` and the application's overall shutdown budget;
no camera can hang shutdown indefinitely.

### RTSP-06 — Honor explicit aggregate SDP control URLs

- [ ] Resolve session-level aggregate control separately from video-track control.

**Source finding:** `RTSPSDPParser.parse` reads session-level `a=control`, but
`RTSPClient.sendDescribe` uses Content-Base as `aggregateURL`. An explicitly different
aggregate URL is not honored for PLAY/keepalive/TEARDOWN. This was not reproduced
against the deployed cameras and is an interoperability issue, not outage evidence.

**Acceptance:** Test explicit relative/absolute session control, `a=control:*`, and
track-specific SETUP URLs. Preserve authority pinning and credential stripping;
camera-supplied SDP must not redirect credentials to another host.

### RTSP-07 — Review outgoing RTCP receiver feedback

- [ ] Evaluate receiver reports/SDES and appropriate session-end signaling.

**Source finding:** The client consumes RTCP sender reports for timing but sends
no receiver reports, SDES, or BYE. It uses RTSP OPTIONS for session liveness.
ONVIF accepts RTSP requests as keepalives and recommends receiver reports to reduce
RTSP keepalive overhead. Absence of receiver reports is not, by itself, evidence
of exhaustion or a failed keepalive scheme.

**Acceptance:** Establish the applicable RTP/RTSP requirements and camera
compatibility before changing the strategy. Add synthetic packet/cadence tests
for any feedback implementation. Avoid redundant high-frequency keepalives and
retain a compatible, bounded liveness mechanism. No speculative production switch
is part of this audit.

### RTSP-08 — Add sanitized session-lifecycle observability

- [ ] Make connection churn and cleanup outcomes diagnosable without credentials.

Record camera ID, operation, sanitized status/failure category, connection/session
generation, age, reconnect reason/backoff, and cleanup outcome (acknowledged,
rejected, transport lost, or deadline expired). Distinguish connection attempts
from successfully established sessions and avoid losing diagnostic history on a
name edit. Deduplicate repetitive failures; do not log every frame/packet or add
routine disk churn. Raw URLs, Authorization headers, passwords, and raw session
tokens must not be logged. Update the stale `hbnvr/0.4` User-Agent when touching
protocol diagnostics.

## Verification evidence and regression plan

Five targeted fake-camera cases were run against the installed 0.18.2 executable
in isolated temporary runtime directories, with no recording stores:

1. Normal stop: authenticated setup/streaming/keepalives followed by successful
   TEARDOWN; one connection and one explicitly released session.
2. Keepalive 500 with video still arriving: old connection closed without TEARDOWN.
3. TEARDOWN 401 with a fresh Digest nonce: no authenticated retry.
4. Stop during SETUP: successful allocation received, no TEARDOWN sent.
5. Rename with delayed teardown: two concurrent connections.

These checks confirmed **current behavior**, including defects. Their passing
assertions did not establish correctness. The fake server counted explicit release
requests; it did not prove that real Tapo firmware leaked any resources. A one-off
audit harness was used; the scenarios above are recorded here so future regression
tests do not depend on that temporary file. Add permanent tests asserting the
corrected behavior when implementing these items.

Four existing `scripts/integration.py` tests also passed:

- `test_streams_receive_discard_keepalive_remove_and_restart`
- `test_stream_disconnect_reconnect_and_auth_failure_are_isolated`
- `test_stream_watchdog_reconnects_when_video_stalls`
- `test_camera_controls_are_persistent_and_stop_keeps_receiver_alive`

Preserve the healthy baseline: one steady-state stream per configured camera,
no background ONVIF subscriptions/polling, one outstanding RTSP request, bounded
authentication and reconnect backoff, bounded recording input queues, and no new
camera connections for shard rotation or history retrieval.

## Source and protocol references

- [RTSP transport](HomeBase-NVR/RTSP.swift): `RTSPClient` and `RTSPSDPParser`.
- [Streaming coordinator](HomeBase-NVR/Streaming.swift): `add`, `retry`, and `stop`.
- [Integration tests](scripts/integration.py).
- [RFC 2326](https://www.rfc-editor.org/rfc/rfc2326.txt), sections 1.7 and 10.7:
  RTSP session state and TEARDOWN resource release.
- [ONVIF Streaming Specification](https://www.onvif.org/specs/stream/ONVIF-Streaming-Spec.pdf),
  version 26.06, section 5.2.2.2: RTSP/RTCP session liveness and receiver-report guidance.
