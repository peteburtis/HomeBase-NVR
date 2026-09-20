# Opt-in real-AWS smoke test

Unit tests use synthetic video and injected transports/HTTP; they never upload to AWS.
Use this procedure only with an **explicitly designated existing test bucket/prefix**.
Local camera-access permission does not itself authorize uploading camera video.
No elevated installation, production restart, or Git commit is part of this procedure.

1. Create/designate a disposable general-purpose, never-versioned, SSE-S3 test bucket
   yourself. HBNVR will not create it. Confirm its region and owner account ID.
2. Start an isolated foreground agent (short private path):

   ```sh
   hbnvr agent --runtime-dir /tmp/hbnvr-s3-smoke
   ```

3. In another terminal run `hbnvr store add --runtime-dir /tmp/hbnvr-s3-smoke` and
   choose S3. Use the designated test bucket and a unique test prefix, `10s` shards,
   `1d` retention, and Managed lifecycle. Generate a dedicated principal with exactly
   the printed policy, no console login. Supply its access key/hidden secret.
   Enter and confirm a unique test encryption password; keep it separately.
4. Confirm setup. Verify `store list --json` and `status --json` contain no credentials.
   Check desired 1d/applied 1d separately from upload health. Use **separate read/admin
   credentials** to inspect the setup object, prefix-scoped lifecycle rule, and one-day
   multipart cleanup. Do not add GetObject/ListBucket to the recorder's policy.
5. Only after explicitly authorizing footage for this destination, add a test RTSP camera
   to this isolated agent: `hbnvr camera add --runtime-dir /tmp/hbnvr-s3-smoke`.
   Alternatively use a synthetic RTSP source. Verify several confirmed uploads. With
   your separate reader, retrieve and play full/short files and confirm UTC keys,
   unique IDs, SSE-S3, and S3 Standard. The normal spool should contain no media files.
   With encryption enabled, the downloaded files are `.mp4.hbnvr` opaque objects.
   Run `hbnvr decrypt INPUT OUTPUT` and enter the test password before playback.
   A wrong password or modified ciphertext must create no output. Verify list/status
   expose the encryption setting but never its password.
6. Temporarily deny PutObject to **this dedicated test principal/prefix**, leaving other
   applications untouched. Confirm immediate spooling, continued recording, private
   0700/0600 spool permissions, retained complete files, and a 60s recovery probe.
   Restore that permission. Confirm oldest-first probe recovery, bounded backlog replay,
   live-upload priority, and deletion of spool entries only after confirmation.
7. While denied/offline, SIGTERM the isolated agent. It should finish promptly without
   waiting for AWS, leave complete short shards, and report any unsafe persistence.
   Restart with the same runtime directory; restore access and verify replay. A deliberate
   SIGKILL is a different durability test: current RAM shards may be lost, by design.
8. Disable the store while backlog exists. Verify no new recording is accepted but upload
   recovery continues. Removal must fail until it is disabled and all pending/unreadable
   work is clear. Repair credentials through `store change` with backlog present and verify
   old objects retain their original keys. Remove only after it drains; verify lifecycle
   rules/cloud recordings remain.
   Also change the encryption password while backlog exists: old objects must still
   require the old password, new objects the new one, and queued ciphertext must not
   be re-encrypted. Disabling encryption affects future shards only. Repeat setup with
   a blank encryption password to verify ordinary MP4 operation remains available.
9. Repeat with External lifecycle and a principal lacking lifecycle permissions. Apply the
   printed lifecycle JSON yourself, merged with existing rules. Status must remain
   external/unverified, with no lifecycle calls. Managed mode with lifecycle permission
   denied should warn while uploads still succeed.

For large-shard testing, use a shard exceeding 64 MiB; inspect multipart completion and
checksums with the separate administrator. Never-versioned buckets plus same-key retries
mean an ambiguous upload can overwrite identical bytes. Multipart parts abandoned by a
crash are cleaned asynchronously by lifecycle, not reconstructed by HBNVR.

## Opt-in thumbnails and metadata repair smoke (0.18.0)

For download failures, install matching 0.18.2 (or newer) CLI/agent builds and rerun the same
repair command. Capture the `Download diagnostic [...]` lines and final skip totals.
Up to three examples per reason are printed and logged; they contain byte counts
and hashed ETag summaries, not credentials, footage, or raw object paths. HTTP
404/412 and HTTP-200 size/ETag failures are distinct. A zero-recovery scan must say
that no new metadata or thumbnails were recovered, not claim a successful merge.
Version 0.18.2 also fixes false 404 skips when listings encode spaces as `+`.
For an isolated key-encoding smoke, use camera names containing spaces, literal `+`,
literal `%20`, and Unicode; repair must request the exact original objects and leave
their names untouched. Do not rename existing footage to work around this bug.

Before repair, keep the isolated synthetic/test camera recording across a canonical
UTC :10, :30, or :50 midpoint. With separate reader credentials, retrieve
`<prefix>.hbnvr/playback/v1/<camera UUID lowercase>/thumbnails/YYYY-MM-DD/HH-mm.jpg.hbnvr`
(or `.jpg` without encryption). Decrypt with `hbnvr decrypt INPUT OUTPUT.jpg` and
verify a valid JPEG no larger than 1280×720, original aspect, no upscaling, and a
caption containing the midpoint plus actual preceding keyframe time. Use a long
shard for this check: the thumbnail should upload before that shard closes.

Force spooling before another midpoint. Verify both `thumbnail.jpg.hbnvr` and
`video.mp4.hbnvr` entries live under the SAME selected spool directory, share its
quota/free-space reporting, and resume through bounded replay after `spool --off`.
Restart while held to check both kinds survive; no normal-path JPEG cache should exist.
Use separate reader/admin keys to compare the exact frozen ciphertext before/after
replay. Never give recorder keys object reads to perform this check.

