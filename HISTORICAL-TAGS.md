# Footage tags

Tags belong to footage. A request identifies a time interval from a camera, and
the NVR applies the annotation to every available Local and S3 copy of that
footage. Stores and recording boundaries are persistence details, not tag owners.
A camera UUID identifies the source of footage; editing it does not change camera
configuration, future frames, watch status, or recording intent. `camera tag`
remains the separate prospective default for arriving frames.

Keys and values are opaque, case-sensitive strings. These descriptive annotations
are not authorization rules: readers with S3 credentials/passwords can still read
original objects directly.

## CLI

Commands use the authenticated control socket without sudo. Add `--runtime-dir
PATH` for an isolated agent. There is no destination store option or store picker.
`--store`, JSON `storeIDs`, and public revision selectors are rejected. A file or
source shard can locate footage as a convenience; it does not restrict which
copies receive the annotation.

```sh
# Time-based addressing needs no recording filename or storage identity.
hbnvr media tag set --camera 'Bedroom Camera' \
  --timeline canonical --from '2026-10-25T14:30:00-07:00' \
  --to '2026-10-25T14:31:00-07:00' --key recognition.person.alice --value present

# Actual frame offsets from timestamps, not nominal-FPS calculations.
hbnvr media tag set --camera 'Bedroom Camera' \
  --from '2026-10-25T14:30:00-07:00' --from-frame 12 \
  --to '2026-10-25T14:30:00-07:00' --to-frame 30 \
  --key example.note --value detected

# Source-file convenience: zero-based frames 120 through 359, end EXCLUSIVE.
hbnvr media tag set --file '/absolute/managed/camera/recording.mp4' \
  --frames 120:360 --key recognition.person.alice --value present

# A source-store reference only locates the shard used for coordinates.
hbnvr media tag remove --source-store 'S3 recordings' --shard SHARD_UUID \
  --all-frames --key recognition.person.alice

hbnvr media tag inspect --file '/absolute/managed/camera/recording.mp4' --all-frames
hbnvr media tag status JOB_UUID
```

`--value ''` sets an empty string. `remove` makes a key absent only within the
selected interval; other keys and frames outside it retain their prior state.
Use `--dry-run` to validate and inspect proposed changes without writing them.
Camera UUIDs continue to address retained footage after camera removal.

Accepted footage can be edited while recording, after local finalization, while
queued/spooled/uploading to S3, and after cloud delivery. Clients do not wait for
finalization or discover recording boundaries. Edits are finite: future frames
keep their prospective tags. The recorder follows selected footage through
rollover or upload completion between inspection and commit.

Managed-file selectors reject arbitrary MP4s and symlinks. Use the configured
physical recording path without `.` or `..` components. A shard selector retains
`sourceStoreID` solely to identify its source coordinates.

## Frame and time semantics

`canonical` (default), `received`, and `camera` timelines use fractional Unix
seconds. Camera time is unavailable when the camera supplied no clock. `--epoch
UUID` disambiguates overlapping clock epochs and is independent of file boundaries.

Timestamp-only cuts affect frames with presentation timestamps in `[from,to)`.
Positive frame offsets find the first actual sample at or after the timestamp,
then advance by the requested sample count. Offsets can cross contiguous
recordings in one clock epoch, but never gaps, ambiguous overlaps, or clock
resets. The initial search window is 120 seconds. A file/shard's exclusive frame
end may equal its actual sample count. Missing exact sample indexes produce an
error rather than a nominal-FPS estimate; timestamp-only editing stays available.

The NVR translates convenience selectors into canonical source time and applies
them to every matching copy. Local and S3 copies may have different recording IDs
and boundaries. A store with no matching footage needs no write. A selection with
no available footage fails; partial footage coverage appears in `gaps`, in the
selected timeline. Different clock epochs are never guessed to be equivalent.
Timestamp intervals may deliberately span distinct nonoverlapping epochs.

