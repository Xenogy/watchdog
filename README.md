# watchdog

A simple **Proxmox VE** watchdog for virtual machines. It runs on your Proxmox
host and, every few minutes, checks each VM you tell it to watch. If a VM has
crashed (stopped), is pinned at very high CPU, or has stalled at very low CPU,
the watchdog automatically restarts it.

It is a single Bash script (`monitor_vms.sh`) that you schedule with `cron`.

> ⚠️ **This script restarts and force-stops VMs.** Only list the VM IDs that are
> safe to reboot automatically, and run it once by hand (see *Test it*) before
> you schedule it.

## Requirements

- A **Proxmox VE** host — the script uses Proxmox's own `qm` and `pvesh` tools.
- Run every command below as **root** (the default Proxmox admin user).
- Two helper utilities, `jq` and `lsof`. Install them once with:

  ```bash
  apt update && apt install -y jq lsof
  ```

## Install

Pick **one** of the two options below. Both leave the script at
`/root/monitor_vms.sh`, which is the path the cron job will use.

### Option A — Clone the git repository

```bash
cd /root
git clone https://github.com/Xenogy/watchdog.git
cp /root/watchdog/monitor_vms.sh /root/monitor_vms.sh
```

(If `git` is not installed, run `apt install -y git` first.)

### Option B — Paste the script with nano

1. Open a new, empty file:

   ```bash
   nano /root/monitor_vms.sh
   ```

2. Paste in the full contents of `monitor_vms.sh` (copy it from the file on the
   GitHub repo page).
3. Save and exit: press **Ctrl+O**, then **Enter**, then **Ctrl+X**.

## Configure (required)

Open the script and edit the two settings near the top:

```bash
nano /root/monitor_vms.sh
```

```bash
# REQUIRED: Enter host node name and VM IDs to monitor.
HOST_NODE="pve"                          # your Proxmox node name
MONITOR_VMS=("101" "102" "103" "104")    # the VM IDs to watch
```

- **`HOST_NODE`** — your node's name. Find it with `hostname`, or read it from
  the left sidebar of the Proxmox web interface.
- **`MONITOR_VMS`** — the list of VM IDs to watch, separated by spaces. **Wrap
  each ID in its own pair of quotes**, exactly as shown above (an unmatched
  quote will break the whole script).

Save and exit again (**Ctrl+O**, **Enter**, **Ctrl+X**).

## Make it executable

```bash
chmod +x /root/monitor_vms.sh
```

## Test it

Run it once by hand before scheduling it:

```bash
/root/monitor_vms.sh
```

You should see lines such as `Checking VM: 101` and `VM 101 healthy`. If you get
a `syntax error`, re-check the `MONITOR_VMS` line — every ID needs both an
opening and a closing quote.

## Schedule it with cron (every 15 minutes)

1. Open root's crontab:

   ```bash
   crontab -e
   ```

   (The first time, it may ask which editor to use — choose **nano**.)

2. Add this line at the bottom of the file:

   ```
   */15 * * * * /root/monitor_vms.sh
   ```

3. Save and exit (**Ctrl+O**, **Enter**, **Ctrl+X**).

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