Use only the isolated agent and explicitly designated test destination above. Do not
delete production metadata to test repair. Keep the cameras configured.

1. With the test store disabled and drained, stop its agent. Back up and move aside
   **only** its `<runtime-dir>/playback/<test-store UUID>` journal, retaining the backup
   outside the runtime directory. Restart the isolated agent. The original MP4 objects
   remain on S3. This simulates missing metadata without deleting video.
2. Run `hbnvr store repair-metadata "Test S3 store" --dry-run --runtime-dir PATH`.
   The recorder's write-only keys should be denied listing. Use a separate temporary
   reader principal with precisely the printed ListBucket/GetObject policy.
   Verify the count/download estimate, no GETs of video, no manifest PUTs from repair,
   and that saved store credentials are unchanged.
3. Run without `--dry-run`, supply temporary reader keys again, and confirm. Check
   independent reader/admin credentials can retrieve the resulting daily/monthly
   manifests and play recovered full/short and encrypted/plain shards.
   Verify sample-derived start/end times and canonical source; no video ETag should change.
4. Put a harmless unrelated test object and a legacy MP4 without embedded timing in the
   designated test prefix. Rerun: both must remain byte-for-byte unchanged and unindexed.
   Unknown cameras are similarly ignored. Camera display-name changes must not block
   files whose embedded camera UUID still matches.
5. Repeat repair: indexed objects with their expected thumbnails present should not
   be downloaded again. For a synthetic recording covering a midpoint but lacking its
   thumbnail, retain the video journal and verify repair downloads only that needed
   source and adds a preview through the shared pool. Compare all preexisting image
   ETags: no existing thumbnail may be overwritten. A rerun should skip this source
   once its image is pending or listed. Test a wrong old
   password and choose skip; the original ciphertext remains. Cancel during a read:
   previously merged entries remain, later candidates do not merge, and IPC status
   remains responsive. Resume recording during another repair to exercise shared
   publication without dropping live entries.

No deletion permission is needed by either recorder or temporary repair reader. Cloud
publication still uses the saved write-only credentials; the temporary principal must
not gain PutObject. Read/transfer charges apply. Do not restore an old journal over a
running agent; preserve the test backup until results have been checked.

For a controlled manual-spooling test (no network-disconnect required):

```sh
hbnvr store spool "Test S3 store" --on
hbnvr status
# Let at least one shard complete; expect manual reason, growing spool count,
# no new uploads/probes after existing requests finish. Restart preserves the hold.
hbnvr store spool --off  # select the test store from the picker
hbnvr status
# Expect bounded replay, confirmed uploads, and deletion only after confirmation.
hbnvr store change "Test S3 store" --advanced
```

Use `--runtime-dir PATH` on these commands for an isolated local agent. Operational-only
advanced edits need no AWS validation. Do not enable unbounded recording with a manual
hold; quota exhaustion suspends the store rather than evicting pending footage.

For encrypted external-drive spooling, use a dedicated test directory on an existing
writable local APFS/HFS+ volume with ownership ignored. Do not change the volume's
ownership setting. With client-side encryption enabled, disable/drain the test store,
select that directory with `store change --advanced`, then enable it and force spooling.
Verify `.mp4.hbnvr` files, no plaintext media, status capacity/free-space values from
that drive, shutdown/restart recovery, and confirmed-upload cleanup after releasing
the hold. Exact UID/0700/0600 checks do not apply on that encrypted shared volume.
Disabling encryption there must fail without changing the configuration. On a private
ownership-enabled spool, plaintext operation and strict permission checks still apply.
Other local users may see metadata or delete/modify encrypted files on the shared
volume; macOS privacy approval is still required for the installed daemon.

Space exhaustion and corrupted-spool tests are safer with the deterministic injected
filesystem tests than filling a real disk. For a controlled test, stop the isolated agent,
lower its private JSON `Advanced.SpoolLimitBytes`, restart while upload is denied, and
confirm suspension without eviction. Restore the quota/access, then verify recovery.

The offline test suites cover repeated S3 rejections, legacy quarantine markers,
permission/hash/manifest failures followed by repair, and interrupted post-confirmation
cleanup. No rejection permanently excludes an entry. `status` reports unreadable entries
and the next read check; repairing a file restores eligibility automatically. A failing
probe gives other eligible shards a turn. These tests use synthetic bytes and injected
transports (the subprocess repair fixture holds all uploads), never a real AWS destination.
Transport fixtures also enforce fixed-length versus AWS-chunked request framing and
verify SHA-256 trailers across chunk boundaries and same-key disk retries. This catches
the disk-only HTTP 411 defect fixed in 0.7.4; the earlier fixture decoded chunks without
validating their required headers. Keep the real-AWS outage/replay check above as the
separate end-to-end verification of the actual service.

For external-drive spooling, first drain/disable the test store, stop the agent, and
configure a dedicated `Advanced.SpoolDirectory` (private unless using the encrypted
ignore-ownership exception above) with store `SchemaVersion` at
least 3 (preserve 4 after using forced spooling)
as documented in S3-STORE.md. Verify status names that exact directory and reports
capacity/free space for its mounted volume, not the internal disk. Start with the drive
absent: the store must report an error without creating a fallback directory. Mount it
and restart, then repeat the offline-upload test and verify ciphertext appears only
on the external spool. Do not forcibly detach a drive containing accepted footage;
mid-operation disappearance/replacement is covered by injected tests. Test location
changes with a pending shard: they must be refused, leaving the old spool untouched.

Clean up the disposable prefix/principal using the separate administrator when you are
finished. HBNVR deliberately has no cloud purge command. Do not run broad bucket deletion
commands or reuse production prefixes for this test.