Older recordings can have overlapping estimated final durations. The NVR resolves
an overlap at the next recording's first sample only after verifying the same
epoch, clock rate, source, RTP/UTC mapping, actual sample indexes, and the previous
writer's extrapolated end. The earlier recording must have no sample at or after
the boundary. Duplicate/interleaved samples, inconsistent clocks, and overlapping
distinct epochs remain ambiguous. Older MP4 timescale rounding is accounted for;
a sample whose uncertainty could reach the next recording is rejected.

Coverage is half open: a range beginning at the next recording's start excludes
the prior recording's empty estimated tail. Inspection does not rewrite media
durations or timing indexes. New recordings preserve source-clock precision and
use the next actual RTP interval at ordinary rollover. Shutdown or discontinuity
can still require estimating the last duration; active edits cover only already
accepted sample positions.

Timestamp-only S3 edits use local metadata and require no listing, media download,
media upload, or delete permission. Exact-frame selection or an older ambiguous
overlap may need to read compressed samples in RAM. Saved credentials are used
first; `--read-credentials` supplies temporary GetObject credentials and
`--encryption-password` supplies an older media/metadata password. Neither is
saved. Manifest size, SHA-256, and embedded identity must match. Decrypted remote
media is never written to disk.

## JSON batches and IPC

`hbnvr media tag apply edits.json` or `hbnvr media tag apply -` accepts:

```json
{
  "jobID": "11111111-1111-4111-8111-111111111111",
  "edits": [
    {
      "selection": {
        "cameraID": "33333333-3333-4333-8333-333333333333",
        "timeline": "canonical",
        "start": {"timestamp": 1792963800, "frameOffset": 0},
        "end": {"timestamp": 1792963860, "frameOffset": 0}
      },
      "key": "recognition.person.alice",
      "value": "present"
    }
  ],
  "dryRun": true
}
```

Omit `value` to remove a key. Defaults are `frameOffset:0`, `timeline:"canonical"`,
and `dryRun:false`/`inspect:false`. File selection uses
`{"file":"/absolute/path","startFrame":120,"endFrame":360}`; shard selection uses
`sourceStoreID` plus `shardID`. `allFrames:true` replaces explicit frame boundaries.
There is no destination store list or public expected-revision map. Obsolete and
unknown request fields are rejected. Edits apply in list order; later overlapping
edits for the same key win. Validation/preparation precede application.

Inspection returns normalized spans with `cameraID`, `timeline`, `epochID`,
`start`, `end`, and effective `tags`. Tag state has `values`, `knownAbsent`, and
`complete`; absent legacy metadata stays explicitly unknown. Public results use
footage time spans and `changed`, without destination store IDs, shard IDs,
publication states, or revision tokens.

Control protocol v1 operations:

- `media.tags.start`: `historicalTags` holds the request. Optional `nvrInstanceID`
  must match. Optional `repairCredentials`/`repairPassword` carry ephemeral inputs.
- `media.tags.poll`: `tagJobID`; reply `tagJob` includes `state`, `message`, footage
  `results`, and `gaps`. Failed jobs report an error; some copies may already be
  committed, so inspect the footage range before retrying. States are preparing,
  applying, completed, and failed.
- `media.tags.read`: completed inspection `tagJobID` plus `tagOffset`; `tagData` is
  a base64 chunk of at most 32 KiB. A short chunk ends the JSON document. The CLI
  assembles these automatically.

Jobs belong to the authorized requesting UID. One editor runs at a time; the last
eight statuses/inspection outputs survive until restart. Reusing a job UUID with
the same request returns prior status; a different request is rejected. Use a new
UUID for a corrected failed job. Disconnecting does not cancel accepted work.
Uncommitted preparation may be lost on restart. Inspect before retrying an
uncertain job; finite overrides, including removals, are idempotent. Persistent
metadata never includes ephemeral credentials.

## Persistence and publication

Active writers apply overrides on their recording queue. Local checkpoints and
live playback metadata reflect the edit; normal finalization includes it in the
completed file. S3 RAM recordings include it in the finalized encrypted-as-needed
media and upload descriptor. Active footage and its tags retain the recorder's
existing durability guarantees.

