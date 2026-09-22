# Historical tags (0.21.0)

Historical edits are separate from `camera tag`: they never change current camera
configuration, live frames, camera watch status, or recording intent. Keys and
values remain opaque, case-sensitive strings. These are descriptive annotations,
not NVR authorization rules. Applications may use them for UI gating, but an S3
reader with credentials/password can still access the original objects directly.

## CLI

All commands use the authenticated control socket, without sudo. Add
`--runtime-dir PATH` for an isolated development agent. Target stores are explicit:
repeat `--store NAME_OR_UUID` to edit multiple stores, or omit it for the normal
store picker. There is no implicit propagation to other stores.

```sh
# Frame numbers are zero-based; end is EXCLUSIVE (frames 120 through 359).
hbnvr media tag set --store 'Local recordings' \
  --file '/absolute/managed/camera/recording.mp4' --frames 120:360 \
  --key recognition.person.alice --value present

# A shard UUID is meaningful together with its source store.
hbnvr media tag remove --store 'S3 recordings' \
  --source-store 'S3 recordings' --shard SHARD_UUID --all-frames \
  --key recognition.person.alice

# canonical (default), received, and camera timelines are supported.
hbnvr media tag set --store 'S3 recordings' --camera 'Bedroom Camera' \
  --timeline canonical --from '2026-09-21T14:30:00-07:00' \
  --to '2026-09-21T14:31:00-07:00' --key recognition.person.alice --value present

# Select actual frames relative to a timestamp, without finding a filename.
hbnvr media tag set --store 'Local recordings' --camera 'Bedroom Camera' \
  --from '2026-09-21T14:30:00-07:00' --from-frame 12 \
  --to '2026-09-21T14:30:00-07:00' --to-frame 30 \
  --key example.note --value detected

hbnvr media tag inspect --store 'Local recordings' \
  --file '/absolute/managed/camera/recording.mp4' --all-frames
hbnvr media tag status JOB_UUID
```

`--value ''` sets an empty string; `remove` makes the key absent only within the
selected interval. Other keys and all frames outside it retain their prior state.
Use `--dry-run` to validate and inspect proposed changes without any writes, or
`--expected-revision REVISION` to reject intervening edits to a single shard.
Inspection emits JSON with store/camera/shard identity, original timing, duration,
frame count when available, current opaque revision, and the authoritative tag
timeline. Camera UUIDs continue to address retained history after camera removal.

Only finalized, indexed local recordings and confirmed, indexed S3 recordings
participate. Active/interrupted files and pending S3 uploads are not edited. File
paths must identify existing managed files, not arbitrary MP4s or symlinks; use
the configured physical recording path, without `.` or `..` components. Store and
shard UUIDs avoid path spelling/rename issues.

### Frame and time semantics

File/shard ranges use actual presentation-order samples, not nominal FPS. The
exclusive end may equal the frame count. Timestamp-only cuts apply to frames
whose presentation timestamps lie in `[from,to)`. A positive frame offset finds
the first sample at or after the timestamp, then advances by that many samples.
Offsets can cross contiguous shards in the same clock epoch, but not gaps,
ambiguous overlaps, or clock discontinuities. The initial search window is 120
seconds; unavailable footage is an error, not permission to guess. `--epoch UUID`
disambiguates overlapping clock epochs. Camera time cannot be used if absent.

Local and S3 stores have independent shard IDs and boundaries. File-based
propagation translates source frames through their common canonical clock epoch,
then intersects that interval with each explicitly selected store's shards.
Different epochs are never guessed to be equivalent. A target store with no
matching footage rejects the batch before application. Partial coverage is
reported in the job's `gaps`, in the selected timeline; no tags are fabricated
for those gaps. Timestamp ranges can deliberately span distinct nonoverlapping
epochs. Overlapping timestamp ranges require an epoch or shard selector.

