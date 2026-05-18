#!/bin/bash

# NOTE: We intentionally do NOT use 'set -e' because this script uses
# background jobs for parallel SSH, and set -e behaves unpredictably
# with subshells/background processes. Errors are handled explicitly.

# ============================================================================
# create-users.sh — Create one or more users across all nodes in a SageMaker
# HyperPod Slurm cluster (controller, login nodes, and compute nodes).
#
# This script can be run from ANY node (controller, login, or compute).
# It auto-detects the current node and SSHes to all other nodes.
# Compute nodes are configured in parallel for large clusters (500+ nodes).
#
# Modes:
#   File mode:        If "shared_users.txt" exists, reads users from it,
#                     validates, and creates only new users on all nodes.
#   Interactive mode:  If no file found, prompts for usernames/UIDs interactively.
#
# After creating users, appends to "shared_users.txt" and optionally
# uploads to the lifecycle S3 bucket.
#
# Usage: sudo ./create-users.sh
#
# Prerequisites:
#   - jq installed on the current node
#   - SSH access from current node to all other nodes
#   - /opt/ml/config/resource_config.json present
#   - /opt/ml/config/provisioning_parameters.json present
# ============================================================================

RESOURCE_CONFIG="/opt/ml/config/resource_config.json"
PROVISIONING_PARAMS="/opt/ml/config/provisioning_parameters.json"
SHARED_USERS_FILE="shared_users.txt"
MAX_PARALLEL=64

# --- Validate prerequisites ---
for config_file in "$RESOURCE_CONFIG" "$PROVISIONING_PARAMS"; do
    if [[ ! -f "$config_file" ]]; then
        echo "[ERROR] $config_file not found. Are you running this on a HyperPod node?"
        exit 1
    fi
done

if ! command -v jq &>/dev/null; then
    echo "[ERROR] jq is required but not installed."
    exit 1
fi

# --- Detect SSH user ---
if [[ -n "$SUDO_USER" ]]; then
    SSH_USER="$SUDO_USER"
elif [[ "$(id -u)" -ne 0 ]]; then
    SSH_USER="$(whoami)"
else
    SSH_USER="ubuntu"
    echo "[WARN] Could not detect original user, defaulting to '$SSH_USER' for SSH"
fi

# --- Helpers ---

ip_to_hostname() { echo "ip-${1//./-}"; }

get_group_hostnames() {
    local ips
    ips=$(jq -r --arg name "$1" \
        '.InstanceGroups[] | select(.Name == $name) | .Instances // [] | .[].CustomerIpAddress' \
        "$RESOURCE_CONFIG" 2>/dev/null)
    while IFS= read -r ip; do
        [[ -n "$ip" ]] && ip_to_hostname "$ip"
    done <<< "$ips"
}

