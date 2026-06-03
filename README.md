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

### Option A — Clone the git repository

```bash
cd /root
git clone https://github.com/Xenogy/watchdog.git
cp /root/watchdog/monitor_vms.sh /root/monitor_vms.sh
```

### Option B — Paste the script with nano

1. Open a new, empty file:

   ```bash
   nano /root/monitor_vms.sh
   ```

2. Paste in the full contents of `monitor_vms.sh`
3. Save and exit: press **Ctrl+S**, then **Ctrl+X**.

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

Save and exit again (**Ctrl+S**, **Ctrl+X**).

## Make it executable

```bash
chmod +x /root/monitor_vms.sh
```

## Test it

Run it once by hand before scheduling it:

```bash
/root/monitor_vms.sh
```

You should see lines such as `Checking VM: 101` and `VM 101 healthy`.

## Schedule it with cron

1. Open root's crontab:

   ```bash
   crontab -e
   ```

   (The first time, it may ask which editor to use — choose **nano**.)

2. Add this line at the bottom of the file:

   ```
   */15 * * * * /root/monitor_vms.sh
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