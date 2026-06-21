# watchdog

A single Bash script (`monitor_vms.sh`) that you schedule with `cron`.

## Requirements

- A **Proxmox VE** host — the script uses Proxmox's own `qm` and `pvesh` tools.
- Run every command below as **root** (the default Proxmox admin user).
- Two helper utilities, `jq` and `lsof`. Install them once with:

  ```bash
  apt update && apt install -y jq lsof
  ```

## Install

### Clone the git repository

```bash
cd /root
git clone https://github.com/Xenogy/watchdog.git
```

## Configure (optional)

There's nothing you *have* to set — the script auto-detects which node it's
running on. The two settings you might want to change live near the top:

```bash
nano /root/watchdog/monitor_vms.sh
```

```bash
WATCHDOG_TAG="watchdog"

WATCHDOG_ACTIVE_TAG="watchdog-active"
TAG_DURING_CHECK=1

CLUSTER_WIDE=0
```

- **`WATCHDOG_TAG`** — the tag that marks a VM for monitoring. The default,
  `watchdog`, matches the rest of this guide; leave it unless you want a
  different name.
- **`WATCHDOG_ACTIVE_TAG`** — a transient tag the watchdog puts on a VM while it
  is working on it, then removes when it is done (see
  [The "active" tag](#the-active-tag) below). Set it to `""` to turn the feature
  off.
- **`TAG_DURING_CHECK`** — when `1` (default), the active tag is applied while
  the watchdog is merely *examining* each VM, so it visibly steps from one VM to
  the next and you can watch a run progress in the UI. Set to `0` to tag a VM
  only while it is actually being restarted (see
  [The "active" tag](#the-active-tag)).
- **`CLUSTER_WIDE`** — leave at `0` to watch only this node's VMs. Set to `1` to
  watch tagged VMs across the whole cluster from this one node (see
  [Cluster-wide mode](#cluster-wide-mode-optional) below).

There's also a `LOCAL_NODE` setting just above these, normally left **empty** —
the script detects this node's name from Proxmox. Only set it if auto-detection
ever picks the wrong name.

Save and exit again (**Ctrl+S**, **Ctrl+X**).

## Choose which VMs to monitor (by tag)

You no longer list VM IDs in the script. Instead, **tag the VMs you want
watched** with the `watchdog` tag — every VM carrying that tag is monitored,
and the script re-reads the tags on every run.

In the **Proxmox web interface**: open the VM → its **Summary** page → click the
**＋** next to the VM name (or **Edit** in the Notes/Tags area) → type
`watchdog` → confirm.

Or from the **command line**. For a VM that has no other tags:

```bash
qm set 101 --tags watchdog
```

`qm set --tags` **replaces** the VM's entire tag list, so if the VM already has
tags you must list them all (semicolon-separated), e.g.:

```bash
qm set 101 --tags "production;web;watchdog"
```

To **temporarily disable** monitoring for a VM — handy during testing — just
remove the `watchdog` tag again (UI, or re-run `qm set` with the remaining tags;
`qm set <vmid> --tags ""` clears all tags). The change takes effect on the next
run. The script also re-checks each VM's tags immediately before acting on it,
so a tag removed mid-run is honored before the next restart attempt — though it
won't interrupt a `qm` stop/start already in progress.

Notes:

- Matching is **case-insensitive** (`watchdog`, `Watchdog`, … all count) and
  matches the whole tag, so unrelated tags like `watchdog-test` are ignored.
- **Templates are skipped** automatically, even if tagged.

## The "active" tag

While the watchdog is working on a VM it tags that VM with `watchdog-active`
(configurable via `WATCHDOG_ACTIVE_TAG`) and removes the tag again when it is
done. The VM's other tags are left untouched.

This gives you two things:

- **Visibility** — the VM the watchdog is touching right now is obvious at a
  glance in the Proxmox UI and in `qm config`/`pvesh` output.
- **Coordination** — other automation can watch for this tag and hold off on
  touching a VM until it disappears, so nothing fights the watchdog.

### What "working on it" means: `TAG_DURING_CHECK`

The watchdog walks its monitored VMs one at a time. `TAG_DURING_CHECK` controls
how much of that work the tag covers:

- **`TAG_DURING_CHECK=1` (default)** — the tag is added as each VM's check
  *begins* and removed as it *ends*, so the tag visibly steps from one VM to the
  next and you can follow a run's progress live in the UI. If a check decides to
  restart the VM, the tag simply stays on through the restart and comes off when
  that finishes. So normally only one VM is tagged at a time during the
  sequential check; the exceptions are if you also enable parallel restarts, or
  if a tag removal fails (a transient `pvesh` error leaves it lingering until the
  next run's startup sweep — see [Details](#details)).
- **`TAG_DURING_CHECK=0`** — the tag is applied *only* while a VM is actually
  being restarted. Its presence then strictly means "the watchdog is changing
  this VM," which is the cleaner do-not-touch signal for other automation, and it
  avoids a tag write per VM on every run (worth considering if you monitor many
  VMs and want to keep cluster-config churn down). The visual progress cursor is
  lost.

Either way, the lifecycle of a healthy watched VM is: it carries `watchdog`; the
`watchdog-active` tag appears while the watchdog is on it and then goes away
again.

### Details

- During a restart the tag is removed whether it **succeeded, failed, or was
  aborted** because the `watchdog` tag was pulled mid-run.
- A *restart* never tags a VM the watchdog decided to **skip** (e.g. still in its
  restart cooldown, or its lock holder is stuck in `D` state). With
  `TAG_DURING_CHECK=1` such a VM is still briefly tagged for its check, then
  untagged like any other examined VM.
- If a run is **killed mid-restart** (host reboot, `kill -9`, …) the tag can be
  left behind. To prevent it from lingering forever, the watchdog strips any
  pre-existing `watchdog-active` from monitored VMs at the **start** of each run,
  before it begins any work — safe because only one run executes at a time.
- The tag is a best-effort, soft signal, **not a lock.** There is a small window
  between another system reading tags and the watchdog adding the tag, and the
  tag doesn't prevent anyone from acting. The real guard during `qm`
  stop/start/unlock remains Proxmox's own per-VM config lock.
- Set `WATCHDOG_ACTIVE_TAG=""` to disable the feature entirely (no tag is ever
  added, the check-time tagging and the startup cleanup are both skipped).

## Cluster-wide mode (optional)

By default the watchdog only manages VMs on its own node, so in a multi-node
cluster you would run one copy per node. Set `CLUSTER_WIDE=1` instead to watch
**every tagged VM across the whole cluster from a single node** — one script,
one cron job.

```bash
CLUSTER_WIDE=1
```

How it works: discovery and the CPU-history/uptime checks use the cluster-wide
Proxmox API (`pvesh`). The VM's current run state is read with `qm status`, and
all corrective actions (`qm` shutdown/stop/start/unlock) plus lock inspection
(`lsof`, `ps`) run on the VM's host node over **SSH**. So if inter-node SSH is
down, VMs on unreachable nodes are simply skipped that cycle (logged).

Requirements and notes:

- **Inter-node root SSH must work.** Proxmox sets up passwordless `root` SSH
  between cluster members by default, so this normally works out of the box. The
  watchdog connects to each node by its **IP** (read from `/etc/pve/.members`),
  so node names do **not** need to resolve via DNS/`/etc/hosts`. You can confirm
  reachability with `ssh root@<other-node-IP> qm list` from the node running the
  watchdog. If SSH is locked down, the watchdog falls back to skipping VMs it
  can't reach (logged), so nothing is silently broken. The startup log prints the
  node→IP map it resolved.
- **The node you run on is auto-detected** (from `/etc/pve/local`) — that's how
  the script tells "local" from "remote", so there's nothing to configure.
- **`lsof` must be installed on every node** (lock inspection runs on the VM's
  host node). `jq` is only needed on the node running the watchdog.
- **Run it on one node only.** Don't also leave per-node copies running, or
  they'll fight over the same VMs.
- The startup log line shows where each VM lives, e.g.
  `Monitoring 3 VM(s) tagged 'watchdog' cluster-wide: 101@pve1 104@pve2 105@pve3`.
- The optional stale-`qm`-process cleanup (`ENABLE_STALE_QM_CLEANUP`, off by
  default) only ever inspects the local node.
- A VM's host node is resolved once per run. If a VM is **live-migrating** at the
  moment the watchdog reaches it, that one cycle may target the old node and skip
  the VM; the next run picks up the new location. No action is taken on the wrong
  node, so this self-heals.

## Make it executable

```bash
chmod +x /root/watchdog/monitor_vms.sh
```

## Test it

Run it once by hand before scheduling it:

```bash
/root/watchdog/monitor_vms.sh
```

You should see a line listing the tagged VMs it found (e.g.
`Monitoring 2 VM(s) tagged 'watchdog': 101 104`), followed by lines such as
`Checking VM: 101` and `VM 101 healthy`. If you haven't tagged any VMs yet, it
logs `No VMs tagged 'watchdog'` and exits — go back and add the tag.

## Schedule it with cron

1. Open root's crontab:

   ```bash
   crontab -e
   ```

   (The first time, it may ask which editor to use — choose **nano**.)

2. Add this line at the bottom of the file:

   ```
   */15 * * * * /root/watchdog/monitor_vms.sh
   ```

3. Save and exit (**Ctrl+S**, **Ctrl+X**).

`*/15 * * * *` means *run at every 15th minute* — i.e. at :00, :15, :30, and :45
past every hour. The five fields are **minute, hour, day-of-month, month,
day-of-week**, and a `*` means "every".

Confirm the entry was saved:

```bash
crontab -l
```

That's it — the watchdog now checks your VMs four times an hour.

## Pause / disable the watchdog

You don't need to touch cron to turn the watchdog off. Drop a flag file next to
the script and it stops; remove it and it resumes:

```bash
touch /root/watchdog/watchdog.disabled   # OFF — pause the watchdog
rm    /root/watchdog/watchdog.disabled   # ON  — resume it
```

- **Takes effect immediately.** With the flag present, the next cron run exits
  right away without touching any VM. If a run is already in progress, it stops
  cleanly after the VM it's on (never mid-restart).
- **Survives reboots.** The flag lives next to the script, so an OFF watchdog
  stays off until you remove the file.
- **Quiet.** A disabled cron run logs nothing (so a long pause won't fill the
  log). Running `./monitor_vms.sh` by hand while disabled prints a one-line
  reminder telling you the flag is set.

This is the recommended way to pause for maintenance — commenting out the cron
entry can still let an already-scheduled run fire, whereas the flag is checked at
the start of (and during) every run.

## Logs

The watchdog records everything it does in two files:

- `/var/log/vm_monitor.log` — the main activity log.
- `/var/log/vm-monitor-ex-cron.log` — the full output of each cron run.

Watch it live with:

```bash
tail -f /var/log/vm_monitor.log
```