Timestamp-only S3 edits use the private playback journal: no bucket listing,
media download, media upload, or delete permission is required. Exact S3 frame
addressing may download the referenced object and inspect compressed samples in
RAM. It first uses saved credentials; if those cannot read, rerun with
`--read-credentials` to enter temporary GetObject credentials. Use
`--encryption-password` for an older metadata/media password. These inputs are
never saved. The object's manifest size, SHA-256, and embedded identity must
match. No decrypted remote media is written to disk.

## JSON batches and IPC

`hbnvr media tag apply edits.json` or `hbnvr media tag apply -` accepts:

```json
{
  "jobID": "11111111-1111-4111-8111-111111111111",
  "storeIDs": ["22222222-2222-4222-8222-222222222222"],
  "edits": [
    {
      "selection": {
        "cameraID": "33333333-3333-4333-8333-333333333333",
        "timeline": "canonical",
        "start": {"timestamp": 1790026200, "frameOffset": 12},
        "end": {"timestamp": 1790026200, "frameOffset": 30}
      },
      "key": "recognition.person.alice",
      "value": "present"
    }
  ],
  "dryRun": true
}
```

Omit `value` to remove a key. Omitted `frameOffset` defaults to zero, `timeline`
to canonical, and `dryRun`/`inspect` to false. For file selection replace the
time selector with `{"file":"/absolute/path","startFrame":120,"endFrame":360}`;
for shard selection use `sourceStoreID` plus `shardID`. Use `allFrames:true`
instead of frame boundaries for a whole file/shard. Optional `expectedRevisions`
maps `STORE_UUID/SHARD_UUID` to inspection's revision. Unknown revision targets
are rejected, not ignored. Edits apply in list order; later edits win for the
same key over overlapping intervals. Validation and staging finish before any
application begins. A batch for one shard is a single rewrite/revision.

Control protocol v1 operations:

- `media.tags.start`: `historicalTags` holds the JSON request. Optional
  `nvrInstanceID` must match. Optional `repairCredentials` and `repairPassword`
  carry ephemeral read/decryption inputs using the existing repair types.
- `media.tags.poll`: `tagJobID`; reply `tagJob` contains `state`, `message`,
  per-shard `results` and `gaps`. Failed jobs include an error and any already
  committed results. States: preparing, applying, completed, failed.
- `media.tags.read`: completed inspection `tagJobID` plus `tagOffset` byte offset;
  reply `tagData` is a base64 chunk of at most 32 KiB. A short chunk ends the
  JSON inspection document. The CLI assembles these automatically.

Jobs are bound to the authorized requesting UID. Only one editor runs at once;
the last eight job statuses/inspection outputs remain available until restart.
Reusing a job UUID with the same request returns its prior status; a different
request with that UUID is rejected. Use a new UUID for a corrected failed job.
Disconnecting the CLI does not cancel an accepted job. `preparing` is not a
durability promise: restart may discard uncommitted preparation. Inspect durable
metadata before retrying an uncertain job after restart. Applied overrides are
idempotent, including explicit removals. No persistent job contains credentials.

## Publication and recovery

Local manifest schema 4 adds `tag_edits`, a short-lived durable replacement
intent. Copies are staged alongside existing **plaintext local** MP4s with the
same daemon ownership, 0600 mode, and inherited access policy. Original sample
bytes and offsets are preserved; only the trailing private UUID tag box changes.
After staging and syncing, the manifest commits the intended replacements, files
are atomically renamed, and index identity/tag values are updated. Readers already
holding an old descriptor can finish that revision; an old manifest snapshot may
temporarily report unavailable until refreshed. Startup/maintenance rolls pending
intents forward across either side of rename. Unexpected file identities are
preserved for operator inspection. Staging before a committed intent can leave
an orphan `.hbnvr-tags-*.tmp` after a crash; it is never adopted as footage or
automatically deleted. A failed commit similarly preserves recovery files.

