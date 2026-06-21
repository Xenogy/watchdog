#!/bin/bash
set -o nounset
set -o pipefail

LOCK_FILE="/var/lock/vm_monitor.lock"
CRON_LOG_FILE="/var/log/vm-monitor-ex-cron.log"
if [[ "${VM_MONITOR_SKIP_REDIRECT:-0}" != "1" ]]; then
        exec > >(tee -a "$CRON_LOG_FILE") 2>&1
fi

# The name of THIS node (the one running the script) is auto-detected from
# Proxmox, so you normally do not need to set anything here. Only fill this in
# to override auto-detection if it ever picks the wrong name.
LOCAL_NODE=""

# VMs to monitor are selected dynamically by tag: every VM carrying this tag is
# watched. Add or remove the tag in the Proxmox UI (or with
# `qm set <vmid> --tags <tag>`) to enable/disable monitoring for a VM without
# editing this script. Matching is case-insensitive.
WATCHDOG_TAG="watchdog"

# While the watchdog is actively restarting a VM it adds this transient tag to that VM
WATCHDOG_ACTIVE_TAG="watchdog-active"
TAG_DURING_CHECK=0

# Optional cluster-wide mode.
#   0 (default) - only manage VMs on LOCAL_NODE, using local commands exactly as
#                 before.
#   1           - discover tagged VMs across the whole cluster and manage VMs on
#                 other nodes over SSH. Run the watchdog from a single node.
# Proxmox configures passwordless root SSH between cluster nodes by default, so
# no extra setup is normally needed.
CLUSTER_WIDE=0
SSH_CONNECT_TIMEOUT_SECONDS=10

LOG_FILE="/var/log/vm_monitor.log"

# Root of the Proxmox cluster filesystem (pmxcfs). VM configs live under
# $PVE_CONF_BASE/nodes/<node>/qemu-server/<vmid>.conf and are replicated to every
# node, so tags can be read from here directly. You should never need to change
# this on a real Proxmox host.
PVE_CONF_BASE="/etc/pve"

# Detection tuning.
HIGH_CPU_THRESHOLD=99
LOW_CPU_THRESHOLD=30
HIGH_CONSECUTIVE_POINTS=2
LOW_CONSECUTIVE_POINTS=5
SAMPLE_WINDOW_SECONDS=600
LOW_CPU_BOOT_GRACE_SECONDS=240
ENABLE_LOW_CPU_RESTART=1
LOW_CPU_FORCE_STOP=1

# Restart tuning.
SHUTDOWN_TIMEOUT_SECONDS=30
FORCE_STOP_TIMEOUT_SECONDS=90
START_TIMEOUT_SECONDS=60
RESTART_RETRIES=3
RETRY_DELAY_SECONDS=5
MAX_PARALLEL_RESTARTS=1
RESTART_COOLDOWN_SECONDS=1800
RESTART_STATE_DIR="/run/vm_monitor"

# Direct-kill fallback. When `qm stop` cannot run its task worker (headless
# worker-fork failures that log "got no worker upid"/"failed to tcsetpgrp"), the
# VM is never actually told to stop even though its kvm process is alive and
# signalable. As a last resort, signal the kvm process from its pidfile directly
# -- SIGTERM first (a stalled qemu may ignore it), then SIGKILL -- which needs no
# task worker and no terminal. Set DIRECT_KILL_ENABLED=0 to disable.
DIRECT_KILL_ENABLED=1
DIRECT_KILL_TERM_WAIT_SECONDS=8
DIRECT_KILL_KILL_WAIT_SECONDS=15

# Command hard timeouts to avoid indefinite hangs.
QM_STATUS_TIMEOUT_SECONDS=8
QM_ACTION_TIMEOUT_SECONDS=60
PVESH_CMD_TIMEOUT_SECONDS=20
QM_STALE_PROCESS_SECONDS=600
ENABLE_STALE_QM_CLEANUP=0
VM_LOCK_CHECK_TIMEOUT_SECONDS=5
VM_LOCK_CLEAR_WAIT_SECONDS=20
VM_LOCK_CLEAR_RETRY_SECONDS=2
BLOCK_RESTARTS_WHEN_STUCK_TASKS=1

# How often run_with_timeout polls a child for completion. This is the floor on
# how long every pvesh/qm/lsof call takes, so it must stay well under a second:
# a typical pvesh call returns in well under 100ms, and the script makes many of
# them sequentially (one or more per VM). A coarse 1s poll would add ~1s to every
# single call. Accepts fractional seconds (GNU sleep).
WAIT_POLL_INTERVAL_SECONDS=0.1

MAX_CONSECUTIVE_POINTS=$HIGH_CONSECUTIVE_POINTS
if (( LOW_CONSECUTIVE_POINTS > MAX_CONSECUTIVE_POINTS )); then
        MAX_CONSECUTIVE_POINTS=$LOW_CONSECUTIVE_POINTS
fi

RESTART_PIDS=()
declare -A RESTART_META=()

# Populated fresh on every run by discover_watchdog_vms.
WATCHDOG_VMS=()

# Maps each monitored VM id to the cluster node that hosts it. Only populated in
# cluster-wide mode; node-local mode leaves it empty so every lookup defaults to
# LOCAL_NODE.
declare -A VM_NODE=()

# Maps each cluster node name to its IP (from /etc/pve/.members), so remote SSH
# targets the IP directly rather than the bare node name -- which often does not
# resolve via DNS/hosts. Only populated in cluster-wide mode.
declare -A NODE_IP=()

# Snapshot of each monitored VM's tag string as read during discovery, so the
# startup stale-tag sweep can check for a leftover active tag without paying for
# a second per-VM config read.
declare -A VM_TAGS_SNAPSHOT=()

log() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Determine the name of the node this script is running on. Proxmox exposes it
# as the symlink /etc/pve/local -> nodes/<thisnode>; fall back to the system
# hostname if that is unavailable. Prints the node name (empty on failure).
detect_local_node() {
        local target=""

        target=$(readlink -f /etc/pve/local 2>/dev/null)
        if [[ -n "$target" ]]; then
                printf '%s' "${target##*/}"
                return 0
        fi

        hostname -s 2>/dev/null || hostname 2>/dev/null || true
}

# Populate NODE_IP (node name -> IP) from Proxmox's cluster membership file, so
# remote SSH can target a node's IP directly. This sidesteps clusters where the
# bare node name does not resolve via DNS/hosts (the common case). Best-effort:
# if the data is missing, run_on_vm_node falls back to the node name.
load_node_ips() {
        local members="/etc/pve/.members"
        local name=""
        local ip=""

        NODE_IP=()

        if [[ ! -r "$members" ]]; then
                return 0
        fi

        while IFS=$'\t' read -r name ip; do
                if [[ -n "$name" && -n "$ip" ]]; then
                        NODE_IP["$name"]="$ip"
                fi
        done < <(/usr/bin/jq -r '.nodelist // {} | to_entries[] | "\(.key)\t\(.value.ip // "")"' "$members" 2>/dev/null)

        return 0
}

# Render the resolved node->IP map for logging (e.g. "m1=10.0.0.2 gpu1=10.0.0.1").
format_node_ips() {
        local name=""
        local out=""

        for name in "${!NODE_IP[@]}"; do
                out+="${name}=${NODE_IP[$name]} "
        done

        printf '%s' "${out% }"
}

