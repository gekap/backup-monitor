# K10-tool

A smart stuck-action detection and cancellation tool for [Veeam Kasten K10](https://www.kasten.io/) backup environments.

K10 actions (backups, exports, restores) can get stuck in `Pending`, `Running`, or `AttemptFailed` states indefinitely. This tool identifies genuinely stuck actions using multi-signal detection and safely cancels them — without killing legitimate long-running operations.

## Features

### Smart Stuck Detection

Unlike blindly cancelling all non-complete actions, K10-tool uses three layers of detection:

| Signal | Condition | Applies to |
|--------|-----------|------------|
| **Age threshold** | Action older than `--max-age` (default 24h) | All actions (required gate) |
| **No progress** | `progress` field is `0` after threshold | All action types |
| **Error present** | `status.error.message` is non-empty | All action types |
| **Pending forever** | State is `Pending` (never started) | All actions |
| **AttemptFailed** | Stuck in retry loop | All actions |

`Running` actions older than the threshold are only cancelled if they **also** show no progress or have an error — protecting healthy long-running operations.

### Policy Status Dashboard (`--check`)

A read-only overview of all K10 policies and their current state, similar to the K10 UI dashboard:

```
$ ./k10-cancel-stuck-actions.sh --check

=== K10 Policy Status Dashboard ===

NAME                         NAMESPACE            ACTION                 LAST RUN                     STATUS
--------------------------------------------------------------------------------------------------------------------
notes-app-backup             notes-app            Snapshot + Export      Sat Feb 21 2026 12:38 PM     Running
  [OK   ] RunAction            policy-run-xxxxx                         age=0h    Running progress=—  policy=notes-app-backup
  [OK   ] BackupAction         scheduled-xxxxx                          age=0h    Running progress=—  policy=notes-app-backup
  [OK   ] ExportAction         policy-run-xxxxx                         age=0h    Running progress=5% policy=notes-app-backup
crypto-analyzer-backup       crypto-analyzer      Snapshot + Export      Sat Feb 21 2026 10:13 AM     Skipped

=== Summary ===
Policies: 9 (7 complete, not shown)
  Failed:    0
  Skipped:   1
  Running:   1
  Stuck:     0
  Never run: 0
```

- Shows policy names, target namespaces, action types, last run time, and status
- Completed policies are hidden (count shown in summary) — use `--show-recent-completed` to view them
- Active actions are expanded underneath each running policy with health labels (`OK`, `OLD`, `STUCK`)
- Searches both `kasten-io` and application namespaces for actions

### Recently Completed Policies (`--show-recent-completed`)

A standalone view of policies whose most recent action completed successfully:

```
$ ./k10-cancel-stuck-actions.sh --show-recent-completed

=== Recently Completed K10 Policies ===

NAME                         NAMESPACE            ACTION                 COMPLETED AT
--------------------------------------------------------------------------------------------
notes-app-backup             notes-app            Snapshot               Sat Feb 21 2026 12:45 PM
crypto-analyzer-backup       crypto-analyzer      Export                 Sat Feb 21 2026 10:20 AM

2 completed policies.
```

- Shows policy name, target namespace, last action type, and completion time
- Complements `--check`, which hides completed policies behind a summary count

### Safe Cancellation

```
$ ./k10-cancel-stuck-actions.sh --dry-run --max-age 48h

[DRY RUN] No changes will be made.
Stuck detection: actions older than 48h

STUCK: BackupAction scheduled-abc123 [Running] policy=myapp-backup — age 72h — no progress (progress=0 after 72h)
  -> Would attempt cancel, then delete if cancel fails

=== Summary ===
Found:     3 actions in target states (Pending/Running/AttemptFailed)
Skipped:   2 (too young or Running without stuck signals)
Stuck:     1 actions identified as stuck
```

- Attempts K10 `CancelAction` first (graceful cancellation)
- Falls back to direct deletion for `Pending` actions that can't be cancelled
- Re-checks action state before cancelling (handles race conditions)
- Validates resource names before YAML interpolation

## Usage

```
./k10-cancel-stuck-actions.sh [--dry-run] [--max-age <duration>] [--check] [--show-recent-completed]
```

| Flag | Description |
|------|-------------|
| `--check` / `--monitor` | Status dashboard — show all policies and active actions, then exit |
| `--show-recent-completed` | Show recently completed policies with completion time, then exit |
| `--dry-run` | Show what would be cancelled without making changes |
| `--max-age <dur>` | Only target actions older than this (default: `24h`, minimum: `1h`). Supports `h` (hours) and `d` (days): `12h`, `24h`, `2d`, `72h` |
| `-h` / `--help` | Show usage |

### Examples

```bash
# Check current policy status (read-only)
./k10-cancel-stuck-actions.sh --check

# View recently completed policies
./k10-cancel-stuck-actions.sh --show-recent-completed

# Preview what would be cancelled (default: actions older than 24h)
./k10-cancel-stuck-actions.sh --dry-run

# Preview with custom threshold
./k10-cancel-stuck-actions.sh --dry-run --max-age 48h

# Cancel stuck actions older than 2 days
./k10-cancel-stuck-actions.sh --max-age 2d
```

## Requirements

- `kubectl` configured with access to the K10 namespace (`kasten-io`)
- `jq` for JSON parsing
- `bash` 4.0+ (associative arrays)
- Veeam Kasten K10 installed on the target cluster

## How It Works

1. Scans all 12 K10 action types across `kasten-io` and application namespaces
2. For each action in `Pending`, `Running`, or `AttemptFailed` state:
   - Computes age from `status.startTime` (Running) or `metadata.creationTimestamp` (fallback)
   - Skips actions younger than `--max-age`
   - For `Running` actions, requires an additional stuck signal (no progress or error present)
   - `Pending` and `AttemptFailed` actions older than the threshold are always considered stuck
3. Cancels via K10 `CancelAction` CRD (graceful), falls back to `kubectl delete` if CancelAction fails
4. Cancelling a `RunAction` cascades to cancel all child actions (BackupAction, ExportAction, etc.)

## License Compliance System

The tool includes automatic enterprise environment detection and license key enforcement powered by `k10-lib.sh`. This system is **non-blocking** — it never prevents the tool from running, but enterprise clusters will see a persistent license banner on every run until a valid key is provided.

### How It Works

On startup, the script:

1. **Generates a cluster fingerprint** — SHA256 hash of the `kube-system` namespace UID, truncated to 16 characters. Anonymous and deterministic (same cluster always produces the same ID). Logged to `~/.k10tool-fingerprint`.

2. **Detects enterprise environments** using a scoring system (0-5 points):

| Signal | Points | Detection Method |
|--------|--------|-----------------|
| Node count > 3 | +1 | `kubectl get nodes` |
| Managed K8s (EKS/AKS/GKE/OpenShift) | +1 | Node labels + server version |
| Namespace count > 10 | +1 | `kubectl get namespaces` |
| HA control plane (>1 control-plane node) | +1 | Node labels + apiserver pod count |
| Paid K10 license (>5 nodes + license present) | +1 | K10 configmap/secret |

   A score of **3 or higher** triggers enterprise detection. This prevents false positives on lab/dev clusters.

3. **License key validation** — on enterprise clusters, the banner **cannot be suppressed** without a valid license key tied to the cluster fingerprint. `K10TOOL_NO_BANNER=true` is ignored on enterprise clusters.

4. **Optional telemetry** — only when explicitly opted in via environment variables.

### Obtaining a License Key

Enterprise users will see a banner like this on every run:

```
================================================================================
  K10-TOOL  —  Enterprise Environment Detected (Unlicensed)
================================================================================
  Cluster ID:   a1b2c3d4e5f67890
  ...
  To obtain a license key for this cluster, contact:
    georgios.kapellakis@yandex.com

  Include your Cluster ID in the request. Once received:
    export K10TOOL_LICENSE_KEY=<your-key>
================================================================================
```

Each license key is unique to a cluster fingerprint and cannot be reused across clusters.

### Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `K10TOOL_LICENSE_KEY` | unset | License key for this cluster (suppresses banner on enterprise clusters) |
| `K10TOOL_NO_BANNER` | unset | Set to `true` to suppress the banner (only works on non-enterprise clusters) |
| `K10TOOL_REPORT` | unset | Set to `true` to opt in to anonymous telemetry |
| `K10TOOL_REPORT_ENDPOINT` | unset | HTTPS URL for telemetry POST (required alongside `K10TOOL_REPORT`) |
| `K10TOOL_FINGERPRINT_FILE` | `~/.k10tool-fingerprint` | Custom path for the fingerprint log file |

### Graceful Degradation

- All kubectl calls are guarded — detection failures produce defaults, never crash the tool
- If `k10-lib.sh` is missing, the tool works normally without compliance features
- The banner never appears when `--help` is used (exits before compliance check)
- Adds ~300-500ms overhead at startup (8 lightweight kubectl calls, run once)

## License

This project is licensed under the **GNU Affero General Public License v3.0 (AGPL-3.0)** — see [LICENSE](LICENSE) for details.

This means you are free to use, modify, and distribute this tool, but **any modifications or derivative works must also be released under AGPL-3.0**, including when used to provide a network service.

This tool is provided **as-is, without warranty of any kind**. Use at your own risk. Always test with `--dry-run` first.

### Commercial License

If your organization requires a **proprietary/commercial license** (without AGPL copyleft obligations), enterprise support, custom integrations, or SLA-backed maintenance, see [COMMERCIAL_LICENSE.md](COMMERCIAL_LICENSE.md) or contact: **georgios.kapellakis@yandex.com**
