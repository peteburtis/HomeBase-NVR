# S3 stores (0.18.0)

As of 0.21.0, [historical tags](HISTORICAL-TAGS.md) can update authoritative
manifest tag timelines without rewriting or re-uploading MP4/JPEG objects.
Embedded media tags remain the original snapshot; manifest edits take precedence.
Ordinary timestamp edits need no media reads. Exact frame addressing can use
temporary GetObject credentials and RAM-only inspection. Live tags are unchanged.

Use `hbnvr store add`, choose **S3**, and follow the same name/options/confirmation
workflow as a local store. `change`, `list`, `enable`, `disable`, and `remove` accept
names or UUIDs and `--runtime-dir` for isolated foreground agents. No sudo is needed.

## Manual spooling and advanced editing

```sh
hbnvr store spool "S3 recordings" --on
hbnvr store spool "S3 recordings" --off
hbnvr store spool --on                    # interactive store picker
hbnvr store change "S3 recordings" --advanced
hbnvr store change --advanced             # interactive store picker
```

`spool --on` persists `S3.Advanced.ForceSpooling: true` and queues application on
the store's worker. Completed shards go to its disk spool; new live uploads, replay,
retries, and recovery probes are held. Already-active requests may finish. Recording
continues until quota/free-space or another safety constraint suspends that store.
The setting survives restarts and does not change camera or store enablement.
Check status for the `manual` spooling reason; no next probe is scheduled while held.

`spool --off` clears only this manual hold. Normal bounded backlog draining resumes,
or an immediate controlled probe is permitted if upload errors still require recovery.
Pressure, storage failures, and shutdown are not overridden. This is not an OS-wide
network switch: in-flight operations and explicit setup validation can still contact AWS.
These commands authenticate through normal IPC, need no AWS validation, and are
idempotent. Omit the name for the usual terminal picker (including with `--off`).

`store change --advanced` retains the common editor and additionally shows **every
Advanced field**, with its current value, units, and constraints: concurrency/live slots,
failure thresholds/window, retry/probe/request times, RAM queue pressure thresholds,
spool quota/free-space reserve/directory, and forced spooling. Enter keeps the current
value; durations accept seconds or interval text such as `2m`; sizes are integer bytes.
Use `default` for SpoolDirectory to return to the built-in location. Local stores have
no hidden advanced tuning fields. Identity/ownership/type and recording destinations
remain fixed; secrets are replaced explicitly, never displayed or prefilled.

An edit limited to Advanced settings saves without AWS validation, preserving private
credentials/encryption and the current shard. Concurrent edits are rejected rather than
overwritten. Other S3 changes still use the confirmed asynchronous validation workflow.
Changing spool location requires a **disabled, fully drained** store and a dedicated,
pre-created new directory. Both old and new locations must contain no pending/damaged
footage. The daemon switches an empty store in place; failures preserve the old store.

ForceSpooling requires store schema **4**; the CLI upgrades it automatically and keeps
that version after release. Older agents must reject it, never silently upload. Reinstall
the matching binary before using these commands; never lower the schema to bypass this.

## Destination and setup

V1 supports existing, never-versioned general-purpose AWS S3 buckets, with
bucket-default SSE-S3 (AES256) and S3 Standard uploads. Generated IAM ARNs follow
the selected commercial, China, or GovCloud partition. A bucket with
versioning Suspended is not a never-versioned bucket. No bucket creation, S3 Express,
KMS, general-purpose object retrieval, audio expansion, or local-store backfill is implemented.
The optional metadata-repair command below reads objects to rebuild S3 indexes and missing previews.

Setup asks for name, bucket, region, visible/editable prefix, optional 12-digit expected
owner account ID, shard duration (`1m`), retention (`1w`), and Managed/External
lifecycle (Managed by default). The prefix defaults to `hbnvr/<store UUID>/`.
Prefixes in the same bucket must not overlap, including disabled stores.
Bucket, region, prefix, and expected owner are fixed for a store identity. Relocation
requires remove/add. Changing a camera name never moves existing or pending objects.

Before requesting credentials, setup prints an IAM **identity policy** for a dedicated
IAM principal without console access. Generate an access key, not a console password.
The secret is entered with terminal echo disabled. The recorder uses only these
explicit credentials, never environment variables or another user's AWS profiles.

The policy grants:

- `s3:PutObject` and `s3:AbortMultipartUpload` on the exact prefix's objects.
- `s3:GetBucketVersioning` and `s3:GetEncryptionConfiguration` on the exact bucket.
- Managed only: `s3:GetLifecycleConfiguration` and `s3:PutLifecycleConfiguration`.

There is no GetObject, DeleteObject, ListBucket, CreateBucket, or bucket-policy editing.
**Lifecycle permissions can indirectly delete objects throughout the bucket.** AWS
does not scope lifecycle editing to one rule/prefix. A write-only key can overwrite
existing objects in its prefix; it is not immutable-storage or ransomware protection.

After confirmation, an authenticated daemon-side job checks compatibility and writes
a unique small setup object. Start/poll/cancel requests each retain the normal five-second
IPC deadline; AWS calls run separately. Jobs belong to the requesting UID/account UUID
and exact draft, reject intervening configuration changes, and expire after 15 minutes.
Ctrl-C during validation cancels without saving. A setup object may remain after an
interruption or cancellation; bucket lifecycle is responsible for its expiration.