acquire_lock() {
        if [[ "${VM_MONITOR_LOCK_HELD:-0}" == "1" ]]; then
                return
        fi

        /usr/bin/flock -n -o "$LOCK_FILE" env VM_MONITOR_LOCK_HELD=1 VM_MONITOR_SKIP_REDIRECT=1 "$0" "$@"
        local rc=$?
        if (( rc == 1 )); then
                log "Another watchdog run is already active. Exiting."
                exit 0
        fi

        exit "$rc"
}

run_with_timeout() {
        local timeout_seconds="$1"
        shift
        local child_pid=0
        local deadline=0

        # Run detached in a new session (setsid) so a timeout can SIGKILL the whole
        # process group, AND with stdin redirected from /dev/null so the wrapped
        # command is fully non-interactive. The </dev/null is load-bearing for qm:
        # `qm stop/start/shutdown` fork a task worker, and Proxmox only attempts
        # terminal job-control (tcsetpgrp) for that worker when stdin is a tty. When
        # the script is run by hand, stdin is the operator's terminal -- which
        # setsid has just detached this process from -- so tcsetpgrp fails with
        # "Inappropriate ioctl for device" and the worker never starts ("got no
        # worker upid"), breaking the qm action. Forcing stdin to /dev/null makes a
        # by-hand run behave like cron (where stdin is already /dev/null), so qm
        # works in both. (This generalises the `ssh -n` in run_on_vm_node.)
        /usr/bin/setsid "$@" </dev/null &
        child_pid=$!
        deadline=$(( $(date +%s) + timeout_seconds ))

        while kill -0 "$child_pid" 2>/dev/null; do
                if (( $(date +%s) >= deadline )); then
                        kill -TERM "-$child_pid" 2>/dev/null || kill -TERM "$child_pid" 2>/dev/null || true
                        sleep 1
                        kill -KILL "-$child_pid" 2>/dev/null || kill -KILL "$child_pid" 2>/dev/null || true

                        if ! kill -0 "$child_pid" 2>/dev/null; then
                                wait "$child_pid" 2>/dev/null || true
                        fi

                        return 124
                fi

                sleep "$WAIT_POLL_INTERVAL_SECONDS"
        done

        wait "$child_pid"
}

# Run a node-local command (qm/lsof/ps/...) against the node that hosts a VM,
# with a hard timeout. Runs directly when the target is the local node (always
# the case in node-local mode); otherwise over SSH to root@<node>. Proxmox sets
# up passwordless root SSH between cluster nodes, so no extra setup is normally
# needed. Stdout is returned exactly as if run locally, so the awk/jq pipelines
# downstream are unchanged. Each remote call opens its own SSH connection; on an
# SSH/connect failure the command simply yields no output and a non-zero status,
# which the callers already treat as "couldn't read", skipping the VM safely.
#
# The node comes from VM_NODE, a discovery-time snapshot of /cluster/resources.
# If a VM live-migrates mid-cycle the snapshot can be briefly stale and a remote
# qm/pvesh call may target the prior node; that read simply fails and the VM is
# skipped for the cycle (never restarted on the wrong node), and the next run
# re-discovers the new node. So this is self-healing and non-destructive.
run_on_vm_node() {
        local node="$1"
        local timeout_seconds="$2"
        shift 2

        if [[ -n "$node" && "$node" != "$LOCAL_NODE" ]]; then
                # Prefer the node's IP (node names often don't resolve via
                # DNS/hosts); fall back to the name if no IP was discovered.
                local target="${NODE_IP[$node]:-$node}"
                # -n points ssh's stdin at /dev/null. Without it ssh inherits and
                # drains the stdin of an enclosing `while read` loop (e.g.
                # is_vm_lock_stuck_in_d_state iterating lock-holder PIDs), which
                # would truncate that loop to its first iteration.
                run_with_timeout "$timeout_seconds" /usr/bin/ssh -n \
                        -o BatchMode=yes \
                        -o ConnectTimeout="$SSH_CONNECT_TIMEOUT_SECONDS" \
                        -o StrictHostKeyChecking=accept-new \
                        -o LogLevel=ERROR \
                        "root@$target" "$@"
        else
                run_with_timeout "$timeout_seconds" "$@"
        fi
}

is_monitored_vm() {
        local target_vm_id="$1"
        local vm_id=""

        for vm_id in "${WATCHDOG_VMS[@]}"; do
                if [[ "$vm_id" == "$target_vm_id" ]]; then
                        return 0
                fi
        done

        return 1
}

