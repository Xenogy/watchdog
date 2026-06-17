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

## Configure (required)

Open the script and set your node name near the top:

```bash
nano /root/watchdog/monitor_vms.sh
```

```bash
# REQUIRED: Enter the Proxmox host node name (find it with `hostname`).
HOST_NODE="pve"

WATCHDOG_TAG="watchdog"
```

- **`HOST_NODE`** — your node's name. Find it with `hostname`, or read it from
  the left sidebar of the Proxmox web interface.
- **`WATCHDOG_TAG`** — the tag that marks a VM for monitoring. The default,
  `watchdog`, matches the rest of this guide; leave it unless you want a
  different name.

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

## Logs

The watchdog records everything it does in two files:

- `/var/log/vm_monitor.log` — the main activity log.
- `/var/log/vm-monitor-ex-cron.log` — the full output of each cron run.

Watch it live with:

```bash
tail -f /var/log/vm_monitor.log
```
