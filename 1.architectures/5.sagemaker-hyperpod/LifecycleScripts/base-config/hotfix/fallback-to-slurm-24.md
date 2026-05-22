# Falling Back from Slurm 25.11 to Slurm 24.11

If your HyperPod cluster was created with Slurm 25.11 and you need to downgrade to Slurm 24.11, there are two ways to do it depending on whether a new AMI is available.

---

## Prerequisite — Back up your data

> ⚠️ **This step is critical regardless of which option you choose.** Both options restart Slurm daemons and may cause in-progress jobs to be lost. Back up your data before proceeding.

SageMaker HyperPod provides a backup script in this repository at [`1.architectures/5.sagemaker-hyperpod/patching-backup.sh`](../../patching-backup.sh). Run the following command on the **head node** to back up your Slurm state, MariaDB accounting database, and any other local data to Amazon S3 or Amazon FSx for Lustre:

```bash
sudo bash patching-backup.sh --create
```

The script will:
1. Check `squeue` for any queued or running jobs — **cancel or drain all jobs before proceeding** if there are any
2. Stop Slurm services
3. Back up MariaDB (Slurm accounting database)
4. Copy local items to your backup destination, including:
   - `/var/spool/slurmd`
   - `/var/spool/slurmctld`
   - `/etc/systemd/system/slurmctld.service`

You can add any additional files or directories to the `LOCAL_ITEMS` list in the script before running it.

To restore your data after the fallback if anything goes wrong:

```bash
sudo bash patching-backup.sh --restore
```

