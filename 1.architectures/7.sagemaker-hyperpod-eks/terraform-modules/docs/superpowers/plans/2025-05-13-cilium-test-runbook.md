# Cilium CNI Live Cluster Test Runbook

## Overview

Test the three Cilium modes (overlay, chaining, ENI) on real EKS clusters. Each test deploys a fresh cluster, verifies Cilium is healthy, validates pod networking, and confirms HyperPod integration works.

**Order:** Overlay → Chaining → ENI
- Overlay exercises the most new code paths (VPC CNI skipped, VXLAN SG rules, Cilium as sole CNI)
- Chaining validates the VPC CNI co-existence path
- ENI validates native routing + IAM policy attachment

**Time estimate:** ~15 min per apply + ~5 min per destroy = ~60 min total

---

## Prerequisites

- AWS credentials configured with sufficient permissions
- `terraform` >= 1.14.0 installed
- `kubectl` installed
- `helm` installed
- Working directory: `hyperpod-eks-tf/`
- A valid `custom.tfvars` base config (use `terraform.tfvars` as template)

---

## Test 1: Overlay Mode

**What this tests:**
- VPC CNI addon is NOT deployed
- Cilium Helm release deploys successfully with overlay/tunnel values
- VXLAN UDP 8472 security group rules are created
- Pods get cluster-pool IPs (non-VPC-routable)
- CoreDNS comes up after Cilium
- HyperPod helm chart deploys on top of Cilium

### 1.1 Deploy

```bash
terraform apply \
  -var-file="terraform.tfvars" \
  -var="enable_cilium=true" \
  -var='cilium_mode=overlay' \
  -var="create_hyperpod_module=false" \
  -var="create_helm_chart_module=false"
```

Note: We skip HyperPod and its helm chart initially to isolate the EKS + Cilium layer. We'll enable them after confirming Cilium is healthy.

### 1.2 Configure kubectl

```bash
aws eks update-kubeconfig --name sagemaker-hyperpod-eks-cluster --region us-west-2
```

### 1.3 Verify Cilium is running

```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium
kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium-operator
```

**Expected:** All cilium and cilium-operator pods in `Running` state, `READY 1/1`.

### 1.4 Verify VPC CNI is NOT present

```bash
kubectl -n kube-system get daemonset aws-node 2>&1
```

**Expected:** `Error from server (NotFound)` — aws-node DaemonSet should not exist.

```bash
aws eks list-addons --cluster-name sagemaker-hyperpod-eks-cluster --region us-west-2
```

**Expected:** Output should NOT include `vpc-cni`. Should include `kube-proxy`, `eks-pod-identity-agent`, `coredns`.

### 1.5 Verify security group rules

```bash
SG_ID=$(terraform output -raw security_group_id 2>/dev/null || terraform state show 'module.security_group[0].aws_security_group.no_ingress[0]' | grep ' id ' | awk '{print $3}' | tr -d '"')
aws ec2 describe-security-group-rules --filter Name=group-id,Values=$SG_ID --query "SecurityGroupRules[?FromPort==\`8472\`]" --region us-west-2
```

**Expected:** Two rules (ingress + egress) for UDP port 8472 referencing the same security group.

### 1.6 Verify CoreDNS is running

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns
```

**Expected:** CoreDNS pods in `Running` state (may take a few minutes after nodes join).

### 1.7 Verify pod networking (once nodes are available)

```bash
kubectl run test-pod --image=busybox --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/test-pod --timeout=120s
kubectl exec test-pod -- wget -qO- https://kubernetes.default.svc/version --no-check-certificate 2>&1 | head -5
kubectl get pod test-pod -o jsonpath='{.status.podIP}'
```

**Expected:**
- Pod gets an IP from the Cilium cluster-pool range (NOT a VPC subnet IP like 10.192.x.x)
- Pod can reach the Kubernetes API

### 1.8 Verify Cilium status

```bash
kubectl -n kube-system exec ds/cilium -- cilium status --brief
```

**Expected:** Shows `Routing: tunnel` and `IPAM: cluster-pool`.

### 1.9 Cleanup test pod

```bash
kubectl delete pod test-pod --ignore-not-found
```

### 1.10 Destroy

```bash
terraform destroy \
  -var-file="terraform.tfvars" \
  -var="enable_cilium=true" \
  -var='cilium_mode=overlay' \
  -var="create_hyperpod_module=false" \
  -var="create_helm_chart_module=false"