Queued or in-flight S3 edits persist effective tags in the existing spool before
acknowledgment, without replacing video bytes, key, hash, or upload destination.
Completion uses current effective metadata instead of the old transport snapshot.
Restart/replay retains the edited revision. Pending footage is not advertised as
playable cloud media until successful upload delivery.

Finalized local plaintext MP4 edits preserve sample bytes and offsets, replacing
only the trailing private tag box. Staged files retain daemon ownership, mode,
and access policy. Manifest schema 4's `tag_edits` intent persists before atomic
replacement and index updates. Startup/maintenance rolls committed intents
forward; unexpected identities and uncommitted orphan staging files are retained
for operator inspection. Existing readers can finish their old revision.

Confirmed S3 edits use the encrypted-as-needed `.tag-edit` journal before replacing
private playback records. Video and thumbnail objects remain unchanged; their
embedded tags are the finalization-time snapshot. The current manifest's complete
`tagMetadata` and `tagRevision` are authoritative. Readers must not merge older
embedded values back in. Existing serialized manifest publication handles daily
and monthly updates, forced spooling, and network backoff. Older callbacks cannot
clear a newer revision, and original upload replay/repair preserves edits.

A completed job means the local metadata change was accepted; cloud publication
follows the existing delivery process. Multiple storage copies are not a single
distributed transaction: a later failure retains earlier commits. A failed job
does not claim successful coverage; inspect the range to establish its state. Losing both private journals and cloud manifests
loses post-finalization edits; unchanged objects recover only their embedded tags.

Timeline version 2 retains base changes and adds finite `{start,end,key,value?}`
overrides in internal recording ticks. Missing `value` is a known-absence tombstone.
Per-key spans coalesce and split on overlap. Unknown legacy base state remains
unknown. Encrypted footage keeps edited tag values encrypted in spool metadata,
private journals, and public manifests even after encryption is disabled for new
footage.

Local IPC serves effective [segment tag maps](MEDIA-PROTOCOL.md#segment-tag-maps-0220).
Existing Homebase/GUI behavior is unchanged: current GUI thumbnails bypass manifests
and playback ignores tags. S3 consumers must refresh manifests, including checking
a thumbnail's actual sample timestamp before tag-dependent display. Already
buffered/downloaded media does not instantly acquire new annotations.

## Bounds and checks

- One active job; at most 64 edits, 64 internal recording segments, 64 reported gaps.
- IPC request limit 64 KiB; CLI batch limit 60,000 bytes; time ranges at most 24h.
- Tag timelines: 4096 base changes, 4096 override spans, 512 KiB JSON; effective
  dictionaries remain bounded to 32 keys and 8192 bytes.
- Exact-frame inspection: 1,000,000 frames per file and 2,000,000 retained frame
  timestamps per job; remote objects at most 256 MiB, 512 MiB total downloaded.
- Local staging: 512 MiB original bytes per job plus room for each replacement
  and a 64 MiB reserve on the actual recording volume.
- Preparation/inspection deadline: five minutes; remote inspection: 30 seconds;
  inspection JSON: 16 MiB. Oversized edits fail instead of truncating tags.

Build and test without installing or accessing real cameras:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project HomeBase-NVR.xcodeproj -scheme HomeBase-NVR -configuration Debug \
  -derivedDataPath /tmp/hbnvr-build -destination 'platform=macOS' test
python3 scripts/integration.py /tmp/hbnvr-build/Build/Products/Debug/hbnvr
```

For disposable footage: inspect, dry-run, apply, inspect the normalized spans,
repeat and verify `changed:false`, and confirm prospective camera tags are
unchanged. Exercise active footage, rollover, pending S3 uploads, and restart.
Forced spooling exercises pending metadata without contacting a bucket. After
finalization, S3 edits must preserve the video key/hash/size; updated manifests
become available through normal delivery. Installation and commits remain
separate user-directed actions.