For full details on the backup script, see [Use the backup script provided by SageMaker HyperPod](https://docs.aws.amazon.com/sagemaker/latest/dg/sagemaker-hyperpod-operate-slurm-cli-command.html#sagemaker-hyperpod-operate-slurm-cli-command-update-cluster-software-backup).

---

## Option 1 — Update Cluster Software (recommended)

If a new AMI is available for your cluster, the cleanest approach is to update your lifecycle scripts to pin Slurm to version 24.11, then trigger an **Update Cluster Software** operation via the SageMaker console or API. This re-runs the lifecycle scripts on each node using the new AMI, and the version switch happens automatically before any Slurm services start.

If no new AMI is available, the Update Cluster Software operation will not re-run the lifecycle scripts. In that case, follow Option 2 below.

> **Important:** This change takes effect at Update Cluster Software time only. Changing the lifecycle scripts after the cluster is running has no effect on existing nodes until the next software update.

### Step 1 — Get the lifecycle scripts

Clone or download the HyperPod lifecycle scripts:

```bash
git clone https://github.com/awslabs/awsome-distributed-training.git
cd awsome-distributed-training/1.architectures/5.sagemaker-hyperpod/LifecycleScripts/base-config
```

Or navigate to the directory where you maintain your existing lifecycle scripts.

### Step 2 — Edit `lifecycle_script.py`

Open `lifecycle_script.py` and locate the block that determines the node type (~line 194). It looks like this:

```python
        node_type = SlurmNodeType.COMPUTE_NODE
        if group.get("Name") == params.controller_group:
            node_type = SlurmNodeType.HEAD_NODE
        elif group.get("Name") == params.login_group:
            node_type = SlurmNodeType.LOGIN_NODE

        if node_type == SlurmNodeType.HEAD_NODE:
```

**If your lifecycle scripts already contain lines that switch to Slurm 25.11**, replace them with the following. **If they do not**, add the following two lines between the node type block and the `if node_type == SlurmNodeType.HEAD_NODE:` line:

```python
        # Switch to Slurm 24.11 before any Slurm services start.
        # Copy all configs from the active version's etc/ directory (where
        # ClusterAgent writes slurm.conf, gres.conf, etc.) into the 24.11
        # directory, then switch the symlink.
        subprocess.run(["sudo", "cp", "-rf", "/opt/slurm/etc/.", "/opt/slurm-24.11/etc/"], check=True)
        subprocess.run(["sudo", "ln", "-sfn", "/opt/slurm-24.11", "/opt/slurm"], check=True)
```

The full diff if you are adding these lines for the first time (no existing version switch):

```diff
--- a/lifecycle_script.py
+++ b/lifecycle_script.py
@@ -194,6 +194,12 @@ def main(args):
         node_type = SlurmNodeType.COMPUTE_NODE
         if group.get("Name") == params.controller_group:
             node_type = SlurmNodeType.HEAD_NODE
         elif group.get("Name") == params.login_group:
             node_type = SlurmNodeType.LOGIN_NODE

+        # Switch to Slurm 24.11 before any Slurm services start.
+        # Copy all configs from the active version's etc/ directory (where
+        # ClusterAgent writes slurm.conf, gres.conf, etc.) into the 24.11
+        # directory, then switch the symlink.
+        subprocess.run(["sudo", "cp", "-rf", "/opt/slurm/etc/.", "/opt/slurm-24.11/etc/"], check=True)
+        subprocess.run(["sudo", "ln", "-sfn", "/opt/slurm-24.11", "/opt/slurm"], check=True)
+
         if node_type == SlurmNodeType.HEAD_NODE:
```

### Step 3 — Upload the updated lifecycle scripts to S3

Upload your modified lifecycle scripts to the S3 bucket you use for cluster provisioning:

```bash
aws s3 sync . s3://<your-bucket>/<lcs-foler>/ --exclude ".git/*"
```

Verify the upload:

```bash
aws s3 ls s3://<your-bucket>/<lcs-foler>/lifecycle_script.py
```

### Step 4 — Trigger Update Cluster Software

Trigger an **Update Cluster Software** operation from the SageMaker console or with the AWS CLI. The lifecycle scripts will re-run on each node, copy the configuration files into the Slurm 24.11 directory, and switch the symlink before the Slurm daemons start.

### Step 5 — Verify Slurm 24.11 is active

Once the cluster is up, SSH into the controller node and verify:

```bash
# Confirm the symlink points to 24.11
ls -la /opt/slurm
# Expected: /opt/slurm -> /opt/slurm-24.11

# Confirm the active Slurm version
scontrol --version
# Expected: slurm 24.11.x

# Confirm all nodes are registered and healthy
sinfo
# Expected: all nodes in 'idle' state
```

### Step 6 — Run a validation job

Submit a simple test job to confirm the cluster is functioning:

```bash
srun -N 1 --partition <your-partition> hostname
```

For GPU clusters, verify GPU resources are visible:

```bash
srun -N 1 --partition <your-partition> --gres=gpu:1 nvidia-smi
```

---

## Option 2 — Manual Fallback (no new AMI)

This approach manually switches the active Slurm version by copying the current configuration and redirecting the Slurm symlink to the 24.11 binaries. It requires SSH access to the **head node** and all **worker nodes**.

> **Before you begin:** Make sure Slurm 24.11 binaries are already installed on all nodes at `/opt/slurm-24.11/`. You can verify by running `ls /opt/slurm-*/` on any node — you should see both `/opt/slurm-24.11/` and `/opt/slurm-25.11/`.

### Step 1 — Update the lifecycle scripts in S3

The HostAgent re-runs your lifecycle scripts on every new or replaced node. If your S3 lifecycle scripts still switch to Slurm 25.11, any node that joins after this manual fallback will come up on 25.11 while existing nodes are on 24.11 — a mixed-version cluster that will cause failures.

Before touching the running cluster, update `lifecycle_script.py` in your S3 bucket to switch to 24.11 instead of 25.11. Follow **Option 1, Steps 1–3** to make and upload that change, then continue here.

### Step 2 — Save the worker node list

Before making any changes to the running cluster, capture the list of worker nodes while `sinfo` is still working against the running 25.11 controller. You will use this variable in all subsequent steps.

```bash
NODES=$(sinfo --format="%n" --noheader | tr '\n' ' ')
echo "Worker nodes: $NODES"
```

### Step 3 — Copy the Slurm configuration to the 24.11 directory

On the **head node**, copy the active Slurm configuration files into the 24.11 config directory so the older version picks up the same settings:

```bash
sudo cp -r /opt/slurm/etc/* /opt/slurm-24.11/etc/
```

Then do the same on **every worker node**:

```bash
for node in $NODES; do
    ssh $node "sudo cp -r /opt/slurm/etc/* /opt/slurm-24.11/etc/" &
done
wait
```

### Step 4 — Switch the symlink to Slurm 24.11

The `/opt/slurm` symlink points to the currently active Slurm version. Update it on the **head node** and all **worker nodes**:

```bash
sudo ln -sfn /opt/slurm-24.11 /opt/slurm

for node in $NODES; do
    ssh $node "sudo ln -sfn /opt/slurm-24.11 /opt/slurm" &
done
wait
```

Verify the change on the head node:

```bash
ls -la /opt/slurm
# Should show: /opt/slurm -> /opt/slurm-24.11
```

### Step 5 — Restart slurmdbd (if accounting is enabled)

If the Slurm accounting daemon is running, restart it on the **head node** before restarting `slurmctld`. The daemon links against Slurm libraries from `/opt/slurm/lib/`, so it must be restarted after the symlink switch to pick up the 24.11 libraries.

```bash
sudo systemctl restart slurmdbd
sudo systemctl status slurmdbd
```

If `slurmdbd` is not running on your cluster, skip this step.

### Step 6 — Restart the Slurm controller

On the **head node**, restart `slurmctld` to start running under the 24.11 binaries:

```bash
sudo systemctl restart slurmctld
sudo systemctl status slurmctld
```

Confirm the version:

```bash
/opt/slurm/bin/sinfo --version
# Should show: slurm 24.11.x
```

### Step 7 — Restart the Slurm daemon on all worker nodes

```bash
for node in $NODES; do
    ssh $node "sudo systemctl restart slurmd" &
done
wait
```

### Step 8 — Verify the cluster is healthy

Once all daemons have restarted, check that all nodes are registered and idle:

```bash
sinfo
```

All nodes should appear in `idle` state. If any node shows `down` or `unknown`, check its `slurmd` status:

```bash
ssh <node> "sudo systemctl status slurmd"
```

---

## Notes

- The Slurm state directory (`/var/spool/slurmctld`) is shared between versions — any in-progress jobs will be lost when `slurmctld` restarts. Cancel or drain all jobs before performing this switch if possible.
- The configuration files under `/opt/slurm/etc/` are version-independent (they work with both 24.11 and 25.11), so copying them as-is is safe.
- Do not mix Slurm versions across nodes. All nodes in a cluster must run the same Slurm major version. Mixed-version clusters are not supported and will cause failures.