```

---

## Test 2: Chaining Mode

**What this tests:**
- VPC CNI addon IS deployed (chaining keeps it)
- Cilium Helm release deploys with chaining values
- NO VXLAN security group rules created
- VPC CNI handles IPAM (pods get VPC IPs), Cilium provides eBPF policy/LB
- Both aws-node and cilium DaemonSets coexist

### 2.1 Deploy

```bash
terraform apply \
  -var-file="terraform.tfvars" \
  -var="enable_cilium=true" \
  -var='cilium_mode=chaining' \
  -var="create_hyperpod_module=false" \
  -var="create_helm_chart_module=false"
```

### 2.2 Configure kubectl

```bash
aws eks update-kubeconfig --name sagemaker-hyperpod-eks-cluster --region us-west-2
```

### 2.3 Verify VPC CNI IS present

```bash
kubectl -n kube-system get daemonset aws-node
```

**Expected:** aws-node DaemonSet exists and has desired/ready pods.

```bash
aws eks list-addons --cluster-name sagemaker-hyperpod-eks-cluster --region us-west-2
```

**Expected:** Output includes `vpc-cni`.

### 2.4 Verify Cilium is running

```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium
kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium-operator
```

**Expected:** All pods `Running`, `READY 1/1`.

### 2.5 Verify NO VXLAN security group rules

```bash
SG_ID=$(terraform output -raw security_group_id 2>/dev/null || terraform state show 'module.security_group[0].aws_security_group.no_ingress[0]' | grep ' id ' | awk '{print $3}' | tr -d '"')
aws ec2 describe-security-group-rules --filter Name=group-id,Values=$SG_ID --query "SecurityGroupRules[?FromPort==\`8472\`]" --region us-west-2
```

**Expected:** Empty array `[]` — no VXLAN rules since chaining uses native routing.

### 2.6 Verify pod networking

```bash
kubectl run test-pod --image=busybox --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/test-pod --timeout=120s
kubectl get pod test-pod -o jsonpath='{.status.podIP}'
```

**Expected:** Pod gets a VPC-routable IP (e.g., 10.192.x.x or from the VPC CIDR range) — VPC CNI is handling IPAM.

### 2.7 Verify Cilium chaining status

```bash
kubectl -n kube-system exec ds/cilium -- cilium status --brief
```

**Expected:** Shows `Routing: native` and CNI chaining mode active.

### 2.8 Cleanup and destroy

```bash
kubectl delete pod test-pod --ignore-not-found
terraform destroy \
  -var-file="terraform.tfvars" \
  -var="enable_cilium=true" \
  -var='cilium_mode=chaining' \
  -var="create_hyperpod_module=false" \
  -var="create_helm_chart_module=false"
```

---

## Test 3: ENI Mode

**What this tests:**
- VPC CNI addon is NOT deployed
- Cilium Helm release deploys with ENI values
- IAM policy `cilium-eni-policy` is attached to the SageMaker execution role
- Pods get VPC-routable ENI IPs (similar to VPC CNI)
- Cilium manages ENI allocation instead of VPC CNI

### 3.1 Deploy

```bash
terraform apply \
  -var-file="terraform.tfvars" \
  -var="enable_cilium=true" \
  -var='cilium_mode=eni' \
  -var="create_hyperpod_module=false" \
  -var="create_helm_chart_module=false"