Each local camera-index batch has a durable intent; S3 store batches use an
encrypted-as-needed `.tag-edit` journal before replacing private shard records.
Those intents survive restart and roll forward. Multiple stores/camera indexes
are **not** one distributed transaction: a later failure leaves earlier commits
intact, and job results distinguish completed stores from merely prepared ones.
Recording and control continue while the editor stages files or inspects media;
only the short commit runs on each recording worker.

S3 video and thumbnail objects are never replaced for an edit. Their embedded
tags remain the creation-time snapshot. The authoritative manifest `tagMetadata`
is replaced, and `tagRevision` changes. Playback lookup must use the whole current
manifest timeline, not merge old embedded values back into it. Current-day daily
and affected closed-day daily/monthly publications use the existing serialized
publisher, respecting forced spooling and network backoff. `s3-queued` means
durably accepted, not already delivered. Older in-flight manifest uploads cannot
clear newly dirtied revisions. Original upload replay and repair must preserve
edited records. Loss of both private journals and cloud manifests loses historical
edits; unchanged media can recover only original tags. Never rebuild over a newer
cloud manifest without first preserving those annotations.

Tag timeline version 2 retains version 1 `changes`/`unknownFromTicks` and adds
finite `overrides`: `{start,end,key,value?}` in shard timescale ticks. An omitted
value is a tombstone (known absence), not a request to fall back. Per-key spans
are coalesced and split on overlap. Legacy unknown base state remains unknown:
`state(at:)` exposes known values, known absences, and `complete:false`; it does
not invent a complete empty dictionary. A missing timeline is likewise unknown.
Encrypted recordings keep edited timelines encrypted in private journals and
public manifests, even if encryption has since been disabled for new footage.

Local history IPC can serve effective segment tag maps as of 0.22.0; see
[the opt-in wire contract](MEDIA-PROTOCOL.md#segment-tag-maps-0220). This public
projection treats unknown and absent as no value, without exposing tombstones.
No Homebase/GUI tag interpretation is added. Future S3 consumers must refresh manifests for edits, including consulting
them at a JPEG's actual sampled timestamp before tag-dependent thumbnail display.
Current GUI thumbnails bypass manifests and current playback ignores tags.
Already-buffered/downloaded media does not instantly acquire new annotations.

## Bounds and smoke checks

- One active job; at most 8 stores, 64 edits, 64 resolved shards, 64 reported gaps.
- IPC requests: 64 KiB; CLI batch input: 60,000 bytes. Time ranges: at most 24h.
- Tag timelines: 4096 base changes, 4096 coalesced override spans, 512 KiB JSON;
  effective dictionaries retain the existing 32-key / 8192-byte limits.
- Exact-frame inspection: at most 1,000,000 frames per file, 2,000,000 retained
  frame timestamps per job; S3 objects up to 256 MiB / 512 MiB total downloads.
- Local staging: at most 512 MiB original file bytes per job, with room for each
  replacement plus a 64 MiB reserve on the **actual local store volume**.
- Preparation/inspection checks a five-minute deadline; remote asset inspection
  is capped at 30 seconds. Inspection JSON is capped at 16 MiB. Oversized or
  unsupported edits fail explicitly; recording tags are never silently truncated
  to accommodate a historical edit.

Build/test without installing or touching real cameras:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project HomeBase-NVR.xcodeproj -scheme HomeBase-NVR -configuration Debug \
  -derivedDataPath /tmp/hbnvr-build -destination 'platform=macOS' test
python3 scripts/integration.py /tmp/hbnvr-build/Build/Products/Debug/hbnvr
```

On an intentionally selected recording: inspect; save its revision; dry-run a
small interval; apply with the expected revision; inspect again; retry the same
edit and verify `changed:false`; confirm `camera tag list` is unchanged. For S3,
confirm the media key/hash/size are unchanged and wait for manifest publication.
Installation and commits remain separate user-directed actions.
