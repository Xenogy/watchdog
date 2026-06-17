#!/bin/bash
set -o nounset
set -o pipefail

LOCK_FILE="/var/lock/vm_monitor.lock"
CRON_LOG_FILE="/var/log/vm-monitor-ex-cron.log"
if [[ "${VM_MONITOR_SKIP_REDIRECT:-0}" != "1" ]]; then
        exec > >(tee -a "$CRON_LOG_FILE") 2>&1
fi

# REQUIRED: Enter the Proxmox host node name (find it with `hostname`).
HOST_NODE="pve"

# VMs to monitor are selected dynamically by tag: every VM carrying this tag is
# watched. Add or remove the tag in the Proxmox UI (or with
# `qm set <vmid> --tags <tag>`) to enable/disable monitoring for a VM without
# editing this script. Matching is case-insensitive.
WATCHDOG_TAG="watchdog"

LOG_FILE="/var/log/vm_monitor.log"

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

MAX_CONSECUTIVE_POINTS=$HIGH_CONSECUTIVE_POINTS
if (( LOW_CONSECUTIVE_POINTS > MAX_CONSECUTIVE_POINTS )); then
        MAX_CONSECUTIVE_POINTS=$LOW_CONSECUTIVE_POINTS
fi

RESTART_PIDS=()
declare -A RESTART_META=()

# Populated fresh on every run by discover_watchdog_vms.
WATCHDOG_VMS=()

log() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
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

        /usr/bin/setsid "$@" &
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

                sleep 1
        done

        wait "$child_pid"
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
get_vm_tags() {
        local vm_id="$1"
        local raw=""
        local rc=0

        raw=$(run_with_timeout "$PVESH_CMD_TIMEOUT_SECONDS" /usr/bin/pvesh get "/nodes/$HOST_NODE/qemu/$vm_id/config" --output-format json 2>/dev/null)
        rc=$?
        if (( rc != 0 )) || [[ -z "$raw" ]]; then
                return 1
        fi

        printf '%s' "$raw" | /usr/bin/jq -r '.tags // ""' 2>/dev/null
        return 0
}

# Return 0 if the given tag string contains the watchdog tag. Proxmox stores
# tags separated by ';'; we also tolerate ',' and whitespace, and match
# case-insensitively so "watchdog", "Watchdog", etc. all count. Splitting with
# `read -ra` (rather than an unquoted `for`) keeps tags that contain glob
# characters from being expanded against the filesystem.
tags_contain_watchdog() {
        local tags="$1"
        local want="${WATCHDOG_TAG,,}"
        local parts=()
        local tag=""
        local IFS=$'; \t,'

        read -ra parts <<< "$tags"
        for tag in "${parts[@]}"; do
                if [[ "${tag,,}" == "$want" ]]; then
                        return 0
                fi
        done

        return 1
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

# Enumerate every VM on the node carrying the watchdog tag and populate the
# WATCHDOG_VMS array. Returns non-zero only when the VM list cannot be read at
# all, so the caller can skip the cycle instead of mistaking a failed lookup
# for "nothing is tagged". A per-VM tag read that fails is logged and that VM is
# left out for this cycle (reconsidered next run) rather than being silently
# dropped or restarted while its tag state is unknown.
discover_watchdog_vms() {
        local index_json=""
        local vm_ids=()
        local vm_id=""
        local tags=""
        local rc=0

        index_json=$(run_with_timeout "$PVESH_CMD_TIMEOUT_SECONDS" /usr/bin/pvesh get "/nodes/$HOST_NODE/qemu" --output-format json 2>/dev/null)

        if [[ -z "$index_json" ]] || ! echo "$index_json" | /usr/bin/jq -e 'type == "array"' >/dev/null 2>&1; then
                log "Unable to enumerate VMs on node '$HOST_NODE' (pvesh failed or returned no data). Skipping this cycle."
                return 1
        fi

        # Skip templates: they never run and must never be "restarted". The flag
        # may render as a number, string or boolean across PVE versions, so the
        # match is type-agnostic.
        readarray -t vm_ids < <(echo "$index_json" | /usr/bin/jq -r '.[] | select((.template // false) | tostring | (. == "1" or . == "true") | not) | .vmid' 2>/dev/null | sort -n)

        WATCHDOG_VMS=()
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
                fi
        done

        return 0
}

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
        local lock_file="/var/lock/qemu-server/lock-${vm_id}.conf"
        local holder_count=0

        holder_count=$(run_with_timeout "$VM_LOCK_CHECK_TIMEOUT_SECONDS" /usr/bin/lsof "$lock_file" 2>/dev/null | awk 'NR>1 {count+=1} END {print count+0}')
        if [[ ! "$holder_count" =~ ^[0-9]+$ ]]; then
                return 1
        fi

        (( holder_count > 0 ))
}