Successful validation permits a separate configuration commit. Failed validation offers
**save disabled** or cancellation. Enabling a disabled S3 store validates again. Change
uses the same editor and preserves credentials unless explicitly replaced. Credentials
can be repaired with backlog present; the backlog's destination and bytes never change.

## Optional client-side password encryption

After AWS credentials, setup asks for a separate encryption password with terminal echo
disabled. Leave it blank to omit encryption; otherwise enter it twice. Use a strong,
unique password-manager-generated passphrase and back it up separately. There is no
password reset capable of recovering encrypted footage. This is **not** an IAM password,
SSE-C key, KMS setting, or AWS Encryption Client file format. SSE-S3 stays enabled as well.

The Swift AWS SDK has no supported S3 Encryption Client implementation. HBNVR uses
Apple's CommonCrypto PBKDF2-HMAC-SHA256 (600,000 iterations, fresh random 32-byte salt per
shard, 256-bit key) and CryptoKit AES-256-GCM (fresh 12-byte nonce, 16-byte tag). We do not
implement a password-derivation or cipher algorithm ourselves. See
[AWS's supported client languages](https://docs.aws.amazon.com/amazon-s3-encryption-client/latest/developerguide/programming-languages.html)
and [OWASP's PBKDF2 work-factor guidance](https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html#pbkdf2).

Complete MP4s and thumbnails are encrypted in RAM **before** entering the upload manager. Upload hashes,
checksums, retries, and spool contents refer to the exact ciphertext. No plaintext media
file is created by the S3 store. Encryption temporarily requires extra RAM for plaintext
and ciphertext; shard sizing must allow for this overhead. Local stores are unaffected
and continue to write plaintext MP4s. The nonsensitive setup marker remains plaintext.
Object keys (including camera names and capture times), object sizes, and upload timing
remain visible; this feature protects video contents, not metadata or immutable history.

The password is kept in the daemon-private store JSON (0600 in a 0700 directory) so
recording can resume unattended after boot. It is never sent to AWS or included in
list/status/edit summaries. This protects cloud-held footage, **not** against someone
who can read daemon memory/private configuration or compromise the Mac. Filesystem
permissions are not password encryption, and Swift/OS memory copies are not guaranteed
to be erased. Protect configuration backups accordingly.

`store change` offers keep, replace, or explicitly disable encryption. Changes apply at
the finalized-shard boundary. Existing and pending footage is never re-encrypted, and
replay needs neither the old nor new password because its ciphertext is already frozen.
Keep each old password for as long as recordings made with it must remain recoverable.
Omitting the settings from an older client's edit preserves the existing settings.
Encryption-aware clients use a distinct setup-start IPC operation: an older daemon
must reject it instead of silently ignoring encryption. Install the matching agent
before using the new S3 setup workflow.
Encrypted stores also use store `SchemaVersion: 2`; older daemons reject that version
rather than ignore the encryption setting after a binary downgrade. Local and legacy
unencrypted stores retain schema version 1. Do not lower an encrypted store's version.

### Offline recovery and portable format

Download using **separate read credentials**, then run:

```sh
hbnvr decrypt downloaded.mp4.hbnvr recovered.mp4
```

The hidden prompt accepts the original password. No running agent or AWS connection is
needed. One shard is held in RAM. The entire authentication tag is verified before any
plaintext is written; wrong passwords or damaged files create no output. The command
publishes a 0600 file without overwriting any existing file or symlink. Keep the encrypted
original. A recovered MP4 may then be opened in a video player.

The self-contained **HBNVR-PBE v1** envelope has no dependency on the store configuration,
spool manifest, object key, or original Mac. The binary format is:

| Byte range | Contents |
| --- | --- |
| 0–7 | ASCII `HBNVRE01` (magic and version) |
| 8–11 | Unsigned big-endian PBKDF2 iteration count, exactly 600000 in v1 |
| 12–43 | 32-byte random PBKDF2 salt |
| 44–55 | 12-byte AES-GCM nonce |
| 56 through length−17 | Encrypted content bytes (MP4, JPEG, or playback JSON) |
| Final 16 bytes | AES-GCM authentication tag |

Derive 32 bytes with PBKDF2-HMAC-SHA256 from the exact UTF-8 password (no normalization
or trimming). Authenticate the complete 56-byte header as GCM additional authenticated
data. The per-file overhead is 72 bytes; no padding is used. Passwords are 1–1024 UTF-8
bytes excluding NUL/newlines. Readers reject unknown versions and work factors before
derivation. The v1 AES-GCM plaintext limit is 2^36−32 bytes per shard. This documented
application envelope has interoperability tests against OpenSSL, not an external security
audit or AWS Encryption Client compatibility. Retain the format specification and a
working decrypt binary with long-term backups.

## S3 thumbnails (0.18.0)

Record one preview per camera at the **midpoint** of each UTC-aligned 20-minute tile:
`:10`, `:30`, and `:50`. Select the closest available keyframe at or before that point,
at most 120 seconds earlier. A recording that starts after the midpoint does not invent
a preview for it. Selection uses canonical recording time, not wall-clock arrival or
filename timestamps. Stream-epoch changes reset selection. Rendering runs off the
recording queue, retaining only the latest compressed keyframe and a bounded render
queue; there is no additional multi-minute buffer or normal-path image file.

JPEGs fit within **1280×720**, preserve aspect ratio, never upscale, and use **80% quality**.
The predictable key below the configured store prefix is:

```
.hbnvr/playback/v1/<lowercase camera UUID>/thumbnails/YYYY-MM-DD/HH-mm.jpg.hbnvr
```

Dates/minutes are UTC canonical midpoint times. Unencrypted stores use `.jpg` instead.
The image's IPTC caption contains JSON: `format: "hbnvr-s3-thumbnail"`, `version: 1`,
`storeID`, `cameraID`, `slot` (midpoint Unix seconds), and `timestamp` (actual keyframe
Unix seconds). For encrypted stores the **whole JPEG**, caption included, uses the same
authenticated HBNVR-PBE envelope and password as new recordings. Object existence,
keys, size, and timing remain visible. Old images retain their original encryption;
repair does not replace an existing plaintext or encrypted thumbnail name.

A ready JPEG immediately enters the **same frozen-object upload pool as video shards**;
it never waits for the containing shard to close or upload. Both kinds share concurrency,
checksums, serial error retries, spooling policy, manual hold, target-volume free-space
reserve, quota, restart replay, and confirmed-delivery-only deletion. Pending live video
gets scheduling priority. Repair images use background slots, preserving the live slot.
There is no second upload loop, cache directory, or thumbnail spool. Unconfirmed images
are durably spooled on graceful shutdown. Quota exhaustion preserves accepted work and
suspends new recording to that S3 store, just as for video. Failed image *generation*
warns without stopping video; explicit repair can regenerate the missing preview.

Upload/spool counters include both object kinds; completed **shards** still counts video.
Status separately reports `pendingThumbnails` and `thumbnailWarning`. Spool metadata
schema 2 identifies `thumbnail.jpg[.hbnvr]`; existing schema-1 video spool entries retain
their format. Drain thumbnail work before downgrading to an older agent, which cannot
replay schema-2 entries. Thumbnails do not create video manifest coverage. An image can
exist before its video uploads, or after that video expires; it is not proof of playable
footage. Lifecycle covers this same prefix and expires images by upload age, including
late repair uploads. The normal writer IAM policy is unchanged; readers need only
GetObject on the prefix. GUI retrieval of these objects is a separate client change.

## Explicit metadata repair (0.18.0)

```sh
hbnvr store repair-metadata "S3 recordings" --dry-run
hbnvr store repair-metadata "S3 recordings"
hbnvr store repair-metadata                 # interactive picker
# Add --runtime-dir PATH for an isolated foreground agent.
```

This is an opt-in reconstruction of playback metadata, not video repair, migration,
or object cleanup. It works while the store records or is disabled. Install the
matching CLI and agent. The selected store must be operational enough to open its
private spool/journal; repair does not bypass an existing storage error.

1. List only the store's configured bucket/prefix using the saved recorder credentials.
   If S3 denies access, print an IAM policy for `s3:ListBucket` on the exact bucket,
   conditioned on the exact requested prefix, and `s3:GetObject` within that prefix.
   Prompt for temporary access key, hidden secret, and optional hidden session token.
   These credentials are used only for reading, stay in agent RAM, and never replace
   saved writer keys. A network failure stops repair instead of requesting more privilege.
   An expected-owner or bucket-policy denial can also produce the credential prompt;
   check those settings rather than repeatedly supplying keys.
2. Match HBNVR shard names to **currently configured camera UUIDs**. Display names may
   have changed. Ignore manifest/setup objects, other cameras, unknown layouts, and
   oversized files. Preserve pending uploads. After all listing pages are read, skip
   already journaled video unless a midpoint thumbnail is missing. Preserve every
   existing recognized thumbnail name without downloading or overwriting it, even
   if its contents are unreadable. Unknown image objects are also left untouched.
   Preview candidate count and maximum initial download bytes, then ask for confirmation.
   `--dry-run` stops here: it does not download, decrypt, or certify recoverability.
3. Read one whole object at a time with its listed ETag as an If-Match condition.
   Authenticate encrypted envelopes using the configured password. If necessary, ask
   for an old password or offer to skip unreadable encrypted objects. A corrupt
   encrypted envelope can be indistinguishable from a wrong password. No plaintext
   media is written to disk. Network traffic, S3 requests, and CPU work may incur costs.
4. Validate embedded timing, store/camera/shard identities, H.264/H.265 sample timestamps,
   keyframe start, and the existing no-B-frame constraint. Recover all recorded timeline
   anchors, canonical source, duration from sample timings, exact key, size, and SHA-256
   of the original stored bytes. Never infer duration from file size or adjacent names.
   Missing/unsupported timing, legacy files, changed objects, and invalid media are
   skipped. **All footage and unexpected objects remain untouched**, including skipped
   objects. Repair creates no quarantine or deletion state.
5. Merge each recovered entry durably on the existing store queue, sharing the normal
   serialized daily/monthly/catalog publisher with live uploads. Existing or pending
   recording metadata wins. Only expected playback manifest keys are rewritten, using
   saved writer credentials and the current manifest encryption password. Final
   publication also refreshes already journaled entries for currently configured cameras.
   Completion means a durable merge and queued publication, not confirmed cloud delivery;
   check the separate playback warning/pending count in `hbnvr status`.
   A scan that recovers nothing explicitly reports no new metadata/thumbnails;
   existing journal entries may still be republished.
6. For missing midpoint previews, reuse the downloaded object, decode only the preceding
   keyframes, and submit completed JPEGs to the same upload/spool pool as recordings.
   Use current store encryption and saved writer credentials, never the temporary reader
   principal for PUTs. This also works when the video's manifest entry already exists.
   The preview estimate includes indexed files needing images; no extra download of
   the same video is needed for thumbnail generation during that attempt.

Re-running is safe and skips indexed work with all expected thumbnails present or pending.
In 0.18.1, download diagnostics distinguish `notFound` (HTTP 404),
`preconditionFailed` (HTTP 412), `sizeMismatch`, `etagMissing`, and `etagMismatch`.
The last three mean GET returned HTTP 200 but failed validation. CLI progress and
daemon logs retain the first three examples of each reason (at most 15 per job),
with exact skip totals at completion. Examples identify the candidate number and
shard UUID, list expected/received bytes and Content-Length, and summarize ETags
by length, quoting, and a truncated SHA-256 fingerprint. No raw ETag, object path,
request/response body, credential, or password is logged. Diagnostic samples stay
in the existing expiring job state; no extra on-disk diagnostic file is created.
This instrumentation does not relax validation or change which videos are skipped.

### S3 key representation (0.18.2 audit)

Object keys and prefixes are raw Unicode strings in configuration, IAM resources,
lifecycle rules, spool sidecars, playback journals/manifests, thumbnails, and Homebase
discovery metadata. They are not URLs and must not be percent-decoded or form-decoded.
SDK requests encode these strings for the wire; the restricted repair/GUI HTTP adapters
preserve the SDK's already-encoded path and query rather than encoding them again.
Pagination tokens are opaque strings, also left unchanged before SDK request encoding.

The exception is `ListObjectsV2` with `EncodingType=url`: decode returned object keys
once, replacing bare `+` with space **before** percent decoding. Thus `Room+Camera`
becomes `Room Camera`, `%2B` remains a literal plus, and `%2520` remains literal `%20`.
Earlier repair versions interpreted space-as-plus as a different key, producing false
HTTP 404 skips for normal camera-name folders. Version 0.18.2 corrects only this LIST
boundary; existing uploads and objects do not need renaming. Synthetic SDK regressions
cover LIST-to-GET, prefixes/pagination, multipart completion/abort, spool replay, manifest
journaling/publication, and lifecycle XML. The GUI's raw-key GET path and Homebase's
metadata forwarding require no runtime changes.

Ctrl-C cancels remaining reads/merges, but already accepted metadata and thumbnails
remain and can still publish. Active jobs block store edits,
enable/disable, spooling changes, and removal; they do not stop recording. Jobs are
bound to the initiating UID/account UUID and expire after 15 minutes without a client
poll. IPC remains responsive while listing/downloading. Removing a camera during repair
prevents subsequent merges for that camera.

Limits: 256 MiB per object, one in-memory object at a time (plus decryption/AVFoundation
overhead), 100,000 candidates, and 10,000 listing pages per run. Requests time out after
60 seconds; transient failures leave accepted work intact for a rerun, not an automatic
retry storm. Password retries can download a file again, exceeding the preview estimate.
Corrupt local journal records are preserved and must be resolved separately; repair
will not publish an incomplete journal over a cloud index. Deleted/unrecoverable timing
cannot be recreated. This command does not rebuild local SQLite manifests.

## Playback manifests (0.16.0)

Normal recording maintains a **prospective index** of confirmed uploads. Previously
uploaded objects are never automatically enumerated or guessed from their names.
Version 0.18.0 extends the explicit repair workflow above to missing thumbnails as well.
Normal recording still needs neither `ListBucket` nor `GetObject`; phone playback
needs `GetObject` but no listing. Repair does not add deletion permissions.

The authenticated NVR catalog adds optional `playbackManifestVersion: 1` to its S3
destination, forwarded unchanged by Homebase. Old servers omit it. The stable keys
below the store's exact configured prefix are:

```
.hbnvr/playback/v1/<lowercase camera UUID>/catalog.json
.hbnvr/playback/v1/<lowercase camera UUID>/days/YYYY-MM-DD.json
.hbnvr/playback/v1/<lowercase camera UUID>/months/YYYY-MM.json
```

Dates/periods use UTC, not the camera's display time zone. `.json` remains the suffix
even for encrypted objects: inspect the `HBNVRE01` envelope magic. If store encryption
is enabled, the complete JSON is protected by the same `hbnvr-pbe-v1` envelope as
video. A password change republishes retained indexes under the new password; old
video remains encrypted under its original password. Retain those old passwords.

Every JSON document has `format: "hbnvr-s3-playback"`, `schemaVersion: 1`, `storeID`,
`cameraID`, and `generatedAt` (Unix seconds). A catalog has `days`, each containing
`day`, `start`, and `end`; bounds are the canonical union's outer limits for that
day, **not a promise of continuous video**. A day/month document has `period` and
`shards`. Each shard contains:

- `id`, exact object `key`, uploaded `size`, lowercase hexadecimal `sha256`;
- optional `encryption` (`hbnvr-pbe-v1`), describing the frozen object itself;
- `timing`, the same versioned `ShardTimingMetadata` embedded in its MP4;
- `endTicks`, the exclusive sample-zero-relative end at `timing.timescale`.

For a selected timeline, frame time is that timeline's anchor plus sample ticks
divided by the timescale. Object hashes cover ciphertext when encrypted. Each shard
is listed in **every canonical UTC day it intersects**; readers deduplicate by shard
ID. Monthly manifests contain full entries for closed UTC days, excluding today.
Today uses its daily manifest. Late recovery updates its affected capture day(s),
calendar month(s), and camera catalog; it does not rewrite intervening months.
An ordinary shard affects one day/month; a boundary-crossing shard can affect both.
Midnight closes the prior day even if no new shard arrives. Camera renaming changes
future video keys but never index keys or pending entries' frozen video keys.

The upload manager journals timing/key/hash metadata durably **before dropping the
last local metadata copy of a confirmed upload**. The journal is daemon-private,
0700 directories and 0600 records, at
`/Library/Application Support/HomeBase-NVR/private/playback/<store UUID>` in system
mode or `<runtime-dir>/playback/<store UUID>` locally. It is deliberately independent
of the configurable external spool. No media or AWS/encryption secrets live in it.
Metadata records are retained; they are not an object-expiration authority.

One serialized manifest publisher per store snapshots a finite round of revisions,
uploads period objects first, then the matching catalog. Incoming completions join
the next round, preventing a busy recorder from starving catalog publication. Old
acknowledgments cannot clear newer dirty revisions. Retries use a 60-second delay;
they never read cloud indexes or interfere with recording/upload-error spooling.
Restart reconstructs dirty indexes from the durable journal and republishes them.
This renews **manifest object** age under S3 lifecycle, not recording object age.

Manifest cloud failures report `playbackWarning` separately from upload and retention
warnings; recording continues. A journal read/write/sync failure retains the completed
recording in RAM or spool and retries persistence, rather than losing its only index
information. Corrupt metadata is preserved and blocks rewriting an incomplete cloud
index. RAM-only unjournaled work does not count as safe shutdown. Disabled stores drain
indexes; removal refuses while publications remain pending. Shutdown does not wait
for manifest network success because journal records already support restart replay.
Uninstall preserves this private state. Deleting it loses searchable earlier cloud
history; deleting video objects does not repair or rewrite the metadata automatically.

Manifests can refer to expired or manually removed objects: expiration is asynchronous
and controlled only by S3. A reader must handle missing/unreadable recordings explicitly.
Without `ListBucket`, S3 can return 403 for a missing key; it is not proof of bad keys or
proof of no video. No automatic cloud deletion or index reconstruction is introduced.
Full monthly documents can reach tens of MiB with continuous minute shards. The GUI
reader's bounded fetch limit applies to unusually dense/large indexes; shorter shard
durations may exceed that limit. S3 thumbnail publication is described above; it does
not alter these video manifests or local thumbnail IPC.

## Retention authority

S3 Lifecycle is the only expiration mechanism. Retention must resolve to positive whole
days (`1w`, `1M`, `1y` are valid; months are 31 days and years 365 days). Expiration is
asynchronous and based on object creation/upload age, not capture age. Uploading old
backlog does not backdate its expiration clock.

Managed mode owns rule `hbnvr-<store UUID>` scoped to the visible prefix: object expiration
at the desired day count plus one-day incomplete-multipart cleanup. It reads, merges,
writes, and verifies while preserving unrelated rules and the transition-minimum-size
setting. Unknown lifecycle XML/settings cause a warning instead of an unsafe rewrite.
Transactions targeting the same bucket are serialized within this daemon; there is no
cross-administrator compare-and-swap protection. Reconciliation runs after committed
changes, at startup, and hourly. Access denial or verification failure is a separate
retention warning, **not** an upload failure or an assurance that retention was applied.

External mode makes no lifecycle API calls. Setup prints the corresponding lifecycle
JSON for an administrator to merge with the bucket's rules. Status says external/unverified.
Disabling or removing a store leaves cloud lifecycle rules intact, so existing objects
continue aging under the last applied policy.

## Video and scheduling

Each S3 store independently creates a self-contained fragmented MP4 in RAM using
AVAssetWriter segment output, passing through H.264/H.265 without transcoding. Shards
start on keyframes and rotate on the first keyframe at/after the requested duration.
No-B-frame profiles are required. Stream end, camera/store changes, and shutdown finalize
short but complete video. The normal upload path creates no temporary media files.

Object layout (UTC, with identity disambiguation):

```text
<chosen-prefix>/Living Room--<camera UUID>/2026-09-16T18-30-00.000Z_<shard UUID>.mp4
```

With client-side encryption, the suffix is `.mp4.hbnvr` and the content type is
`application/octet-stream`; without it, `video/mp4`. Multipart/PUT thresholds use the
final ciphertext size, including the envelope overhead.

Finalized bytes, key, and destination are frozen. RAM remains owned until a confirmed
upload or durable spool publication. Overlapping assembling/uploading shards are normal;
choose shard durations appropriate to available RAM. Status byte counts account for
encoded/retained data, not every AVFoundation/SDK allocation or total process RSS.

The per-store upload manager controls all first attempts, retries, probes, and replay:

| Setting | Default |
| --- | --- |
| Total upload slots | 5 |
| Reserved live-first-attempt slots | 1 (background uses at most 4) |
| Error-triggered retry concurrency | 1 |
| Shared retry delay | Exponential full jitter, capped at 30s |
| Transient breaker | 3 failures in 30s without a confirmed whole-shard success |
| Recovery probe | Oldest eligible durable shard every 60s, no overlapping probes |
| Pressure entry | Finalized residents > max(10, 2 × recording cameras), or oldest ready RAM shard > max(2m, 2 × shard duration), or OS memory pressure |
| Pressure exit | Below half the count limit, age clear, OS memory pressure normal |
| HTTP request deadline | 600s, including response consumption |

Confirmed network unavailability or store-wide authorization/destination errors spool
immediately. Structured error codes and operation context distinguish transient failures
from store-wide failures; **all upload errors remain retryable**, including shard-specific
S3 rejections. There is no permanent quarantine state or finite retry budget. Retries
and recovery probes remain paced; they do not hammer S3. A recovery cycle starts with
the oldest eligible shard, then rotates failed probes so other files can make progress.
Sanitized AWS error codes/status are retained per failed shard; another shard's success
does not erase that diagnostic. Lifecycle warnings never affect this breaker. The SDK's
own retry count is one attempt.

Uploads below 64 MiB use PUT; larger **already finalized** files use sequential multipart
parts within one upload slot (16 MiB parts, enlarged to stay under 10,000 parts). Checksums
are sent. Failed multipart attempts are best-effort aborted; abandoned parts rely on the
one-day lifecycle rule. Ambiguous acknowledgments retry the exact same key and bytes;
an existence error alone is never success. No object-read permission is needed.

Disk-backed PUTs use the SDK's incremental SHA-256 trailer together with its
AWS-chunked headers. RAM PUTs and multipart parts retain fixed-length bodies with
explicit SHA-256 headers. Version 0.7.4 corrects a disk-replay framing mismatch in
the SDK integration: supplying a precomputed checksum bypassed chunk-header setup
while the signer still chunked file streams, resulting in `MissingContentLength`
(HTTP 411). The fix keeps bounded disk reads, encryption, frozen keys/bytes, and
checksums; existing spool files need no changes. Tests now validate required framing
and the actual checksum trailer, rather than merely decoding a chunked body.
See [AWS's chunked-upload framing requirements](https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sigv4-streaming.html).

Spooling is a binary routing decision; pressure, upload-error, and shutdown reasons are
tracked independently. One confirmed recovery probe clears upload-error spooling, not
pressure/shutdown. Ordinary in-flight success does not clear an outstanding outage reason.
If disk persistence failed and there is no eligible durable file, the controlled probe may
use the oldest retained complete RAM shard. This avoids recovery deadlock.

After recovery, live first attempts outrank queued background work. Backlog replay uses
the remaining slots; failed replay joins the serial retry lane. Slots reserve concurrency,
not network bandwidth, and do not cancel active uploads.

## Private spool and durability

System: `/Library/Application Support/HomeBase-NVR/private/spool/<store ID>`.
Local: `<runtime-dir>/spool/<store ID>`. These are independent of local recording stores.
Directories are daemon-owned 0700; files 0600. Complete MP4s (or encrypted envelopes) have versioned manifests
containing identity, frozen destination/key, capture time, byte count, and SHA-256 hash.
Payload/manifest/directory syncs and atomic directory publication precede releasing RAM.
Restart verifies payload length/hash and can promote fully written staging transactions.
Payloads are `video.mp4` or `video.mp4.hbnvr`, according to the manifest's optional
encryption format. Both can coexist after changing settings; legacy plaintext spools
remain readable. Manifests contain no passwords or AWS credentials.

### Custom spool directory and external drives

Set `S3.Advanced.SpoolDirectory` in a store's private JSON to select its **exact**
spool directory (no additional store-ID folder is inserted). This is deliberately
not an ordinary setup question; `store change --advanced` also exposes it. Omitting
it preserves the default paths above.
For example, merge these fields into the existing store JSON, preserving everything else:

```json
{
  "SchemaVersion": 3,
  "S3": {
    "Advanced": {
      "SpoolDirectory": "/Volumes/Recordings/HBNVR-spool",
      "SpoolLimitBytes": 10737418240,
      "MinimumFreeBytes": 2147483648
    }
  }
}
```

Use an absolute path, not `~`. Custom spools require a writable, local **APFS or
HFS+ volume**. exFAT/FAT, network volumes, and read-only media remain unsupported;
encryption does not replace the spool's filesystem/durability requirements.

With **client-side encryption enabled**, volumes configured to **ignore ownership
are supported**. Leave that volume setting alone: no `enableOwnership` or `chown`
is required. Use a dedicated, existing directory the daemon can read, write, and
traverse. On these volumes HBNVR does not require a particular owner or exact mode;
it still requests `0700`/`0600` for new directories/files. Shards are encrypted before
publication. Passwords and AWS credentials remain in daemon-private configuration,
never in the external spool. Unencrypted metadata (including object keys, camera
names, timestamps, and sizes) can be visible to others; encrypted files may be copied,
modified, or deleted by other local users. Encryption protects video confidentiality,
not access control or availability. The existing content hash detects damage, not
malicious changes to both payload and metadata; replay does not decrypt old shards.

Plaintext spools still require ownership enforcement. On ownership-enabled volumes
(including encrypted stores), create a directory owned by `_hbnvr:_hbnvr` with mode
`0700` (your current UID in local-agent mode); files remain `0600`. Allow the daemon
to traverse its parents. The agent never creates a missing custom directory or
mount point, changes unrelated permissions, or falls back to internal storage.
Use a separate, non-overlapping directory for each store, outside local recording roots.

Encryption cannot be disabled while the store uses an ignore-ownership spool. First
disable/drain the store and relocate to private, ownership-enabled storage. Plaintext
buffers are never published to an ignore-ownership volume, even after a setting change.
Unexpected existing plaintext entries are preserved and reported for repair, not
silently deleted or replayed. If the volume's ownership setting changes while running,
restart the agent to revalidate it. Symlink/hardlink rejection, instance locking,
volume/inode checks, synchronization, quota accounting, and confirmed-upload cleanup
apply in either mode.

For private spools, directory errors show both the requirements and detected values: a real directory,
daemon owner (account name and UID when available), and `0700`, versus the actual type,
owner, and permissions. Local agents require their own user, not `_hbnvr`. Group ownership
is conventionally `_hbnvr` for system spools; mode `0700` grants the group no access.

For an **unencrypted** system spool on a mounted external volume, for example
(these ownership commands are unnecessary for encrypted ignore-ownership spools):

```sh
diskutil info '/Volumes/Recordings'  # Check filesystem and Owners setting first.
# Only if ownership is disabled and enforcing it across this volume is acceptable:
sudo diskutil enableOwnership '/Volumes/Recordings'
sudo chown _hbnvr:_hbnvr '/Volumes/Recordings/HBNVR-spool'
sudo chmod 700 '/Volumes/Recordings/HBNVR-spool'
```

Enabling ownership is **volume-wide**, not confined to the spool; existing ownership
and permissions on other files will be enforced too. HBNVR never changes that setting
automatically. The directory commands above are deliberately non-recursive and do not
change the volume root or other directories.

POSIX ownership is separate from macOS privacy protection. An external-drive read may
still fail with `Operation not permitted` (often wrapped as Cocoa error 257) even when
the directory owner and mode are correct. A LaunchDaemon cannot approve an interactive
removable-volume prompt. For this headless installation, an administrator can add the
installed `/usr/local/bin/hbnvr` executable in System Settings > Privacy & Security >
Full Disk Access, enable it, then restart the daemon. In the file picker, Command-Shift-G
can locate `/usr/local/bin/hbnvr`. Grant access to the installed executable, not the
build copy or just Terminal. This is a **broader privacy grant than the spool folder**;
HBNVR never enables it automatically. Ordinary Unix permissions still apply. Do not
use `chmod 777`, disable system protection, or change the daemon to root to work around
privacy denial. See [Apple's macOS file-access controls](https://support.apple.com/guide/security/secddd1d86a6/web).

For CLI relocation, disable the store, release any manual spooling hold so pending
uploads can drain, and run `store change --advanced`. Keep the store disabled while
selecting its new path; enable it separately afterward. No daemon restart is needed.
The same privacy, volume, and empty-directory checks below apply.

For offline JSON editing, change a configured location safely as follows:

1. Disable the store and let its uploads/backlog drain. `active`, `queued`,
   `volatileShards`, `spoolCount`, and `unreadableSpoolCount` must all be zero.
   A disabled store may still have backlog; relocation errors report the remaining work.
2. Stop the agent (`sudo hbnvr stop` for the installed daemon).
3. Provision the new directory on the mounted drive. Edit the existing
   `/Library/Application Support/HomeBase-NVR/private/stores/<ID>.json`
   (`<runtime-dir>/stores/<ID>.json` locally), keeping ownership and `0600` permissions.
   Set `SchemaVersion` to at least **3** (keep **4** if already used) and
   add/change/remove `S3.Advanced.SpoolDirectory`.
   Keeping the higher schema after removing the override is fine. Do not lower it to bypass
   compatibility checks; older binaries must reject this setting rather than ignore it.
4. Start the agent. Check status for the resolved spool directory, mount point,
   volume UUID (JSON), volume capacity, available bytes, quota, and free-space reserve.

There is no automatic backlog migration. The old location must still be accessible
and empty of footage, staging, and damaged work when switching. If it is not, startup
refuses the new location: restore the old setting, mount the old drive, and drain/repair
it first. This avoids silently abandoning accepted recordings. Retain the private
`spool/locations/<ID>.json` registry alongside configuration backups; it remembers the
last path and volume identity even when the footage is on an external disk. Custom
directories also contain private ownership/lock files; leave them in place. They do
not count as footage, but do count toward disk usage. An empty directory claimed by
one store is not automatically reassigned to another store.

Capacity checks use `statfs` on the **actual target filesystem**, not the boot disk.
The 10 GiB per-store quota and 2 GiB free-volume reserve remain explicit defaults,
not percentages or a promise to reserve that space permanently. Tune them for your
drive. Concurrent reservations are shared among this daemon's spools on the same
device; unrelated applications can still consume free space. On APFS, available
capacity may reflect space shared with other volumes in its container. Status caches
the measurements on the one-second scheduling tick rather than doing disk queries
for every video frame.

If the drive disappears, its UUID changes, the directory is replaced, or its permissions
become unsafe, the S3 store suspends new recording and reports the storage error.
Accepted RAM work can still upload; disk backlog is preserved for replay, never treated
as corrupt just because its drive is absent. Other stores continue independently.
Restoring the same live directory/volume lets recovery resume. A remount that changes
the device identity, or a drive missing during startup, requires restarting the agent
after the drive is available. No code can guarantee durability after forcibly unplugging
a drive: stop the agent before ejecting it. The agent does not mount/unlock drives;
encrypted external disks must be unlocked and mounted before the daemon can use them,
including during boot without an interactive login.

Default quota is **10 GiB per store**, including staging and unreadable content,
while preserving **2 GiB free volume space**. There is no oldest-footage eviction.
Quota or disk failure preserves accepted work and suspends new recording **only to that
S3 store**; other stores and receivers continue. Unpersisted completed buffers remain
volatile in RAM and are reported. Recovery continues and recording resumes at a keyframe
when capacity returns. Disk replay uses bounded read buffers, not whole-backlog loading.

Only confirmed delivery permits spool deletion. Read, permission, manifest, size, and
hash failures preserve the entry and report an error; they never cause automatic deletion
or permanent exclusion. The worker rechecks affected files every `ProbeIntervalSeconds`
(60s by default), even while uploads are manually held or recording is disabled. Healthy
known entries are not repeatedly hashed. Once repaired, an entry automatically rejoins
the ordinary upload scheduler without a restart or recovery command. A frozen manifest
must still match its original destination, key, and content hash; a repair is not permission
to redirect footage. Back up affected entries before administrative repair; stopping the
daemon during manual repair is prudent, but does not mark an entry permanently failed.

On upgrade from 0.7.0–0.7.2, legacy `quarantined` markers are ignored for upload eligibility.
Valid entries retry automatically; markers stay with their entries until confirmed-delivery
cleanup. Do not delete markers or footage just to unblock relocation.

After confirmed delivery, failed local cleanup is retried without uploading again in that
process. A crash during cleanup can leave incomplete metadata/files; restart preserves,
reports, and rechecks those leftovers rather than guessing that they are safe to erase.
No purge command is provided.

Disable finalizes active recordings but continues upload/recovery. Remove requires disabled
and no outstanding/unreadable work, and removes configuration/credentials only. Uninstall
preserves private data and the account, allowing replay after reinstallation.

Graceful shutdown stops new dispatch, finalizes short complete shards, and spools every
unconfirmed shard without waiting for network success. The application has a 45s budget;
launchd allows 60s and installer stop/upgrade waits 75s. Failed finalization/persistence
is explicitly unsafe and produces an error; no software flush promises hardware
power-loss safety. **Crash, SIGKILL, or power failure can lose RAM-only footage.** Enable
a local store too when incremental on-disk recording/recovery is required. S3 does not
salvage unfinished containers or backfill from local recordings.

## JSON and diagnostics

S3 uses the existing daemon-private `stores/<UUID>.json` directory (0700, files 0600).
These are plaintext AWS credentials and (if enabled) encryption passwords protected by
filesystem permissions, not encrypted secrets. List/status/edit defaults remove secrets.
Stop the daemon before hand-editing; preserve
its ownership, UID/account UUID, store ID, and destination. Do not change destination with
backlog present. Unknown future store fields are not promised round-trip preservation.

Example (identity and keys are placeholders; use interactive setup for real values):

```json
{
  "SchemaVersion": 2,
  "ID": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
  "Name": "S3 recordings",
  "Type": "S3",
  "Enabled": true,
  "Directory": "",
  "ShardDuration": "1m",
  "RetentionPeriod": "1w",
  "OwnerUID": 501,
  "OwnerUUID": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
  "S3": {
    "Bucket": "your-existing-bucket",
    "Region": "us-west-2",
    "Prefix": "hbnvr/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/",
    "ExpectedOwner": "123456789012",
    "Lifecycle": "Managed",
    "Credentials": {"AccessKeyID": "REPLACE_WITH_ACCESS_KEY", "SecretAccessKey": "REPLACE_WITH_SECRET"},
    "ClientEncryption": {"Enabled": true, "Password": "REPLACE_WITH_A_UNIQUE_BACKED_UP_PASSPHRASE"},
    "Advanced": {
      "ConcurrentUploads": 5,
      "ReservedLiveSlots": 1,
      "TransientFailureCount": 3,
      "TransientFailureWindowSeconds": 30,
      "RetryMaximumDelaySeconds": 30,
      "ProbeIntervalSeconds": 60,
      "RequestTimeoutSeconds": 600,
      "FinalizedShardFloor": 10,
      "FinalizedShardsPerCamera": 2,
      "QueueAgeFloorSeconds": 120,
      "SpoolLimitBytes": 10737418240,
      "MinimumFreeBytes": 2147483648,
      "ForceSpooling": false
    }
  }
}
```

`ExpectedOwner` and `Advanced` are optional. Individual Advanced fields can be omitted;
the table/defaults above apply. Local-store JSON remains compatible.
The optional `Advanced.SpoolDirectory` requires store `SchemaVersion` 3 or newer; the example
above uses the default spool location and therefore needs only version 2 for encryption.
`ClientEncryption` is optional: omitted from a stored file, or `{"Enabled": false}`,
means plaintext video. An enabled persisted configuration must contain its password;
missing/invalid passwords are errors, never a fallback to plaintext. In edit IPC only,
enabled settings with the redacted password omitted retain the stored password.
Status's `s3.clientEncrypted` reports the current policy for newly recorded shards,
not whether historical/pending footage used an earlier policy.
`s3.spoolDirectory`, `spoolVolume`, `spoolVolumeUUID`, `spoolVolumeCapacityBytes`,
`spoolVolumeAvailableBytes`, `spoolLimitBytes`, and `spoolMinimumFreeBytes` describe
the actual spool and its configured limits. Capacity/available values are absent when
the target is unavailable; they never silently describe the internal disk instead.

`status --json` adds an `s3` object per S3 store: acceptance, spooling/reasons, queued,
active/retrying uploads, assembling/resident bytes, volatile count, spool bytes/count,
`unreadableSpoolCount`, oldest backlog age, confirmed uploads, next probe, next read check
(`nextReadRetrySeconds` when needed), desired/applied
retention, lifecycle verification state, and separate warning. Spooling is recording-capable;
spool exhaustion is not. Upload counters are process-lifetime counters, not a cloud inventory.
`quarantinedCount` is a retired compatibility field, always zero on new agents, so older
protocol-v1 clients can still decode status. Use `unreadableSpoolCount` for read problems.
