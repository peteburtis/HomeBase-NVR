# Prospective video tags (0.20.0)

Tags are opaque, case-sensitive string keys and string values per configured
camera. No namespace, value, or spelling has authorization/automation meaning to
HBNVR. These are descriptive metadata, not access control.

## Commands and ordering

```sh
hbnvr camera tag set "Bedroom Camera" --key example.note --value "occupied"
hbnvr camera tag set "Bedroom Camera" --key example.note --value ""
hbnvr camera tag remove "Bedroom Camera" --key example.note
hbnvr camera tag list "Bedroom Camera"
```

NAME may be a UUID; omit it for the normal camera picker. Commands accept
`--runtime-dir` for an unprivileged agent and return the complete dictionary as
escaped JSON. Empty strings are values; remove means absence. Repeating a set or
removing an absent key is idempotent. Other keys/cameras remain unchanged.

Current tags are saved in private camera configuration (`Tags`) and survive
reconnects, profile changes, recording stops, disable/enable, and daemon restarts.
They can be changed while a configured camera is offline/disabled. Removing the
camera removes its current state, not previously recorded metadata.

Disk persistence precedes applying the dictionary on the camera coordinator's
serial queue; the acknowledgment follows application. Every subsequent accepted
frame gets an immutable value snapshot **before** live/store queue fanout.
Already accepted frames keep their old tags, even in RAM or awaiting upload.
Commands do not reconnect RTSP, change recording intent, force a keyframe, split
shards, rewrite existing objects, or edit any absolute/relative historical range.
The boundary is ingestion order, not camera exposure time or command-client time.

Authenticated control IPC (protocolVersion 1) uses `cameras.tags.get`,
`cameras.tags.set`, and `cameras.tags.remove`, with `cameraID`; set takes `tagKey`
and `tagValue`, remove only `tagKey`. Replies contain `tags`. Integrations should
also supply both `nvrInstanceID` and `homebaseDeviceID` from current discovery;
if either is supplied both must match, preventing stale-instance/rebound-camera
writes. There is no tag subscription. [Live frames](LIVE-VIDEO.md) carry the
complete dictionary and advertise `frameTagsVersion: 1`.

## Recorded representation

Each shard records a `VideoTagTimeline` version 1: `changes` contains complete
`tags` snapshots with shard-relative `ticks` in the shard's timescale and
zero-based `frame` numbers. The first entry is at ticks/frame zero, even when
empty. Each entry applies up to the next boundary, or the end of the shard.
Only changes consume additional entries; every shard starts self-contained.

- Local SQLite schema 3 stores this JSON with checkpointed/final progress.
  Bounded finalization retries retain the same timeline along with media identity.
- Both MP4 writers append an ISO-BMFF `uuid` box after AVFoundation finalization,
  before durable local publication or S3 encryption/upload. Its UUID is
  `596a0f37-0baf-437e-9aab-621d5b9df760`, followed by UTF-8 timeline JSON.
  Video samples/offsets remain unchanged. This is custom metadata, not a player-
  interpreted track. Unfinished local files may lack the final box; their last
  successful SQLite checkpoint is only a prefix, not proof of later tag state.
- S3 spool objects and daily/monthly shard entries carry optional `tagMetadata`.
  For plaintext footage it contains `timeline`; for encrypted footage it contains
  base64 `encrypted`, an independent HBNVR-PBE-v1 envelope using the recording's
  password. That envelope remains frozen across retry/replay/password replacement.
  Tag values are never placed in plaintext spool sidecars for encrypted footage,
  S3 headers, object names, or diagnostic messages. Whole-object encryption also
  covers the MP4 box and cloud manifests. Private camera configuration and local
  manifests remain subject to their existing filesystem protections.
- S3 thumbnail JPEGs extend their existing JSON IPTC caption with the tag
  snapshot of the actual selected keyframe (not the nominal thumbnail slot).
  The entire JPEG is encrypted when configured. The spool descriptor omits tags.
- S3 repair reads the embedded box in RAM and preserves it and the corresponding
  thumbnail state. Missing legacy metadata remains unknown; it is never inferred
  from today's tags. Repair never updates the video object itself.

Historical editing is separately supported by `media tag` in 0.21.0; see
[historical tags](HISTORICAL-TAGS.md). `camera tag` remains prospective only.
Historical S3 edits change authoritative manifests, not embedded media tags.
Re-encoding/export through unrelated tools
may strip custom metadata. Clients must not treat missing metadata as an assurance
that no tags applied. Since 0.22.0, local-history frame requests can opt into
[segment tag maps](MEDIA-PROTOCOL.md#segment-tag-maps-0220), where unknown and
absent intentionally both mean no value. On-demand thumbnail IPC does not report
tags; Homebase and GUI consumers are unchanged.

## Bounds and failure policy

At most 32 keys, 256 UTF-8 bytes per nonempty key, 2048 bytes per value, and
8192 encoded JSON bytes for the current dictionary. Unicode/empty values are
preserved without normalization. Validation failure rejects the entire command.
Live/store input queues reserve 8 KiB per accepted frame for tags.

A shard retains at most 4096 change entries / 512 KiB of tag metadata. Extreme
churn beyond that budget logs a warning, explicitly marks `unknownFromTicks`
(and the exact `unknownFromFrame` for new recordings),
and keeps recording video; it never silently substitutes `{}` or lets metadata
grow without bound. The following shard starts fresh with the actual current
dictionary. Readers must treat that tail as unknown. S3 spool/journal metadata
is bounded to 1 MiB per object including ciphertext/base64 overhead.

Existing video/manifest durability rules apply. Local tags are checkpointed with
normal index progress, not with an extra per-frame disk write. Final tag-box
write failure is a finalization failure: local partial files are retained and not
published as complete. No installation, service restart, or camera change is
required to build/test this feature; deployment is a separate action.