get_vm_lock_holders() {
        local vm_id="$1"
        local lock_file="/var/lock/qemu-server/lock-${vm_id}.conf"

        run_with_timeout "$VM_LOCK_CHECK_TIMEOUT_SECONDS" /usr/bin/lsof "$lock_file" 2>/dev/null | awk 'NR>1 {printf "%s(pid=%s) ", $1, $2}'
}

get_vm_lock_holder_pids() {
        local vm_id="$1"
        local lock_file="/var/lock/qemu-server/lock-${vm_id}.conf"

        run_with_timeout "$VM_LOCK_CHECK_TIMEOUT_SECONDS" /usr/bin/lsof "$lock_file" 2>/dev/null | awk 'NR>1 {print $2}' | sort -u
}

get_process_state() {
        local pid="$1"

        run_with_timeout "$VM_LOCK_CHECK_TIMEOUT_SECONDS" ps -o state= -p "$pid" 2>/dev/null | awk 'NR==1 {print $1}'
}

is_vm_lock_stuck_in_d_state() {
        local vm_id="$1"
        local pid=""
        local state=""

        while IFS= read -r pid; do
                if [[ -z "$pid" ]]; then
                        continue
                fi

                state=$(get_process_state "$pid")
                if [[ "$state" == "D" ]]; then
                        return 0
                fi
        done < <(get_vm_lock_holder_pids "$vm_id")

        return 1
}

