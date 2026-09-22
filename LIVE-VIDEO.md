# Shared live video (0.19.0; tags added in 0.20.0)

Homebase may subscribe to the H.264 stream already received by HBNVR. This is
independent of stores and recording intent: an enabled camera can serve live video
with recording stopped and with no stores configured. The subscription never
creates a camera connection, changes quality, or alters recording. H.265 live
forwarding is not advertised yet because Homebase's live media protocol is H.264.
H.265 recording/history are unchanged. A configured video profile is required.

`cameras.snapshot` / `cameras.watch` optionally include `liveVideo` per camera:

```json
{"version":1,"frameTagsVersion":1,"codec":"H264","width":1280,"height":720,"frameRate":15,"bitrateKbps":1000}
```

This advertises the configured receiver capability, not proof of current frames.
Disabled/unconfigured cameras omit it. Profile changes advance the watch revision.
The projection includes no endpoints, profile tokens, or credentials.

## Dedicated authenticated connection

Connect to the same Unix socket as control, with the same authorized-user and
peer-UID checks. Send this newline-delimited JSON request using identities from
the current camera snapshot:

```json
{"protocolVersion":1,"operation":"live.open","liveProtocolVersion":1,"nvrInstanceID":"<instance UUID>","cameraID":"<camera UUID>","homebaseDeviceID":"camera-vendor-serial"}
```

The daemon checks the instance, camera binding, enablement, H.264 profile, and
recent live reception. On failure the ordinary error reply closes the connection.
Success returns `liveSession` in the ordinary reply, then immediately streams
binary records. Retain bytes received after the reply's newline:

```json
{"protocolVersion":1,"liveSession":{"version":1,"frameTagsVersion":1,"cameraID":"<camera UUID>","profile":{"version":1,"frameTagsVersion":1,"codec":"H264","width":1280,"height":720,"frameRate":15,"bitrateKbps":1000},"framing":"media-v1","sampleFormat":"avcc","maximumFrameBytes":8380416}}
```

Each media-v1 record has a one-byte type and four-byte big-endian payload length,
followed by at most 65,536 bytes. Type 1 is a JSON frame header:

```json
{"type":"frame","timestamp":12345,"clockRate":90000,"keyFrame":true,"parameterSets":["<base64 SPS>","<base64 PPS>"],"byteCount":123456,"tags":{"example.note":"value"}}
```

Type 2 records immediately following it contain exactly `byteCount` bytes of
the unmodified AVCC access unit (four-byte big-endian NAL lengths). Timestamps
are 32-bit RTP ticks at `clockRate`, with ordinary rollover; they are not UTC
or stable frame references. Homebase extends/converts them to its existing
90-kHz media clock. Parameter sets accompany every frame. Subscription begins
at the next keyframe, not a retained GOP. Closing the socket unsubscribes.

`frameTagsVersion: 1` promises a complete `tags` dictionary on every frame,
including `{}` when no keys apply. Older servers omit the capability/field:
that is unknown metadata, not a trustworthy empty map. No tag deltas or separate
subscription must be synchronized. Queued frames retain their original tags;
commands affect subsequent ingestion, not frames already received by a viewer.
Old clients may ignore the additive fields. See [tag commands/storage](VIDEO-TAGS.md).

Receiver interruption, packet loss, RTP source/clock-rate change, camera removal/disable/reconfiguration,
authorization loss, shutdown, malformed/unsupported media, or a slow reader
closes the stream. Reopen using current discovery; never concatenate separate
connections as one decoder generation. Stopping recording alone does not close it.
Account identity is revalidated every 30 seconds on the subscriber worker, never
per video frame or while holding a lock used by recording.

## Bounds and compatibility

At most eight live subscriptions, separate from history sessions. Each retains
at most 8 MiB / 120 frames including the outstanding write and an 8-KiB tag
reservation per frame, with five-second
write deadlines. Overflow disconnects only that reader. Admission writes and
stream writes occur outside recording/hub locks. No second GOP archive, files,
transcoding, keyframe requests, or camera keepalives are created by a viewer.

The Homebase integration uses one subscription per camera/shared quality and its
existing bounded authenticated client fanout. Older NVRs omit `liveVideo`, so
Homebase continues to use direct RTSP. A failed shared feed receives bounded
retry/direct-camera fallback in Homebase; NVR recording remains independent.
See Homebase's `Documentation/NVRLiveVideo.md` for Default/quality routing and the
temporary all-qualities override. Installing/restarting HBNVR is a separate action.
