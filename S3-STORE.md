# S3 stores (0.7.6)

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
KMS, object retrieval, audio expansion, or local-store backfill is implemented.

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

Complete MP4s are encrypted in RAM **before** entering the upload manager. Upload hashes,
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
| 56 through length−17 | Encrypted MP4 bytes |
| Final 16 bytes | AES-GCM authentication tag |

Derive 32 bytes with PBKDF2-HMAC-SHA256 from the exact UTF-8 password (no normalization
or trimming). Authenticate the complete 56-byte header as GCM additional authenticated
data. The per-file overhead is 72 bytes; no padding is used. Passwords are 1–1024 UTF-8
bytes excluding NUL/newlines. Readers reject unknown versions and work factors before
derivation. The v1 AES-GCM plaintext limit is 2^36−32 bytes per shard. This documented
application envelope has interoperability tests against OpenSSL, not an external security
audit or AWS Encryption Client compatibility. Retain the format specification and a
working decrypt binary with long-term backups.

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