# Read a VM's tags from its live config and print the raw (semicolon-separated)
# tag string to stdout. Returns 0 when the config was read successfully (the tag
# string may legitimately be empty), and non-zero when the lookup itself failed
# or timed out. Callers must NOT treat a failed read as "no tags": that would
# abandon a VM precisely when the node is too busy to answer quickly.
#
# Fast path: read the tags straight from the VM's config file. /etc/pve is the
# pmxcfs cluster filesystem and is replicated to every node, so a VM's config is
# readable here whether it lives on this node or another -- no SSH, and no pvesh
# process spawned per VM (that per-call cost dominated discovery and the sweep).
# The read is still wrapped in run_with_timeout, like every other cluster access,
# so a wedged pmxcfs cannot hang the run. The awk reads only the main config
# section (it stops at the first "[snapshot]" header), strips any trailing CR,
# and prints the tags value; it exits non-zero if it cannot read the file. We
# trust the fast path only when awk actually read the file (rc 0) AND the file is
# non-empty -- any other outcome (timeout, read error, truncated/empty file)
# falls through to the API, and a failed API read returns non-zero ("unknown"),
# so a failed read is never silently reported as "no tags".
get_vm_tags() {
        local vm_id="$1"
        local node="${VM_NODE[$vm_id]:-$LOCAL_NODE}"
        local conf="$PVE_CONF_BASE/nodes/$node/qemu-server/$vm_id.conf"
        local tags=""
        local raw=""
        local rc=0

        tags=$(run_with_timeout "$PVESH_CMD_TIMEOUT_SECONDS" /usr/bin/awk '
                /^\[/ { exit }
                /^tags:[[:space:]]*/ {
                        sub(/^tags:[[:space:]]*/, "")
                        sub(/\r$/, "")
                        print
                        exit
                }
        ' "$conf" 2>/dev/null)
        rc=$?
        if (( rc == 0 )) && [[ -s "$conf" ]]; then
                printf '%s' "$tags"
                return 0
        fi

        raw=$(run_with_timeout "$PVESH_CMD_TIMEOUT_SECONDS" /usr/bin/pvesh get "/nodes/$node/qemu/$vm_id/config" --output-format json 2>/dev/null)
        rc=$?
        if (( rc != 0 )) || [[ -z "$raw" ]]; then
                return 1
        fi

        printf '%s' "$raw" | /usr/bin/jq -r '.tags // ""' 2>/dev/null
        return 0
}

# Split a raw Proxmox tag string into its individual tags, one per line (empties
# dropped). Proxmox stores tags separated by ';'; we also tolerate ',' and
# whitespace. Splitting with `read -ra` (rather than an unquoted `for`) keeps
# tags that contain glob characters from being expanded against the filesystem.
split_tags() {
        local tags="$1"
        local parts=()
        local tag=""
        local IFS=$'; \t,'

        read -ra parts <<< "$tags"
        for tag in "${parts[@]}"; do
                if [[ -n "$tag" ]]; then
                        printf '%s\n' "$tag"
                fi
        done
}

# Return 0 if the given tag string contains `want` as a whole tag, matched
# case-insensitively (so "watchdog", "Watchdog", etc. all count, while
# "watchdog-test" does not match "watchdog").
tags_contain_tag() {
        local tags="$1"
        local want="${2,,}"
        local tag=""

        while IFS= read -r tag; do
                if [[ "${tag,,}" == "$want" ]]; then
                        return 0
                fi
        done < <(split_tags "$tags")

        return 1
}

# Return 0 if the given tag string contains the watchdog tag.
tags_contain_watchdog() {
        tags_contain_tag "$1" "$WATCHDOG_TAG"
}

# Re-emit a tag string as a normalized ';'-joined list, optionally dropping every
# case-insensitive match of `drop` and/or appending `add` when it is not already
# present (also case-insensitive). Either may be empty. This is the read side of
# the read-modify-write used to add/remove the transient active tag without
# disturbing a VM's other tags.
rebuild_tags() {
        local tags="$1"
        local drop="${2,,}"
        local add="$3"
        local kept=()
        local tag=""
        local have_add=0

        while IFS= read -r tag; do
                if [[ -n "$drop" && "${tag,,}" == "$drop" ]]; then
                        continue
                fi
                if [[ -n "$add" && "${tag,,}" == "${add,,}" ]]; then
                        have_add=1
                fi
                kept+=("$tag")
        done < <(split_tags "$tags")

        if [[ -n "$add" && "$have_add" -eq 0 ]]; then
                kept+=("$add")
        fi

        local IFS=";"
        printf '%s' "${kept[*]}"
}

# Re-check, against the live config, whether a VM currently carries the watchdog
# tag. Used for discovery and for the re-check immediately before acting on a VM
# (so a tag removed mid-run is honoured). Exit codes:
#   0 - tag is present
#   1 - config read succeeded and the tag is absent
#   2 - config read failed/timed out (tag state unknown)
# Distinguishing 2 from 1 lets callers avoid treating a transient pvesh failure
# as "tag removed".
vm_has_watchdog_tag() {
        local vm_id="$1"
        local tags=""
        local rc=0

        tags=$(get_vm_tags "$vm_id")
        rc=$?
        if (( rc != 0 )); then
                return 2
        fi

        if tags_contain_watchdog "$tags"; then
                return 0
        fi

        return 1
}

# Write a VM's tag list, replacing it wholesale with `new_tags` (Proxmox has no
# atomic per-tag add/remove, so callers read-modify-write the full string). Uses
# pvesh, which proxies through the cluster API and so reaches VMs on any node in
# both node-local and cluster-wide mode -- matching how get_vm_tags reads them.
# Returns pvesh's exit status.
write_vm_tags() {
        local vm_id="$1"
        local new_tags="$2"
        local node="${VM_NODE[$vm_id]:-$LOCAL_NODE}"

        run_with_timeout "$PVESH_CMD_TIMEOUT_SECONDS" /usr/bin/pvesh set "/nodes/$node/qemu/$vm_id/config" --tags "$new_tags" >/dev/null 2>&1
}

# Add WATCHDOG_ACTIVE_TAG to a VM (read-modify-write), preserving its other tags.
# `context` tailors the log message to why the tag is going on (e.g. a restart vs
# a plain check). Best-effort and never fatal: a failure here must not stop a
# restart, so the worst case is that the visibility tag is missing, not that
# recovery is skipped.
add_active_tag() {
        local vm_id="$1"
        local context="${2:-restart in progress}"
        local tags=""

        if [[ -z "$WATCHDOG_ACTIVE_TAG" ]]; then
                return 0
        fi

        tags=$(get_vm_tags "$vm_id")
        if (( $? != 0 )); then
                log "VM $vm_id: could not read tags to add '$WATCHDOG_ACTIVE_TAG' ($context); continuing without it."
                return 0
        fi

        if tags_contain_tag "$tags" "$WATCHDOG_ACTIVE_TAG"; then
                return 0
        fi

        if write_vm_tags "$vm_id" "$(rebuild_tags "$tags" "" "$WATCHDOG_ACTIVE_TAG")"; then
                log "VM $vm_id: added '$WATCHDOG_ACTIVE_TAG' tag ($context)."
        else
                log "VM $vm_id: failed to add '$WATCHDOG_ACTIVE_TAG' tag ($context); continuing."
        fi

        return 0
}

# Remove WATCHDOG_ACTIVE_TAG from a VM (read-modify-write), leaving its other
# tags intact. `context` tailors the log message (e.g. "restart finished" vs a
# stale tag swept up at startup). Best-effort; a failure leaves the tag lingering
# but is logged so it can be noticed.
remove_active_tag() {
        local vm_id="$1"
        local context="${2:-restart finished}"
        local tags=""

        if [[ -z "$WATCHDOG_ACTIVE_TAG" ]]; then
                return 0
        fi

        tags=$(get_vm_tags "$vm_id")
        if (( $? != 0 )); then
                log "VM $vm_id: could not read tags to remove '$WATCHDOG_ACTIVE_TAG' ($context); it may linger."
                return 0
        fi

        if ! tags_contain_tag "$tags" "$WATCHDOG_ACTIVE_TAG"; then
                return 0
        fi

        if write_vm_tags "$vm_id" "$(rebuild_tags "$tags" "$WATCHDOG_ACTIVE_TAG" "")"; then
                log "VM $vm_id: removed '$WATCHDOG_ACTIVE_TAG' tag ($context)."
        else
                log "VM $vm_id: failed to remove '$WATCHDOG_ACTIVE_TAG' tag ($context); it may linger."
        fi

        return 0
}

# Sweep up WATCHDOG_ACTIVE_TAG left on any monitored VM by a previous run that
# was killed mid-restart. Safe to run only at startup, before any restart begins:
# the flock guarantees no other watchdog instance is running, so any active tag
# present now is necessarily stale.
#
# To stay cheap, this reuses the tag strings discovery already read
# (VM_TAGS_SNAPSHOT) instead of re-reading every VM's config: in the common case
# (no leftover tags) it makes no Proxmox calls at all, and it only reads+writes
# for a VM that genuinely still carries the active tag.
clear_stale_active_tags() {
        local vm_id=""

        if [[ -z "$WATCHDOG_ACTIVE_TAG" ]]; then
                return 0
        fi

        for vm_id in "${WATCHDOG_VMS[@]}"; do
                if tags_contain_tag "${VM_TAGS_SNAPSHOT[$vm_id]:-}" "$WATCHDOG_ACTIVE_TAG"; then
                        remove_active_tag "$vm_id" "stale tag from an interrupted previous run"
                fi
        done
}

# Populate WATCHDOG_VMS (and, in cluster mode, VM_NODE) with the VMs carrying
# the watchdog tag. Dispatches to the node-local or cluster-wide enumerator.
# Returns non-zero only when the VM list cannot be read at all, so the caller
# can skip the cycle instead of mistaking a failed lookup for "nothing tagged".
discover_watchdog_vms() {
        WATCHDOG_VMS=()
        VM_NODE=()
        VM_TAGS_SNAPSHOT=()

        if [[ "$CLUSTER_WIDE" == "1" ]]; then
                discover_watchdog_vms_cluster
                return $?
        fi

        discover_watchdog_vms_node
        return $?
}

# Node-local discovery: enumerate the VMs on LOCAL_NODE and keep the tagged ones.
# A per-VM tag read that fails is logged and that VM is left out for this cycle
# (reconsidered next run) rather than being silently dropped or restarted while
# its tag state is unknown.
discover_watchdog_vms_node() {
        local index_json=""
        local vm_ids=()
        local vm_id=""
        local tags=""
        local rc=0

        index_json=$(run_with_timeout "$PVESH_CMD_TIMEOUT_SECONDS" /usr/bin/pvesh get "/nodes/$LOCAL_NODE/qemu" --output-format json 2>/dev/null)

        if [[ -z "$index_json" ]] || ! echo "$index_json" | /usr/bin/jq -e 'type == "array"' >/dev/null 2>&1; then
                log "Unable to enumerate VMs on node '$LOCAL_NODE' (pvesh failed or returned no data). Skipping this cycle."
                return 1
        fi

        # Skip templates: they never run and must never be "restarted". The flag
        # may render as a number, string or boolean across PVE versions, so the
        # match is type-agnostic.
        readarray -t vm_ids < <(echo "$index_json" | /usr/bin/jq -r '.[] | select((.template // false) | tostring | (. == "1" or . == "true") | not) | .vmid' 2>/dev/null | sort -n)

        for vm_id in "${vm_ids[@]}"; do
                if [[ -z "$vm_id" ]]; then
                        continue
                fi

                tags=$(get_vm_tags "$vm_id")
                rc=$?
                if (( rc != 0 )); then
                        log "Unable to read tags for VM $vm_id (pvesh failed); excluding it from this cycle."
                        continue
                fi

                if tags_contain_watchdog "$tags"; then
                        WATCHDOG_VMS+=("$vm_id")
                        VM_TAGS_SNAPSHOT["$vm_id"]="$tags"
                fi
        done

        return 0
}

# Cluster-wide discovery: one `pvesh get /cluster/resources` call returns every
# guest on every node together with its node, type, template flag and tags, so
# we can select the tagged QEMU VMs and remember which node hosts each. The tag
# string comes straight from this snapshot; the per-VM re-check before acting
# (vm_has_watchdog_tag) still does a fresh read, so freshness is preserved.
discover_watchdog_vms_cluster() {
        local resources_json=""
        local vmid=""
        local node=""
        local tags=""

        resources_json=$(run_with_timeout "$PVESH_CMD_TIMEOUT_SECONDS" /usr/bin/pvesh get /cluster/resources --type vm --output-format json 2>/dev/null)

        if [[ -z "$resources_json" ]] || ! echo "$resources_json" | /usr/bin/jq -e 'type == "array"' >/dev/null 2>&1; then
                log "Unable to enumerate cluster VMs (pvesh get /cluster/resources failed or returned no data). Skipping this cycle."
                return 1
        fi

        # Keep QEMU VMs only (skip containers and non-guest resources) and skip
        # templates, type-agnostically as above.
        while IFS=$'\t' read -r vmid node tags; do
                if [[ -z "$vmid" || -z "$node" ]]; then
                        continue
                fi

                if tags_contain_watchdog "$tags"; then
                        WATCHDOG_VMS+=("$vmid")
                        VM_NODE["$vmid"]="$node"
                        VM_TAGS_SNAPSHOT["$vmid"]="$tags"
                fi
        done < <(
                echo "$resources_json" | /usr/bin/jq -r '
                        .[]
                        | select(.type == "qemu")
                        | select((.template // false) | tostring | (. == "1" or . == "true") | not)
                        | [(.vmid | tostring), .node, (.tags // "")]
                        | @tsv' 2>/dev/null | sort -t $'\t' -k1,1n
        )

        return 0
}

# Render the monitored VM list for logging. In cluster mode each entry shows the
# hosting node (e.g. "101@pve1"); in node-local mode VM_NODE is empty so it
# falls back to LOCAL_NODE.
format_watchdog_vms() {
        local vm_id=""
        local out=""

        for vm_id in "${WATCHDOG_VMS[@]}"; do
                out+="${vm_id}@${VM_NODE[$vm_id]:-$LOCAL_NODE} "
        done

        printf '%s' "${out% }"
}

# Off by default. Note: this inspects the LOCAL node's process table only, so in
# cluster-wide mode it cleans stale qm helpers on the node running the watchdog,
# not on remote nodes.
cleanup_stale_qm_processes() {
        if (( ENABLE_STALE_QM_CLEANUP != 1 )); then
                return
        fi

        local line=""
        local pid=""
        local etimes=""
        local args=""
        local vm_id=""

        while IFS= read -r line; do
                pid=$(echo "$line" | awk '{print $1}')
                etimes=$(echo "$line" | awk '{print $2}')
                args=$(echo "$line" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+//')

                if [[ ! "$args" =~ /usr/sbin/qm[[:space:]]+(start|stop|shutdown)[[:space:]]+([0-9]+) ]]; then
                        continue
                fi

                vm_id="${BASH_REMATCH[2]}"

                if (( etimes < QM_STALE_PROCESS_SECONDS )); then
                        continue
                fi

                if ! is_monitored_vm "$vm_id"; then
                        continue
                fi

                log "Killing stale qm helper pid=$pid vmid=$vm_id etimes=${etimes}s"
                kill -TERM "$pid" 2>/dev/null || true
                sleep 1
                kill -KILL "$pid" 2>/dev/null || true
        done < <(ps -eo pid=,etimes=,args= | grep -E '/usr/sbin/qm (start|stop|shutdown) [0-9]+' | grep -v grep)
}

is_vm_lock_held() {
        local vm_id="$1"
        local node="${VM_NODE[$vm_id]:-$LOCAL_NODE}"
        local lock_file="/var/lock/qemu-server/lock-${vm_id}.conf"
        local holder_count=0

        holder_count=$(run_on_vm_node "$node" "$VM_LOCK_CHECK_TIMEOUT_SECONDS" /usr/bin/lsof "$lock_file" 2>/dev/null | awk 'NR>1 {count+=1} END {print count+0}')
        if [[ ! "$holder_count" =~ ^[0-9]+$ ]]; then
                return 1
        fi

        (( holder_count > 0 ))
}

get_vm_lock_holders() {
        local vm_id="$1"
        local node="${VM_NODE[$vm_id]:-$LOCAL_NODE}"
        local lock_file="/var/lock/qemu-server/lock-${vm_id}.conf"

        run_on_vm_node "$node" "$VM_LOCK_CHECK_TIMEOUT_SECONDS" /usr/bin/lsof "$lock_file" 2>/dev/null | awk 'NR>1 {printf "%s(pid=%s) ", $1, $2}'
}

get_vm_lock_holder_pids() {
        local vm_id="$1"
        local node="${VM_NODE[$vm_id]:-$LOCAL_NODE}"
        local lock_file="/var/lock/qemu-server/lock-${vm_id}.conf"

        run_on_vm_node "$node" "$VM_LOCK_CHECK_TIMEOUT_SECONDS" /usr/bin/lsof "$lock_file" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u
}

get_process_state() {
        local node="$1"
        local pid="$2"

        run_on_vm_node "$node" "$VM_LOCK_CHECK_TIMEOUT_SECONDS" /usr/bin/ps -o state= -p "$pid" 2>/dev/null | awk 'NR==1 {print $1}'
}

is_vm_lock_stuck_in_d_state() {
        local vm_id="$1"
        local node="${VM_NODE[$vm_id]:-$LOCAL_NODE}"
        local pid=""
        local state=""

        while IFS= read -r pid; do
                if [[ -z "$pid" ]]; then
                        continue
                fi

                state=$(get_process_state "$node" "$pid")
                if [[ "$state" == "D" ]]; then
                        return 0
                fi
        done < <(get_vm_lock_holder_pids "$vm_id")

        return 1
}

clear_vm_lock_if_possible() {
        local vm_id="$1"
        local node="${VM_NODE[$vm_id]:-$LOCAL_NODE}"
        local deadline=0

        if ! is_vm_lock_held "$vm_id"; then
                return 0
        fi

        log "VM $vm_id lock holder(s): $(get_vm_lock_holders "$vm_id")"
        run_on_vm_node "$node" "$QM_ACTION_TIMEOUT_SECONDS" /usr/sbin/qm unlock "$vm_id" >/dev/null 2>&1 || true

        deadline=$(( $(date +%s) + VM_LOCK_CLEAR_WAIT_SECONDS ))
        while (( $(date +%s) < deadline )); do
                if ! is_vm_lock_held "$vm_id"; then
                        log "VM $vm_id lock cleared."
                        return 0
                fi

                sleep "$VM_LOCK_CLEAR_RETRY_SECONDS"
        done

        if is_vm_lock_stuck_in_d_state "$vm_id"; then
                log "VM $vm_id lock holder is stuck in D state; watchdog cannot clear this lock automatically. Host reboot is usually required."
        else
                log "VM $vm_id lock still held after unlock attempt: $(get_vm_lock_holders "$vm_id")"
        fi

        return 1
}

# Read the running kvm process PID for a VM from its Proxmox pidfile. Prints the
# PID (empty when the file is missing/unreadable -- e.g. the VM is not actually
# running on this node). Read-only; used purely for stop-failure diagnostics.
get_vm_kvm_pid() {
        local vm_id="$1"
        local node="${VM_NODE[$vm_id]:-$LOCAL_NODE}"
        local pidfile="/run/qemu-server/${vm_id}.pid"
        local pid=""

        pid=$(run_on_vm_node "$node" "$VM_LOCK_CHECK_TIMEOUT_SECONDS" /bin/cat "$pidfile" 2>/dev/null | awk 'NR==1 {print $1}')
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
                printf '%s' "$pid"
        fi
}

# Force-stop a VM, capturing qm's exit code and any error text so a failed stop
# is diagnosable -- the bare command discards both behind >/dev/null, leaving the
# log unable to say anything beyond "did not stop". Tries --skiplock first and
# only falls back to a plain stop when that attempt actually failed, mirroring
# the previous `... --skiplock 1 || qm stop || true` chain. Returns the exit
# status of the last qm invocation; logs every non-zero result with its output.
force_stop_vm() {
        local vm_id="$1"
        local node="$2"
        local output=""
        local rc=0

        output=$(run_on_vm_node "$node" "$QM_ACTION_TIMEOUT_SECONDS" /usr/sbin/qm stop "$vm_id" --skiplock 1 2>&1)
        rc=$?
        if (( rc != 0 )); then
                log "VM $vm_id 'qm stop --skiplock' exited $rc: $(printf '%s' "$output" | tr '\n' ' ')"
                output=$(run_on_vm_node "$node" "$QM_ACTION_TIMEOUT_SECONDS" /usr/sbin/qm stop "$vm_id" 2>&1)
                rc=$?
                if (( rc != 0 )); then
                        log "VM $vm_id 'qm stop' fallback exited $rc: $(printf '%s' "$output" | tr '\n' ' ')"
                fi
        fi

        return "$rc"
}

# Emit the lock-holder / process-state context the watchdog already gathers, so a
# "did not stop" line is actionable instead of opaque. It distinguishes the
# likely causes: a held config lock, a lock holder wedged in uninterruptible (D)
# I/O sleep, or a live kvm process that ignored the stop (itself possibly in D
# state). A process in D state cannot be killed until its I/O unblocks, so no
# amount of retrying qm stop will help -- exactly the case where a manual stop
# moments later "just works" once the I/O has cleared.
log_stop_failure_diagnostics() {
        local vm_id="$1"
        local node="${VM_NODE[$vm_id]:-$LOCAL_NODE}"
        local kvm_pid=""
        local kvm_state=""

        if is_vm_lock_held "$vm_id"; then
                if is_vm_lock_stuck_in_d_state "$vm_id"; then
                        log "VM $vm_id stop diagnostics: config lock held by [$(get_vm_lock_holders "$vm_id")] with a holder in uninterruptible D state (I/O wait); cannot be cleared until that I/O completes."
                else
                        log "VM $vm_id stop diagnostics: config lock held by [$(get_vm_lock_holders "$vm_id")]."
                fi
        else
                log "VM $vm_id stop diagnostics: no config lock held."
        fi

        kvm_pid=$(get_vm_kvm_pid "$vm_id")
        if [[ -n "$kvm_pid" ]]; then
                kvm_state=$(get_process_state "$node" "$kvm_pid")
                log "VM $vm_id stop diagnostics: kvm pid $kvm_pid in process state '${kvm_state:-unknown}' (D = uninterruptible I/O wait, unkillable until the I/O completes)."
        else
                log "VM $vm_id stop diagnostics: no kvm pidfile found (/run/qemu-server/${vm_id}.pid); VM may have stopped just after the timeout, or is not running on $node."
        fi
}

# Direct, qm-independent force stop: signal the VM's kvm process straight from its
# pidfile. Used as a fallback when `qm stop` cannot run its task worker (e.g. the
# headless worker-fork failure that logs "got no worker upid" -- the kvm process
# itself is still a normal, signalable process). SIGTERM first, then SIGKILL.
# Refuses to act unless the pid is alive, not wedged in uninterruptible D state (a
# signal cannot reap it), and its command line still belongs to this VM (guards
# against signalling a recycled pid). Returns 0 only once the VM is confirmed
# stopped; 1 (no-op or still running) otherwise.
force_kill_vm_process() {
        local vm_id="$1"
        local node="${VM_NODE[$vm_id]:-$LOCAL_NODE}"
        local pid=""
        local state=""
        local args=""

        if (( DIRECT_KILL_ENABLED != 1 )); then
                return 1
        fi

        pid=$(get_vm_kvm_pid "$vm_id")
        if [[ -z "$pid" ]]; then
                log "VM $vm_id direct-kill: no kvm pidfile found; nothing to signal (already stopped, or not running on $node)."
                return 1
        fi

        state=$(get_process_state "$node" "$pid")
        if [[ "$state" == "D" ]]; then
                log "VM $vm_id direct-kill: kvm pid $pid is in uninterruptible D state; a signal cannot reap it until its I/O completes. Skipping."
                return 1
        fi

        # Confirm the pid is still this VM's kvm process before signalling it. The
        # kvm command line carries both `-id <vmid>` and the pidfile path, so a
        # recycled pid (a different process that inherited the number) won't match.
        args=$(run_on_vm_node "$node" "$VM_LOCK_CHECK_TIMEOUT_SECONDS" /usr/bin/ps -o args= -p "$pid" 2>/dev/null)
        if [[ "$args" != *"/$vm_id.pid"* && "$args" != *" -id $vm_id"* ]]; then
                log "VM $vm_id direct-kill: pid $pid does not look like this VM's kvm process (args: ${args:-<unreadable>}); refusing to kill."
                return 1
        fi

        log "VM $vm_id direct-kill: escalating to signal kvm pid $pid (qm stop could not run its task worker)."
        run_on_vm_node "$node" "$QM_ACTION_TIMEOUT_SECONDS" /bin/kill -TERM "$pid" >/dev/null 2>&1 || true
        if wait_for_vm_state "$vm_id" "stopped" "$DIRECT_KILL_TERM_WAIT_SECONDS"; then
                log "VM $vm_id stopped after SIGTERM to kvm pid $pid."
                return 0
        fi

        run_on_vm_node "$node" "$QM_ACTION_TIMEOUT_SECONDS" /bin/kill -KILL "$pid" >/dev/null 2>&1 || true
        if wait_for_vm_state "$vm_id" "stopped" "$DIRECT_KILL_KILL_WAIT_SECONDS"; then
                log "VM $vm_id stopped after SIGKILL to kvm pid $pid."
                return 0
        fi

        log "VM $vm_id direct-kill: still not stopped after SIGKILL to kvm pid $pid."
        return 1
}

host_has_stuck_vm_tasks() {
        local stuck_count=0

        stuck_count=$(ps -eo state=,args= | awk '/^D / && /task UPID:.*:qm(start|stop|shutdown):/ {count+=1} END {print count+0}')
        if [[ ! "$stuck_count" =~ ^[0-9]+$ ]]; then
                return 1
        fi

        (( stuck_count > 0 ))
}

is_restart_in_cooldown() {
        local vm_id="$1"
        local reason="$2"
        local stamp_path=""
        local now=0
        local last=0
        local age=0

        if [[ "$reason" != "low_cpu_stall" ]]; then
                return 1
        fi

        if (( RESTART_COOLDOWN_SECONDS <= 0 )); then
                return 1
        fi

        stamp_path="${RESTART_STATE_DIR}/restart-${vm_id}.stamp"
        if [[ ! -f "$stamp_path" ]]; then
                return 1
        fi

        last=$(cat "$stamp_path" 2>/dev/null || echo "")
        if [[ ! "$last" =~ ^[0-9]+$ ]]; then
                return 1
        fi

        now=$(date +%s)
        age=$(( now - last ))
        if (( age < RESTART_COOLDOWN_SECONDS )); then
                log "Skipping restart for VM $vm_id (reason: $reason) due cooldown (${age}s < ${RESTART_COOLDOWN_SECONDS}s)."
                return 0
        fi

        return 1
}

record_restart_attempt() {
        local vm_id="$1"
        local reason="$2"
        local stamp_path="${RESTART_STATE_DIR}/restart-${vm_id}.stamp"

        if [[ "$reason" != "low_cpu_stall" ]]; then
                return
        fi

        mkdir -p "$RESTART_STATE_DIR" 2>/dev/null || true
        date +%s > "$stamp_path" 2>/dev/null || true
}

reap_finished_restarts() {
        if (( MAX_PARALLEL_RESTARTS <= 1 )); then
                return
        fi

        local active_pids=()
        local pid=""
        local meta=""

        for pid in "${RESTART_PIDS[@]}"; do
                meta="${RESTART_META[$pid]:-unknown restart}"

                if kill -0 "$pid" 2>/dev/null; then
                        active_pids+=("$pid")
                        continue
                fi

                if wait "$pid"; then
                        log "Completed $meta"
                else
                        log "Failed $meta"
                fi

                unset 'RESTART_META[$pid]'
        done

        RESTART_PIDS=("${active_pids[@]}")
}

# Decide on and dispatch a restart for a VM. Return codes tell the caller who is
# responsible for the transient active tag afterwards:
#   2 - a restart was launched in the *background* (parallel mode); it owns the
#       active tag and clears it when it finishes, so the caller must not.
#   0 - nothing is running asynchronously for this VM: either the restart ran
#       synchronously and already cleared its own tag, or the restart was skipped
#       (cooldown / stuck lock) and never touched the tag. Either way the caller
#       is free to drop a check-phase tag it added.
queue_restart() {
        local vm_id="$1"
        local reason="$2"
        local pid=""

        if (( BLOCK_RESTARTS_WHEN_STUCK_TASKS == 1 )) && is_vm_lock_held "$vm_id" && is_vm_lock_stuck_in_d_state "$vm_id"; then
                log "Skipping restart for VM $vm_id (reason: $reason) because its qemu lock holder is stuck in D state."
                return 0
        fi

        if is_restart_in_cooldown "$vm_id" "$reason"; then
                return 0
        fi

        if (( MAX_PARALLEL_RESTARTS <= 1 )); then
                log "Executing restart for VM $vm_id (reason: $reason)"
                if restart_vm "$vm_id" "$reason"; then
                        record_restart_attempt "$vm_id" "$reason"
                fi
                return 0
        fi

        while (( ${#RESTART_PIDS[@]} >= MAX_PARALLEL_RESTARTS )); do
                reap_finished_restarts
                if (( ${#RESTART_PIDS[@]} >= MAX_PARALLEL_RESTARTS )); then
                        sleep 1
                fi
        done

        log "Queueing restart for VM $vm_id (reason: $reason)"
        (
                if restart_vm "$vm_id" "$reason"; then
                        record_restart_attempt "$vm_id" "$reason"
                fi
        ) &
        pid=$!

        RESTART_PIDS+=("$pid")
        RESTART_META["$pid"]="restart VM $vm_id (reason: $reason)"
        return 2
}

wait_for_all_restarts() {
        if (( MAX_PARALLEL_RESTARTS <= 1 )); then
                return
        fi

        if (( ${#RESTART_PIDS[@]} > 0 )); then
                log "Waiting for ${#RESTART_PIDS[@]} queued restart(s) to finish"
        fi

        while (( ${#RESTART_PIDS[@]} > 0 )); do
                reap_finished_restarts
                if (( ${#RESTART_PIDS[@]} > 0 )); then
                        sleep 1
                fi
        done
}

get_vm_status() {
        local vm_id="$1"
        local node="${VM_NODE[$vm_id]:-$LOCAL_NODE}"
        run_on_vm_node "$node" "$QM_STATUS_TIMEOUT_SECONDS" /usr/sbin/qm status "$vm_id" 2>/dev/null | awk '{print $2}'
}

wait_for_vm_state() {
        local vm_id="$1"
        local target_state="$2"
        local timeout_seconds="$3"
        local deadline=$(( $(date +%s) + timeout_seconds ))
        local current_state=""

        while (( $(date +%s) < deadline )); do
                current_state=$(get_vm_status "$vm_id")
                if [[ "$current_state" == "$target_state" ]]; then
                        return 0
                fi

                sleep 2
        done

        return 1
}

get_vm_uptime_seconds() {
        local vm_id="$1"
        local node="${VM_NODE[$vm_id]:-$LOCAL_NODE}"
        local uptime

        uptime=$(run_with_timeout "$PVESH_CMD_TIMEOUT_SECONDS" /usr/bin/pvesh get "/nodes/$node/qemu/$vm_id/status/current" --output-format json 2>/dev/null | /usr/bin/jq -r '.uptime // 0' 2>/dev/null)

        if [[ "$uptime" =~ ^[0-9]+$ ]]; then
                echo "$uptime"
        else
                echo "0"
        fi
}

all_last_n_ge() {
        local threshold="$1"
        local required_count="$2"
        shift 2
        local values=("$@")
        local total_count="${#values[@]}"
        local idx=0
        local start_index=0

        if (( total_count < required_count )); then
                return 1
        fi

        start_index=$((total_count - required_count))
        for (( idx = start_index; idx < total_count; idx++ )); do
                if (( values[idx] < threshold )); then
                        return 1
                fi
        done

        return 0
}

all_last_n_lt() {
        local threshold="$1"
        local required_count="$2"
        shift 2
        local values=("$@")
        local total_count="${#values[@]}"
        local idx=0
        local start_index=0

        if (( total_count < required_count )); then
                return 1
        fi

        start_index=$((total_count - required_count))
        for (( idx = start_index; idx < total_count; idx++ )); do
                if (( values[idx] >= threshold )); then
                        return 1
                fi
        done

        return 0
}

# Public entry point for a restart. Wraps the core retry logic so the transient
# WATCHDOG_ACTIVE_TAG is added right before any qm action and removed once the
# restart finishes, on every exit path (success, failure, or mid-run tag loss).
# Runs in the foreground or inside queue_restart's background subshell; either
# way the add/remove bracket the whole attempt for this VM.
restart_vm() {
        local vm_id="$1"
        local reason="$2"
        local rc=0

        add_active_tag "$vm_id"
        restart_vm_core "$vm_id" "$reason"
        rc=$?
        remove_active_tag "$vm_id"

        return "$rc"
}

restart_vm_core() {
        local vm_id="$1"
        local reason="$2"
        local node="${VM_NODE[$vm_id]:-$LOCAL_NODE}"
        local attempt=1
        local status=""
        local start_attempted=0

        while (( attempt <= RESTART_RETRIES )); do
                # Honour a tag removed mid-restart: bail out before escalating
                # further, but only when the live config read confirms the tag
                # is gone (rc 1) -- never on an inconclusive read (rc 2), so a
                # transient pvesh hiccup can't abort a restart in progress.
                vm_has_watchdog_tag "$vm_id"
                if (( $? == 1 )); then
                        log "VM $vm_id lost the '$WATCHDOG_TAG' tag during restart (reason: $reason). Aborting further attempts."
                        return 0
                fi

                log "VM $vm_id restart attempt $attempt/$RESTART_RETRIES (reason: $reason)"

                status=$(get_vm_status "$vm_id")
                if [[ "$status" == "stopped" ]] && is_vm_lock_held "$vm_id"; then
                        log "VM $vm_id is stopped but qemu lock is still held before restart. Attempting unlock."
                        if ! clear_vm_lock_if_possible "$vm_id"; then
                                return 1
                        fi
                fi

                if [[ "$status" == "running" && "$start_attempted" -eq 1 ]]; then
                        log "VM $vm_id is running after previous start attempt. Treating restart as successful."
                        return 0
                fi

                if [[ "$status" == "running" ]]; then
                        if [[ "$reason" == "low_cpu_stall" ]] && (( LOW_CPU_FORCE_STOP == 1 )); then
                                log "VM $vm_id low-CPU restart uses direct force-stop path."
                                force_stop_vm "$vm_id" "$node" || true
                                if ! wait_for_vm_state "$vm_id" "stopped" "$FORCE_STOP_TIMEOUT_SECONDS"; then
                                        log "VM $vm_id did not stop after direct force-stop."
                                        log_stop_failure_diagnostics "$vm_id" "$node"
                                        if ! force_kill_vm_process "$vm_id" "$node"; then
                                                run_on_vm_node "$node" "$QM_ACTION_TIMEOUT_SECONDS" /usr/sbin/qm unlock "$vm_id" >/dev/null 2>&1 || true
                                                ((attempt += 1))
                                                sleep "$RETRY_DELAY_SECONDS"
                                                continue
                                        fi
                                fi
                        else
                                run_on_vm_node "$node" "$QM_ACTION_TIMEOUT_SECONDS" /usr/sbin/qm shutdown "$vm_id" --timeout "$SHUTDOWN_TIMEOUT_SECONDS" >/dev/null 2>&1 || true

                                if ! wait_for_vm_state "$vm_id" "stopped" "$SHUTDOWN_TIMEOUT_SECONDS"; then
                                        log "VM $vm_id graceful shutdown timed out. Forcing stop."
                                        force_stop_vm "$vm_id" "$node" || true
                                        if ! wait_for_vm_state "$vm_id" "stopped" "$FORCE_STOP_TIMEOUT_SECONDS"; then
                                                log "VM $vm_id did not stop after force-stop."
                                                log_stop_failure_diagnostics "$vm_id" "$node"
                                                if ! force_kill_vm_process "$vm_id" "$node"; then
                                                        run_on_vm_node "$node" "$QM_ACTION_TIMEOUT_SECONDS" /usr/sbin/qm unlock "$vm_id" >/dev/null 2>&1 || true
                                                        ((attempt += 1))
                                                        sleep "$RETRY_DELAY_SECONDS"
                                                        continue
                                                fi
                                        fi
                                fi
                        fi
                elif [[ "$status" != "stopped" ]]; then
                        log "VM $vm_id reported state '$status'. Attempting stop and recovery."
                        run_on_vm_node "$node" "$QM_ACTION_TIMEOUT_SECONDS" /usr/sbin/qm unlock "$vm_id" >/dev/null 2>&1 || true
                        run_on_vm_node "$node" "$QM_ACTION_TIMEOUT_SECONDS" /usr/sbin/qm stop "$vm_id" --skiplock 1 >/dev/null 2>&1 || true
                        wait_for_vm_state "$vm_id" "stopped" "$FORCE_STOP_TIMEOUT_SECONDS" || true
                fi

                run_on_vm_node "$node" "$QM_ACTION_TIMEOUT_SECONDS" /usr/sbin/qm unlock "$vm_id" >/dev/null 2>&1 || true
                start_attempted=1

                if run_on_vm_node "$node" "$QM_ACTION_TIMEOUT_SECONDS" /usr/sbin/qm start "$vm_id" >/dev/null 2>&1; then
                        if wait_for_vm_state "$vm_id" "running" "$START_TIMEOUT_SECONDS"; then
                                log "VM $vm_id restarted successfully."
                                return 0
                        fi
                        log "VM $vm_id start command completed but VM is not running yet."
                else
                        log "qm start failed for VM $vm_id (or timed out)."
                        if is_vm_lock_held "$vm_id"; then
                                log "VM $vm_id start blocked by qemu lock holder."
                                if ! clear_vm_lock_if_possible "$vm_id"; then
                                        if is_vm_lock_stuck_in_d_state "$vm_id"; then
                                                return 1
                                        fi
                                fi
                        fi

                        if wait_for_vm_state "$vm_id" "running" "$START_TIMEOUT_SECONDS"; then
                                log "VM $vm_id reached running state after start command failure."
                                return 0
                        fi
                fi

                ((attempt += 1))
                sleep "$RETRY_DELAY_SECONDS"
        done

        log "VM $vm_id failed to restart after $RESTART_RETRIES attempts."
        return 1
}

# Examine one monitored VM and restart it if it is in a bad run state or its CPU
# history looks stalled. The caller has already confirmed the VM still carries
# the watchdog tag. Mirrors queue_restart's tag-ownership contract:
#   2 - a background restart was launched and owns the active tag (caller must
#       leave it in place).
#   0 - examined with no outstanding async work for this VM (caller may drop a
#       check-phase tag it added).
evaluate_vm() {
        local vm_id="$1"
        local vm_status=""
        local cpu_values=()
        local sample_count=0
        local latest_cpu=""
        local vm_uptime_seconds=0

        vm_status=$(get_vm_status "$vm_id")
        if [[ -z "$vm_status" ]]; then
                log "Unable to read status for VM $vm_id. Skipping this cycle."
                return 0
        fi

        if [[ "$vm_status" != "running" ]]; then
                if [[ "$vm_status" == "stopped" ]] && is_vm_lock_held "$vm_id"; then
                        log "VM $vm_id is stopped but has active qemu lock holder: $(get_vm_lock_holders "$vm_id"). Attempting unlock."
                        if ! clear_vm_lock_if_possible "$vm_id"; then
                                return 0
                        fi
                fi

                log "VM $vm_id is '$vm_status'. Attempting recovery restart."
                queue_restart "$vm_id" "status_$vm_status"
                return $?
        fi

        readarray -t cpu_values < <(
                run_with_timeout "$PVESH_CMD_TIMEOUT_SECONDS" /usr/bin/pvesh get "/nodes/${VM_NODE[$vm_id]:-$LOCAL_NODE}/qemu/$vm_id/rrddata" -timeframe hour --output-format json 2>/dev/null |
                        /usr/bin/jq -r \
                                --argjson now "$(date +%s)" \
                                --argjson window "$SAMPLE_WINDOW_SECONDS" \
                                --argjson max_points "$MAX_CONSECUTIVE_POINTS" \
                                'map(select(.time > ($now - $window) and .cpu != null)) | sort_by(.time) | .[-$max_points:] | .[].cpu * 100 | floor' 2>/dev/null
        )

        sample_count="${#cpu_values[@]}"
        if (( sample_count == 0 )); then
                log "No recent CPU samples for VM $vm_id. Skipping."
                return 0
        fi

        latest_cpu="${cpu_values[$((sample_count - 1))]}"

        if all_last_n_ge "$HIGH_CPU_THRESHOLD" "$HIGH_CONSECUTIVE_POINTS" "${cpu_values[@]}"; then
                log "VM $vm_id high-CPU lock detected (${HIGH_CONSECUTIVE_POINTS} consecutive samples >= ${HIGH_CPU_THRESHOLD}%, latest=${latest_cpu}%)."
                queue_restart "$vm_id" "high_cpu_stall"
                return $?
        fi

        if all_last_n_lt "$LOW_CPU_THRESHOLD" "$LOW_CONSECUTIVE_POINTS" "${cpu_values[@]}"; then
                vm_uptime_seconds=$(get_vm_uptime_seconds "$vm_id")
                if (( vm_uptime_seconds < LOW_CPU_BOOT_GRACE_SECONDS )); then
                        log "VM $vm_id uptime ${vm_uptime_seconds}s < ${LOW_CPU_BOOT_GRACE_SECONDS}s boot grace. Skipping low-CPU check."
                        return 0
                fi

                if (( ENABLE_LOW_CPU_RESTART != 1 )); then
                        log "VM $vm_id sustained low CPU (${LOW_CONSECUTIVE_POINTS} samples < ${LOW_CPU_THRESHOLD}%, latest=${latest_cpu}%), but low-CPU restart is disabled."
                        return 0
                fi

                log "VM $vm_id low-CPU stall detected (${LOW_CONSECUTIVE_POINTS} consecutive samples < ${LOW_CPU_THRESHOLD}%, latest=${latest_cpu}%)."
                queue_restart "$vm_id" "low_cpu_stall"
                return $?
        fi

        log "VM $vm_id healthy (latest CPU=${latest_cpu}%)."
        return 0
}

acquire_lock "$@"
log "--- Run at $(date) ---"

if [[ -z "$LOCAL_NODE" ]]; then
        LOCAL_NODE="$(detect_local_node)"
fi

if [[ -z "$LOCAL_NODE" ]]; then
        log "Could not auto-detect this node's name. Set LOCAL_NODE near the top of the script. Skipping this cycle."
        log "Check complete"
        exit 0
fi

if [[ "$CLUSTER_WIDE" == "1" ]]; then
        log "Running on node '$LOCAL_NODE' (cluster-wide mode)."
        load_node_ips
        if (( ${#NODE_IP[@]} > 0 )); then
                log "Resolved node IPs for SSH: $(format_node_ips)"
        else
                log "No node IPs found in /etc/pve/.members; SSH will use bare node names (may fail if they don't resolve)."
        fi
else
        log "Running on node '$LOCAL_NODE' (node-local mode)."
fi

if ! discover_watchdog_vms; then
        log "Check complete"
        exit 0
fi

if (( ${#WATCHDOG_VMS[@]} == 0 )); then
        if [[ "$CLUSTER_WIDE" == "1" ]]; then
                log "No VMs tagged '$WATCHDOG_TAG' found in the cluster. Nothing to monitor."
        else
                log "No VMs tagged '$WATCHDOG_TAG' on node '$LOCAL_NODE'. Nothing to monitor."
        fi
        log "Check complete"
        exit 0
fi

if [[ "$CLUSTER_WIDE" == "1" ]]; then
        log "Monitoring ${#WATCHDOG_VMS[@]} VM(s) tagged '$WATCHDOG_TAG' cluster-wide: $(format_watchdog_vms)"
else
        log "Monitoring ${#WATCHDOG_VMS[@]} VM(s) tagged '$WATCHDOG_TAG' on node '$LOCAL_NODE': ${WATCHDOG_VMS[*]}"
fi
cleanup_stale_qm_processes
clear_stale_active_tags

for VM_ID in "${WATCHDOG_VMS[@]}"; do
        reap_finished_restarts
        log "Checking VM: $VM_ID"

        vm_has_watchdog_tag "$VM_ID"
        TAG_RECHECK_RC=$?
        if (( TAG_RECHECK_RC == 1 )); then
                log "VM $VM_ID no longer carries the '$WATCHDOG_TAG' tag (removed since this run began). Skipping."
                continue
        elif (( TAG_RECHECK_RC == 2 )); then
                log "VM $VM_ID tag re-check inconclusive (pvesh read failed); proceeding based on discovery."
        fi

        # Optionally mark this VM as the one under examination so the run's
        # progress is visible in the Proxmox UI. The tag is dropped again below
        # once the VM has been evaluated -- unless that evaluation launched a
        # background restart, which then owns the tag until it finishes.
        CHECK_TAG_ADDED=0
        if [[ "$TAG_DURING_CHECK" == "1" ]]; then
                add_active_tag "$VM_ID" "examining"
                CHECK_TAG_ADDED=1
        fi

        evaluate_vm "$VM_ID"
        EVAL_RC=$?

        if (( CHECK_TAG_ADDED == 1 )) && (( EVAL_RC != 2 )); then
                remove_active_tag "$VM_ID" "check complete"
        fi
done

wait_for_all_restarts

log "Check complete"