clear_vm_lock_if_possible() {
        local vm_id="$1"
        local deadline=0

        if ! is_vm_lock_held "$vm_id"; then
                return 0
        fi

        log "VM $vm_id lock holder(s): $(get_vm_lock_holders "$vm_id")"
        run_with_timeout "$QM_ACTION_TIMEOUT_SECONDS" /usr/sbin/qm unlock "$vm_id" >/dev/null 2>&1 || true

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

queue_restart() {
        local vm_id="$1"
        local reason="$2"
        local pid=""

        if (( BLOCK_RESTARTS_WHEN_STUCK_TASKS == 1 )) && is_vm_lock_held "$vm_id" && is_vm_lock_stuck_in_d_state "$vm_id"; then
                log "Skipping restart for VM $vm_id (reason: $reason) because its qemu lock holder is stuck in D state."
                return
        fi

        if is_restart_in_cooldown "$vm_id" "$reason"; then
                return
        fi

        if (( MAX_PARALLEL_RESTARTS <= 1 )); then
                log "Executing restart for VM $vm_id (reason: $reason)"
                if restart_vm "$vm_id" "$reason"; then
                        record_restart_attempt "$vm_id" "$reason"
                fi
                return
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
        run_with_timeout "$QM_STATUS_TIMEOUT_SECONDS" /usr/sbin/qm status "$vm_id" 2>/dev/null | awk '{print $2}'
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
        local uptime

        uptime=$(run_with_timeout "$PVESH_CMD_TIMEOUT_SECONDS" /usr/bin/pvesh get "/nodes/$HOST_NODE/qemu/$vm_id/status/current" --output-format json 2>/dev/null | /usr/bin/jq -r '.uptime // 0' 2>/dev/null)

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

restart_vm() {
        local vm_id="$1"
        local reason="$2"
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
                                run_with_timeout "$QM_ACTION_TIMEOUT_SECONDS" /usr/sbin/qm stop "$vm_id" --skiplock 1 >/dev/null 2>&1 || run_with_timeout "$QM_ACTION_TIMEOUT_SECONDS" /usr/sbin/qm stop "$vm_id" >/dev/null 2>&1 || true
                                if ! wait_for_vm_state "$vm_id" "stopped" "$FORCE_STOP_TIMEOUT_SECONDS"; then
                                        log "VM $vm_id did not stop after direct force-stop."
                                        run_with_timeout "$QM_ACTION_TIMEOUT_SECONDS" /usr/sbin/qm unlock "$vm_id" >/dev/null 2>&1 || true
                                        ((attempt += 1))
                                        sleep "$RETRY_DELAY_SECONDS"
                                        continue
                                fi
                        else
                                run_with_timeout "$QM_ACTION_TIMEOUT_SECONDS" /usr/sbin/qm shutdown "$vm_id" --timeout "$SHUTDOWN_TIMEOUT_SECONDS" >/dev/null 2>&1 || true

                                if ! wait_for_vm_state "$vm_id" "stopped" "$SHUTDOWN_TIMEOUT_SECONDS"; then
                                        log "VM $vm_id graceful shutdown timed out. Forcing stop."
                                        run_with_timeout "$QM_ACTION_TIMEOUT_SECONDS" /usr/sbin/qm stop "$vm_id" --skiplock 1 >/dev/null 2>&1 || run_with_timeout "$QM_ACTION_TIMEOUT_SECONDS" /usr/sbin/qm stop "$vm_id" >/dev/null 2>&1 || true
                                        if ! wait_for_vm_state "$vm_id" "stopped" "$FORCE_STOP_TIMEOUT_SECONDS"; then
                                                log "VM $vm_id did not stop after force-stop."
                                                run_with_timeout "$QM_ACTION_TIMEOUT_SECONDS" /usr/sbin/qm unlock "$vm_id" >/dev/null 2>&1 || true
                                                ((attempt += 1))
                                                sleep "$RETRY_DELAY_SECONDS"
                                                continue
                                        fi
                                fi
                        fi
                elif [[ "$status" != "stopped" ]]; then
                        log "VM $vm_id reported state '$status'. Attempting stop and recovery."
                        run_with_timeout "$QM_ACTION_TIMEOUT_SECONDS" /usr/sbin/qm unlock "$vm_id" >/dev/null 2>&1 || true
                        run_with_timeout "$QM_ACTION_TIMEOUT_SECONDS" /usr/sbin/qm stop "$vm_id" --skiplock 1 >/dev/null 2>&1 || true
                        wait_for_vm_state "$vm_id" "stopped" "$FORCE_STOP_TIMEOUT_SECONDS" || true
                fi

                run_with_timeout "$QM_ACTION_TIMEOUT_SECONDS" /usr/sbin/qm unlock "$vm_id" >/dev/null 2>&1 || true
                start_attempted=1

                if run_with_timeout "$QM_ACTION_TIMEOUT_SECONDS" /usr/sbin/qm start "$vm_id" >/dev/null 2>&1; then
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

acquire_lock "$@"
log "--- Run at $(date) ---"

if ! discover_watchdog_vms; then
        log "Check complete"
        exit 0
fi

if (( ${#WATCHDOG_VMS[@]} == 0 )); then
        log "No VMs tagged '$WATCHDOG_TAG' on node '$HOST_NODE'. Nothing to monitor."
        log "Check complete"
        exit 0
fi

log "Monitoring ${#WATCHDOG_VMS[@]} VM(s) tagged '$WATCHDOG_TAG': ${WATCHDOG_VMS[*]}"
cleanup_stale_qm_processes

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

        VM_STATUS=$(get_vm_status "$VM_ID")
        if [[ -z "$VM_STATUS" ]]; then
                log "Unable to read status for VM $VM_ID. Skipping this cycle."
                continue
        fi

        if [[ "$VM_STATUS" != "running" ]]; then
                if [[ "$VM_STATUS" == "stopped" ]] && is_vm_lock_held "$VM_ID"; then
                        log "VM $VM_ID is stopped but has active qemu lock holder: $(get_vm_lock_holders "$VM_ID"). Attempting unlock."
                        if ! clear_vm_lock_if_possible "$VM_ID"; then
                                continue
                        fi
                fi

                log "VM $VM_ID is '$VM_STATUS'. Attempting recovery restart."
                queue_restart "$VM_ID" "status_$VM_STATUS"
                continue
        fi

        readarray -t CPU_VALUES < <(
                run_with_timeout "$PVESH_CMD_TIMEOUT_SECONDS" /usr/bin/pvesh get "/nodes/$HOST_NODE/qemu/$VM_ID/rrddata" -timeframe hour --output-format json 2>/dev/null |
                        /usr/bin/jq -r \
                                --argjson now "$(date +%s)" \
                                --argjson window "$SAMPLE_WINDOW_SECONDS" \
                                --argjson max_points "$MAX_CONSECUTIVE_POINTS" \
                                'map(select(.time > ($now - $window) and .cpu != null)) | sort_by(.time) | .[-$max_points:] | .[].cpu * 100 | floor' 2>/dev/null
        )

        SAMPLE_COUNT="${#CPU_VALUES[@]}"
        if (( SAMPLE_COUNT == 0 )); then
                log "No recent CPU samples for VM $VM_ID. Skipping."
                continue
        fi

        LATEST_CPU="${CPU_VALUES[$((SAMPLE_COUNT - 1))]}"

        if all_last_n_ge "$HIGH_CPU_THRESHOLD" "$HIGH_CONSECUTIVE_POINTS" "${CPU_VALUES[@]}"; then
                log "VM $VM_ID high-CPU lock detected (${HIGH_CONSECUTIVE_POINTS} consecutive samples >= ${HIGH_CPU_THRESHOLD}%, latest=${LATEST_CPU}%)."
                queue_restart "$VM_ID" "high_cpu_stall"
                continue
        fi

        if all_last_n_lt "$LOW_CPU_THRESHOLD" "$LOW_CONSECUTIVE_POINTS" "${CPU_VALUES[@]}"; then
                VM_UPTIME_SECONDS=$(get_vm_uptime_seconds "$VM_ID")
                if (( VM_UPTIME_SECONDS < LOW_CPU_BOOT_GRACE_SECONDS )); then
                        log "VM $VM_ID uptime ${VM_UPTIME_SECONDS}s < ${LOW_CPU_BOOT_GRACE_SECONDS}s boot grace. Skipping low-CPU check."
                        continue
                fi

                if (( ENABLE_LOW_CPU_RESTART != 1 )); then
                        log "VM $VM_ID sustained low CPU (${LOW_CONSECUTIVE_POINTS} samples < ${LOW_CPU_THRESHOLD}%, latest=${LATEST_CPU}%), but low-CPU restart is disabled."
                        continue
                fi

                log "VM $VM_ID low-CPU stall detected (${LOW_CONSECUTIVE_POINTS} consecutive samples < ${LOW_CPU_THRESHOLD}%, latest=${LATEST_CPU}%)."
                queue_restart "$VM_ID" "low_cpu_stall"
        else
                log "VM $VM_ID healthy (latest CPU=${LATEST_CPU}%)."
        fi
done

wait_for_all_restarts

log "Check complete"