```

### 3.2 Configure kubectl

```bash
aws eks update-kubeconfig --name sagemaker-hyperpod-eks-cluster --region us-west-2
```

### 3.3 Verify VPC CNI is NOT present

```bash
kubectl -n kube-system get daemonset aws-node 2>&1
aws eks list-addons --cluster-name sagemaker-hyperpod-eks-cluster --region us-west-2
```

**Expected:** No aws-node DaemonSet. `vpc-cni` not in addons list.

### 3.4 Verify Cilium is running

```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium
kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium-operator
```

**Expected:** All pods `Running`, `READY 1/1`.

### 3.5 Verify IAM policy attachment

```bash
ROLE_NAME=$(terraform output -raw sagemaker_iam_role_name 2>/dev/null || terraform state show 'module.sagemaker_iam_role[0]' | grep 'role_name' | head -1 | awk '{print $3}' | tr -d '"')
aws iam list-role-policies --role-name $ROLE_NAME --region us-west-2
```

**Expected:** Output includes `cilium-eni-policy`.

### 3.6 Verify Cilium ENI status

```bash
kubectl -n kube-system exec ds/cilium -- cilium status --brief
```

**Expected:** Shows `Routing: native` and `IPAM: eni`.

### 3.7 Verify pod networking (once nodes available)

```bash
kubectl run test-pod --image=busybox --restart=Never -- sleep 3600
kubectl wait --for=condition=Ready pod/test-pod --timeout=120s
kubectl get pod test-pod -o jsonpath='{.status.podIP}'
```

**Expected:** Pod gets a VPC-routable IP from an ENI secondary IP (should be from the subnet CIDR range).

### 3.8 Cleanup and destroy

```bash
kubectl delete pod test-pod --ignore-not-found
terraform destroy \
  -var-file="terraform.tfvars" \
  -var="enable_cilium=true" \
  -var='cilium_mode=eni' \
  -var="create_hyperpod_module=false" \
  -var="create_helm_chart_module=false"
```

---

## Test 4: Default (No Cilium) - Regression

**What this tests:** Ensure `enable_cilium = false` (default) still works identically to before our changes.

### 4.1 Deploy with defaults

```bash
terraform apply \
  -var-file="terraform.tfvars" \
  -var="create_hyperpod_module=false" \
  -var="create_helm_chart_module=false"
```

### 4.2 Verify VPC CNI IS present

```bash
aws eks update-kubeconfig --name sagemaker-hyperpod-eks-cluster --region us-west-2
kubectl -n kube-system get daemonset aws-node
aws eks list-addons --cluster-name sagemaker-hyperpod-eks-cluster --region us-west-2
```

**Expected:** aws-node DaemonSet exists. `vpc-cni` in addons list.

### 4.3 Verify NO Cilium

```bash
kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium 2>&1
helm -n kube-system list | grep cilium
```

**Expected:** No cilium pods. No cilium Helm release.

### 4.4 Verify NO VXLAN rules

```bash
SG_ID=$(terraform output -raw security_group_id 2>/dev/null || terraform state show 'module.security_group[0].aws_security_group.no_ingress[0]' | grep ' id ' | awk '{print $3}' | tr -d '"')
aws ec2 describe-security-group-rules --filter Name=group-id,Values=$SG_ID --query "SecurityGroupRules[?FromPort==\`8472\`]" --region us-west-2
```

**Expected:** Empty — no VXLAN rules.

### 4.5 Destroy

```bash
terraform destroy \
  -var-file="terraform.tfvars" \
  -var="create_hyperpod_module=false" \
  -var="create_helm_chart_module=false"
```

---

## Troubleshooting

### Cilium pods in CrashLoopBackOff

```bash
kubectl -n kube-system logs -l app.kubernetes.io/name=cilium --tail=50
kubectl -n kube-system describe pod -l app.kubernetes.io/name=cilium
```

### Cilium operator not starting

```bash
kubectl -n kube-system logs -l app.kubernetes.io/name=cilium-operator --tail=50
```

### Pods stuck in ContainerCreating (no CNI)

Check if Cilium DaemonSet is ready on the node:
```bash
kubectl get nodes
kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium -o wide
```

### ENI mode: insufficient permissions

Check if the IAM policy is attached:
```bash
aws iam get-role-policy --role-name <role> --policy-name cilium-eni-policy
```

### CoreDNS not starting

CoreDNS needs a functioning CNI. If Cilium isn't ready, CoreDNS will be stuck:
```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
kubectl -n kube-system describe pods -l k8s-app=kube-dns
```

---

## Success Criteria

| Test | Pass Criteria |
|------|---------------|
| Overlay | Cilium running, no VPC CNI, VXLAN SG rules present, pods get cluster-pool IPs |
| Chaining | Both VPC CNI and Cilium running, pods get VPC IPs, no VXLAN rules |
| ENI | Cilium running, no VPC CNI, ENI IAM policy attached, pods get VPC-routable ENI IPs |
| Regression | VPC CNI running, no Cilium, no VXLAN rules — identical to pre-change behavior |