create_users_on_remote() {
    local node="$1" node_type="$2" make_sudoer="$3"
    shift 3
    local users_data=("$@") remote_cmd=""

    for entry in "${users_data[@]}"; do
        IFS=',' read -r user uid home <<< "$entry"
        local cmd="(id $user &>/dev/null && echo '${user}:EXISTS'"
        cmd+=" || (sudo useradd -M -u $uid $user -d $home --shell /bin/bash"
        cmd+=" && (getent group docker &>/dev/null && sudo usermod -aG docker $user && echo '${user}:DOCKER' || true)"
        [[ "$make_sudoer" == "y" ]] && cmd+=" && (sudo usermod -aG sudo $user 2>/dev/null || sudo usermod -aG wheel $user 2>/dev/null || true) && echo '${user}:SUDOER'"
        cmd+=" && echo '${user}:CREATED' || echo '${user}:FAILED'))"
        [[ -n "$remote_cmd" ]] && remote_cmd+=" ; "
        remote_cmd+="$cmd"
    done

    local output
    output=$(sudo -u "$SSH_USER" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$node" "$remote_cmd" 2>&1) || true

    echo "  [$node_type] $node:"
    for entry in "${users_data[@]}"; do
        IFS=',' read -r user uid home <<< "$entry"
        if [[ "$output" == *"${user}:EXISTS"* ]]; then
            echo "    ⚠ '$user' already exists (skipped)"
        elif [[ "$output" == *"${user}:CREATED"* ]]; then
            echo "    ✓ '$user' created (UID: $uid)"
            [[ "$output" == *"${user}:DOCKER"* ]] && echo "      Added to docker group"
            [[ "$output" == *"${user}:SUDOER"* ]] && echo "      Added to sudoer group"
        elif [[ "$output" == *"${user}:FAILED"* ]]; then
            echo "    ✗ '$user' failed"
        else
            echo "    ✗ '$user' — unknown status (SSH may have failed)"
        fi
    done
    return 0
}

# ============================================================================
# CLUSTER CONFIGURATION (auto-detect, no prompts)
# ============================================================================

CONTROLLER_GROUP=$(jq -r '.controller_group // empty' "$PROVISIONING_PARAMS")
LOGIN_GROUP=$(jq -r '.login_group // empty' "$PROVISIONING_PARAMS")
WORKER_GROUPS=$(jq -r '.worker_groups[]?.instance_group_name // empty' "$PROVISIONING_PARAMS")
CURRENT_HOST=$(hostname)

echo "========================================"
echo " Cluster Configuration"
echo "========================================"
echo "  Current node:      $CURRENT_HOST"
echo "  SSH user:          $SSH_USER"
echo "  Controller group:  ${CONTROLLER_GROUP:-not found}"
echo "  Login group:       ${LOGIN_GROUP:-not configured}"
echo "  Worker group(s):   ${WORKER_GROUPS:-not found}"

# Build node lists
CONTROLLER_NODES=()
[[ -n "$CONTROLLER_GROUP" ]] && read -ra CONTROLLER_NODES <<< "$(get_group_hostnames "$CONTROLLER_GROUP" | tr '\n' ' ')"

LOGIN_NODES=()
[[ -n "$LOGIN_GROUP" ]] && read -ra LOGIN_NODES <<< "$(get_group_hostnames "$LOGIN_GROUP" | tr '\n' ' ')"

COMPUTE_NODES=()
if [[ -n "$WORKER_GROUPS" ]]; then
    while IFS= read -r wg; do
        [[ -z "$wg" ]] && continue
        read -ra wg_hosts <<< "$(get_group_hostnames "$wg" | tr '\n' ' ')"
        COMPUTE_NODES+=("${wg_hosts[@]}")
    done <<< "$WORKER_GROUPS"
fi

# Detect role
CURRENT_ROLE="unknown"
for n in "${CONTROLLER_NODES[@]}"; do [[ "$n" == "$CURRENT_HOST" ]] && CURRENT_ROLE="controller" && break; done
[[ "$CURRENT_ROLE" == "unknown" ]] && for n in "${LOGIN_NODES[@]}"; do [[ "$n" == "$CURRENT_HOST" ]] && CURRENT_ROLE="login" && break; done
[[ "$CURRENT_ROLE" == "unknown" ]] && for n in "${COMPUTE_NODES[@]}"; do [[ "$n" == "$CURRENT_HOST" ]] && CURRENT_ROLE="compute" && break; done

echo "  Current node role: $CURRENT_ROLE"

# Detect OpenZFS
USE_OPENZFS=false
if mountpoint -q /home 2>/dev/null; then
    USE_OPENZFS=true
    echo "  OpenZFS:          detected at /home"
else
    echo "  OpenZFS:          not detected"
fi

echo "  Nodes:            ${#CONTROLLER_NODES[@]} controller, ${#LOGIN_NODES[@]} login, ${#COMPUTE_NODES[@]} compute"
echo ""

# ===================================================================
# Step 1: Determine mode + gather user data
# ===================================================================
echo "========================================"
echo " Step 1: User Configuration"
echo "========================================"

declare -a USERS_DATA=()  # "user,uid,/fsx/user" entries to create
MAKE_SUDOER="n"

if [[ -f "$SHARED_USERS_FILE" && -s "$SHARED_USERS_FILE" ]]; then
    # --- FILE MODE ---
    echo "  Found $SHARED_USERS_FILE — validating entries..."
    echo ""

    new_count=0
    skip_count=0
    while IFS="," read -r username uid_str home; do
        [[ -z "$username" || "$username" == \#* ]] && continue
        username=$(echo "$username" | tr -d ' ')
        uid_str=$(echo "$uid_str" | tr -d ' ')
        home=$(echo "$home" | tr -d ' ')

        if id "$username" &>/dev/null; then
            echo "    ⚠ $username (UID: $uid_str) — already exists, will skip"
            ((skip_count++))
        elif getent passwd "$uid_str" &>/dev/null; then
            existing=$(getent passwd "$uid_str" | cut -d: -f1)
            echo "    ✗ $username (UID: $uid_str) — UID conflict with '$existing', will skip"
            ((skip_count++))
        else
            echo "    ✓ $username (UID: $uid_str) — new, will be created"
            USERS_DATA+=("${username},${uid_str},${home}")
            ((new_count++))
        fi
    done < "$SHARED_USERS_FILE"

    echo ""
    echo "  New: $new_count | Skipped: $skip_count"

    if [[ $new_count -eq 0 ]]; then
        echo "  No new users to create. Exiting."
        exit 0
    fi

    read -p "  Create $new_count new user(s) on all nodes? [Y/n]: " confirm
    confirm=${confirm:-Y}
    [[ ! "$confirm" =~ ^[Yy] ]] && echo "  Aborted." && exit 0

    read -p "  Make these user(s) sudoer(s)? (y/N): " MAKE_SUDOER
    MAKE_SUDOER=${MAKE_SUDOER:-n}
    MAKE_SUDOER=$(echo "$MAKE_SUDOER" | tr '[:upper:]' '[:lower:]')

else
    # --- INTERACTIVE MODE ---
    if [[ -f "$SHARED_USERS_FILE" ]]; then
        echo "  $SHARED_USERS_FILE is empty."
    else
        echo "  No $SHARED_USERS_FILE found."
    fi
    echo "  Entering interactive mode..."
    echo ""

    read -p "  Enter username(s), comma-separated (e.g. 'sean' or 'sean,alice,bob'): " USER_INPUT
    if [[ -z "$USER_INPUT" ]]; then
        echo "[ERROR] Username(s) cannot be empty."
        exit 1
    fi

    IFS=',' read -ra USERS <<< "$USER_INPUT"
    USERS=("${USERS[@]// /}")

    # Validate usernames
    for user in "${USERS[@]}"; do
        [[ -z "$user" ]] && echo "[ERROR] Empty username detected." && exit 1
        id "$user" &>/dev/null && echo "[ERROR] User '$user' already exists." && exit 1
    done

    # Optional UIDs
    echo ""
    read -p "  Specify UIDs? (Enter for auto-assign, or comma-separated UIDs): " UID_INPUT
    USER_UIDS=()
    if [[ -n "$UID_INPUT" ]]; then
        IFS=',' read -ra USER_UIDS <<< "$UID_INPUT"
        USER_UIDS=("${USER_UIDS[@]// /}")
        [[ ${#USER_UIDS[@]} -ne ${#USERS[@]} ]] && echo "[ERROR] UID count doesn't match username count." && exit 1
        for i in "${!USER_UIDS[@]}"; do
            uid="${USER_UIDS[$i]}"
            [[ ! "$uid" =~ ^[0-9]+$ ]] && echo "[ERROR] Invalid UID '$uid'." && exit 1
            if getent passwd "$uid" &>/dev/null; then
                existing=$(getent passwd "$uid" | cut -d: -f1)
                echo "[ERROR] UID $uid already in use by '$existing'."
                exit 1
            fi
        done
    fi

    read -p "  Make these user(s) sudoer(s)? (y/N): " MAKE_SUDOER
    MAKE_SUDOER=${MAKE_SUDOER:-n}
    MAKE_SUDOER=$(echo "$MAKE_SUDOER" | tr '[:upper:]' '[:lower:]')
fi

# ===================================================================
# Step 2: Create users locally on current node
# ===================================================================
echo ""
echo "========================================"
echo " Step 2: Create users on current node"
echo "========================================"

# Track created users for summary
declare -a CREATED_USERS_DATA=()

if [[ ${#USERS_DATA[@]} -gt 0 ]]; then
    # FILE MODE — create from validated USERS_DATA
    for entry in "${USERS_DATA[@]}"; do
        IFS=',' read -r user uid_str fsx_dir <<< "$entry"
        uid_flag="--uid $uid_str"

        if [[ "$USE_OPENZFS" == true ]]; then
            home_dir="/home/$user"
            useradd "$user" -m -d "$home_dir" $uid_flag --shell /bin/bash 2>/dev/null
        else
            home_dir="$fsx_dir"
            useradd "$user" -m -d "$home_dir" $uid_flag --shell /bin/bash 2>/dev/null
        fi

        # Verify user was actually created before proceeding
        if ! id -u "$user" &>/dev/null; then
            echo "  ✗ Failed to create user '$user' — skipping"
            continue
        fi

        uid=$(id -u "$user")
        [[ "$USE_OPENZFS" == true ]] && { mkdir -p "$fsx_dir"; chown "$user":"$user" "$fsx_dir"; }
        CREATED_USERS_DATA+=("${user},${uid},${fsx_dir}")
        echo "  ✓ User '$user' created with UID $uid (home: $home_dir)"

        getent group docker &>/dev/null && usermod -aG docker "$user" && echo "    Added to docker group"
        [[ "$MAKE_SUDOER" == "y" ]] && { usermod -aG sudo "$user" 2>/dev/null || usermod -aG wheel "$user" 2>/dev/null || true; echo "    Added to sudoer group"; }
    done
else
    # INTERACTIVE MODE — create from USERS array
    for i in "${!USERS[@]}"; do
        user="${USERS[$i]}"
        fsx_dir="/fsx/$user"
        uid_flag=""
        [[ ${#USER_UIDS[@]} -gt 0 ]] && uid_flag="--uid ${USER_UIDS[$i]}"

        if [[ "$USE_OPENZFS" == true ]]; then
            home_dir="/home/$user"
            useradd "$user" -m -d "$home_dir" $uid_flag --shell /bin/bash 2>/dev/null
        else
            home_dir="$fsx_dir"
            useradd "$user" -m -d "$home_dir" $uid_flag --shell /bin/bash 2>/dev/null
        fi

        # Verify user was actually created before proceeding
        if ! id -u "$user" &>/dev/null; then
            echo "  ✗ Failed to create user '$user' — skipping"
            continue
        fi

        uid=$(id -u "$user")
        [[ "$USE_OPENZFS" == true ]] && { mkdir -p "$fsx_dir"; chown "$user":"$user" "$fsx_dir"; }
        CREATED_USERS_DATA+=("${user},${uid},${fsx_dir}")
        echo "  ✓ User '$user' created with UID $uid (home: $home_dir)"

        getent group docker &>/dev/null && usermod -aG docker "$user" && echo "    Added to docker group"
        [[ "$MAKE_SUDOER" == "y" ]] && { usermod -aG sudo "$user" 2>/dev/null || usermod -aG wheel "$user" 2>/dev/null || true; echo "    Added to sudoer group"; }
    done
fi

if [[ ${#CREATED_USERS_DATA[@]} -eq 0 ]]; then
    echo "  No users were created. Exiting."
    exit 0
fi

# ===================================================================
# Step 3: Setup SSH keypairs
# ===================================================================
echo ""
echo "========================================"
echo " Step 3: Setup SSH keypairs"
echo "========================================"
for entry in "${CREATED_USERS_DATA[@]}"; do
    IFS=',' read -r user uid fsx_dir <<< "$entry"
    ssh_dir="/fsx/$user/.ssh"

    # Ensure .ssh directory exists
    mkdir -p "$ssh_dir" 2>/dev/null || true
    chown "$user":"$user" "$ssh_dir" 2>/dev/null || true
    chmod 700 "$ssh_dir" 2>/dev/null || true

    # Generate keypair
    sudo -u "$user" ssh-keygen -t rsa -q -f "$ssh_dir/id_rsa" -N "" 2>/dev/null || true

    if [[ -f "$ssh_dir/id_rsa.pub" ]]; then
        sudo -u "$user" cp "$ssh_dir/id_rsa.pub" "$ssh_dir/authorized_keys" 2>/dev/null || true
        chmod 600 "$ssh_dir/authorized_keys" 2>/dev/null || true
        chown "$user":"$user" "$ssh_dir/authorized_keys" 2>/dev/null || true
        echo "  ✓ SSH keypair created for $user"
    else
        echo "  ⚠ SSH keypair generation failed for $user (home dir may not exist on shared storage)"
    fi
done

# ===================================================================
# Step 4: Create users on remote nodes
# ===================================================================

# Build remote node lists (exclude current node)
REMOTE_CONTROLLER=(); for n in "${CONTROLLER_NODES[@]}"; do [[ "$n" != "$CURRENT_HOST" ]] && REMOTE_CONTROLLER+=("$n"); done
REMOTE_LOGIN=();      for n in "${LOGIN_NODES[@]}";      do [[ "$n" != "$CURRENT_HOST" ]] && REMOTE_LOGIN+=("$n");      done
REMOTE_COMPUTE=();    for n in "${COMPUTE_NODES[@]}";    do [[ "$n" != "$CURRENT_HOST" ]] && REMOTE_COMPUTE+=("$n");    done

echo ""
echo "========================================"
echo " Step 4: Create users on remote nodes"
echo "========================================"

# Controller (sequential)
if [[ ${#REMOTE_CONTROLLER[@]} -gt 0 ]]; then
    for node in "${REMOTE_CONTROLLER[@]}"; do
        create_users_on_remote "$node" "controller" "$MAKE_SUDOER" "${CREATED_USERS_DATA[@]}"
    done
fi

# Login (sequential)
if [[ ${#REMOTE_LOGIN[@]} -gt 0 ]]; then
    for node in "${REMOTE_LOGIN[@]}"; do
        create_users_on_remote "$node" "login" "$MAKE_SUDOER" "${CREATED_USERS_DATA[@]}"
    done
fi

# Compute (parallel)
if [[ ${#REMOTE_COMPUTE[@]} -gt 0 ]]; then
    echo "  Compute nodes (${#REMOTE_COMPUTE[@]}, parallel max=$MAX_PARALLEL):"
    running=0
    for node in "${REMOTE_COMPUTE[@]}"; do
        create_users_on_remote "$node" "compute" "$MAKE_SUDOER" "${CREATED_USERS_DATA[@]}" &
        ((running++)) || true
        if ((running >= MAX_PARALLEL)); then
            wait -n 2>/dev/null || true
            ((running--)) || true
        fi
    done
    wait || true
fi

TOTAL_REMOTE=$(( ${#REMOTE_CONTROLLER[@]} + ${#REMOTE_LOGIN[@]} + ${#REMOTE_COMPUTE[@]} ))
[[ $TOTAL_REMOTE -eq 0 ]] && echo "  No remote nodes to configure."

# ===================================================================
# Step 5: Slurm accounting (add users to Slurm on controller)
# ===================================================================
echo ""
echo "========================================"
echo " Step 5: Slurm accounting"
echo "========================================"

CONTROLLER_HOST="${CONTROLLER_NODES[0]:-}"
SLURM_ACCT_SUCCESS=false

if [[ -n "$CONTROLLER_HOST" ]]; then
    # Build sacctmgr commands for all new users
    slurm_cmd="sacctmgr -i add account root Description='Root Account' 2>/dev/null || true"
    for entry in "${CREATED_USERS_DATA[@]}"; do
        IFS=',' read -r user uid home <<< "$entry"
        slurm_cmd+="; sacctmgr -i add user $user account=root 2>/dev/null || true"
    done

    if [[ "$CURRENT_HOST" == "$CONTROLLER_HOST" ]]; then
        echo "  Running sacctmgr locally (this is the controller)..."
        eval "$slurm_cmd" && SLURM_ACCT_SUCCESS=true
    else
        echo "  Running sacctmgr on controller ($CONTROLLER_HOST) via SSH..."
        sudo -u "$SSH_USER" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$CONTROLLER_HOST" "$slurm_cmd" 2>&1 && SLURM_ACCT_SUCCESS=true
    fi

    if [[ "$SLURM_ACCT_SUCCESS" == true ]]; then
        echo "  ✓ Added ${#CREATED_USERS_DATA[@]} user(s) to Slurm accounting (account: root)"
    else
        echo "  ✗ Slurm accounting failed — users may need to be added manually:"
        echo "    sacctmgr -i add user <username> account=root"
    fi
else
    echo "  ⚠ No controller node found — skipping Slurm accounting"
fi

# ===================================================================
# Step 6: Update shared_users.txt + optional S3 upload
# ===================================================================
echo ""
echo "========================================"
echo " Step 6: Update shared_users.txt"
echo "========================================"

for entry in "${CREATED_USERS_DATA[@]}"; do
    echo "$entry" >> "$SHARED_USERS_FILE"
    echo "  + $entry"
done
echo "  ✓ Appended ${#CREATED_USERS_DATA[@]} user(s) to $SHARED_USERS_FILE"
echo ""
read -p "  Upload shared_users.txt to S3? Enter bucket URI (or Enter to skip): " S3_BUCKET_URI
S3_BUCKET_URI="${S3_BUCKET_URI%/}"
S3_UPLOAD_SUCCESS=false

if [[ -n "$S3_BUCKET_URI" ]]; then
    echo "  Uploading..."
    if sudo -u "$SSH_USER" aws s3 cp "$SHARED_USERS_FILE" "${S3_BUCKET_URI}/shared_users.txt" 2>&1; then
        echo "  ✓ Uploaded to ${S3_BUCKET_URI}/shared_users.txt"
        S3_UPLOAD_SUCCESS=true
    else
        echo "  ✗ Upload failed. Manual command:"
        echo "    aws s3 cp $SHARED_USERS_FILE ${S3_BUCKET_URI}/shared_users.txt"
    fi
fi

# ===================================================================
# Step 7: Summary
# ===================================================================
echo ""
echo "========================================"
echo " ✓ ${#CREATED_USERS_DATA[@]} user(s) created!"
echo "========================================"
echo ""
echo "  Users created:"
for entry in "${CREATED_USERS_DATA[@]}"; do
    IFS=',' read -r user uid home <<< "$entry"
    echo "    $user (UID: $uid, Home: $home)"
done
echo ""
echo "  Sudoer: $([[ "$MAKE_SUDOER" == "y" ]] && echo "Yes" || echo "No")"
echo ""
echo "  Nodes configured:"
echo "    Current:    $CURRENT_HOST ($CURRENT_ROLE) ✓"
[[ ${#REMOTE_CONTROLLER[@]} -gt 0 ]] && echo "    Controller: ${REMOTE_CONTROLLER[*]}"
[[ ${#REMOTE_LOGIN[@]} -gt 0 ]]      && echo "    Login:      ${REMOTE_LOGIN[*]}"
[[ ${#REMOTE_COMPUTE[@]} -gt 0 ]]    && echo "    Compute:    ${#REMOTE_COMPUTE[@]} node(s)"
echo ""
echo "  Slurm acct:   $([[ "$SLURM_ACCT_SUCCESS" == true ]] && echo "✓" || echo "⚠ manual setup needed")"
echo "  Shared users: $SHARED_USERS_FILE ✓"
[[ "$S3_UPLOAD_SUCCESS" == true ]] && echo "  S3 upload:    ${S3_BUCKET_URI}/shared_users.txt ✓"
[[ "$S3_UPLOAD_SUCCESS" != true && -z "$S3_BUCKET_URI" ]] && echo "  S3 upload:    skipped — run: aws s3 cp $SHARED_USERS_FILE s3://<bucket>/shared_users.txt"

if [[ "$MAKE_SUDOER" == "y" ]]; then
    echo ""
    echo "  NOTE: For passwordless sudo, run on each node:"
    echo "    sudo visudo → change %sudo ALL=(ALL:ALL) ALL to %sudo ALL=(ALL:ALL) NOPASSWD: ALL"
fi
echo ""
echo "========================================"
