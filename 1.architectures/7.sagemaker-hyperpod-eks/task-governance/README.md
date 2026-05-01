# SageMaker HyperPod Task Governance

SageMaker HyperPod task governance is a management system designed to streamline resource allocation and ensure efficient utilization of compute resources across teams and projects for your Amazon EKS clusters. It provides administrators with the capability to set priority levels for various tasks, allocate compute resources for each team, determine how idle compute is borrowed and lent between teams, and configure whether a team can preempt its own tasks.

HyperPod task governance leverages Kueue for Kubernetes-native job queueing, scheduling, and quota management and is installed using the HyperPod task governance EKS add-on. When installed, HyperPod creates and modifies SageMaker AI-managed Kubernetes resources such as:
- KueueManagerConfig
- ClusterQueues
- LocalQueues
- WorkloadPriorityClasses
- ResourceFlavors
- ValidatingAdmissionPolicies

While Kubernetes administrators have the flexibility to modify the state of these resources, any changes made to a SageMaker AI-managed resource may be updated and overwritten by the service.

## Enable Task Governance

### Prerequisites

- Amazon EKS cluster running Kubernetes version 1.30 or greater

- No existing installations of Kueue (it must be removed before installing the add-on)

### Installation Steps

To install the **SageMaker HyperPod task governance EKS add-on**, run the following command:

```
aws eks create-addon --region $REGION --cluster-name $EKS_CLUSTER_NAME --addon-name amazon-sagemaker-hyperpod-taskgovernance
```

Verify successful installation with:

```
aws eks describe-addon --region $REGION --cluster-name $EKS_CLUSTER_NAME --addon-name amazon-sagemaker-hyperpod-taskgovernance
```

If the installation was successful, you should see details about the installed add-on in the output.

## Setup for running the examples

### Cluster Policy and Compute Allocation Setup

Before running the examples, you need to set up a Cluster Policy and define Compute Allocations for the teams.

This example assumes a cluster with **4 g5.8xlarge instances** and two teams (Team A and Team B). The Cluster Policy will use task ranking instead of the default FIFO (First-In-First-Out) behavior, allowing tasks with higher priorities to preempt lower-priority tasks.

#### Create a Cluster Policy

To update how tasks are prioritized and how idle compute is allocated, apply a Cluster Policy using the following placeholder configuration:

```
aws sagemaker \
    --region $REGION \
    create-cluster-scheduler-config \
    --name "example-cluster-scheduler-config" \
    --cluster-arn "<Enter HyperPod ClusterArn>" \
    --scheduler-config "PriorityClasses=[{Name=inference,Weight=90},{Name=experimentation,Weight=80},{Name=fine-tuning,Weight=50},{Name=training,Weight=70}],FairShare=Enabled"
```

#### Create Compute Allocations

Each team requires a Compute Allocation to manage their compute capacity. Both teams will have 2 instances allocated, 100 fair-share weight, and 50% borrowing capability.

If you are deploying the HyperPod EKS Terraform module, you can configure compute allocations with the `task_governance_compute_quotas` variable instead of running the following AWS CLI commands manually. See the [Terraform module README](../terraform-modules/README.md#task-governance-compute-allocations) for an example.

```
aws sagemaker \
    --region $REGION \
    create-compute-quota \
    --name "Team-A-Quota-Allocation" \
    --cluster-arn "<Enter HyperPod ClusterArn>" \
    --compute-quota-config "ComputeQuotaResources=[{InstanceType=ml.g5.8xlarge,Count=2}],ResourceSharingConfig={Strategy=LendAndBorrow,BorrowLimit=50},PreemptTeamTasks=LowerPriority" \
    --activation-state "Enabled" \
    --compute-quota-target "TeamName=team-a,FairShareWeight=0"
```

```
aws sagemaker \
    --region $REGION \
    create-compute-quota \
    --name "Team-B-Quota-Allocation" \
    --cluster-arn "<Enter HyperPod ClusterArn>" \
    --compute-quota-config "ComputeQuotaResources=[{InstanceType=ml.g5.8xlarge,Count=2}],ResourceSharingConfig={Strategy=LendAndBorrow,BorrowLimit=50},PreemptTeamTasks=LowerPriority" \
    --activation-state "Enabled" \
    --compute-quota-target "TeamName=team-b,FairShareWeight=0"
```

If using a different cluster size, adjust the CLI commands and job submission configurations accordingly.

## Running the examples

Once the cluster policy and compute allocations are configured, you can run the following examples demonstrating various aspects of HyperPod task governance:

### Job 1: Idle Compute Usage

**Scenario:** Team A submits a PyTorch job that requires **3 instances** but only has **2 allocated**. The system allows Team A to **borrow** 1 instance from Team B's idle capacity.

```
kubectl apply -f 1-imagenet-gpu-team-a.yaml --namespace hyperpod-ns-team-a
```

Verify the job is running (pulling the container image might take a moment):
```
kubectl get pods -n hyperpod-ns-team-a
```

Once the pods are running, you can check the output of logs to identify the elected master:
```
kubectl logs imagenet-gpu-team-a-1-worker-0 --namespace hyperpod-ns-team-a | grep master_addr=
```
```
[2025-02-04 18:58:08,460] torch.distributed.elastic.agent.server.api: [INFO]   master_addr=imagenet-gpu-team-a-1-worker-2
```
You can then use the pod referenced in the `master_addr` to look at the current training progress:
```
kubectl logs imagenet-gpu-team-a-1-worker-2 --namespace hyperpod-ns-team-a
```

### Job 2: Guaranteed Compute

**Scenario:** Team B needs to reclaim its compute resources. By submitting a job requiring **2 instances**, Team B's job is **prioritized**, and Job 1 is **suspended** due to resource unavailability.

In this example, we'll be using the hyperpod CLI, but we could also use kubectl and have identical behavior.

```
hyperpod start-job --config-file 2-hyperpod-cli-example-team-b.yaml
```

After the job has been submitted, you can see that the workers from Job 1 have been preempted, and only the workers in Team B's namespace are running.
```
kubectl get pods -n hyperpod-ns-team-a
```
Check running pods for Team B:
```
kubectl get pods -n hyperpod-ns-team-b
```

### Job 3: Preemption by Priorities

**Scenario:** Team B submits a **high-priority job** requiring **2 instances**. Since high-priority jobs take precedence, **Job 2 is suspended**, ensuring Team B’s critical workload runs first.


```
kubectl apply -f 3-imagenet-gpu-team-b-higher-prio.yaml --namespace hyperpod-ns-team-b
```

Since this job uses a **priority-class** with a higher weight than the other jobs, the lower-priority Job 2 is preempted:

```
kubectl get pods -n hyperpod-ns-team-b
```
### Inspecting workloads

We can also inspect the workloads on a particular namespace:
```
kubectl get workloads -n hyperpod-ns-team-b
```
This is an example output of the command after running all 3 scenarios:

```
NAME                                         QUEUE                           RESERVED IN                       ADMITTED   FINISHED   AGE
pod-etcd-gpu-6584d647d4-sp6xx-bb3f9          hyperpod-ns-team-b-localqueue   hyperpod-ns-team-b-clusterqueue   True                  11s
pytorchjob-hyperpod-cli-mnist-team-b-2c720   hyperpod-ns-team-b-localqueue                                     False                 45s
pytorchjob-imagenet-gpu-team-b-2-ef5c0       hyperpod-ns-team-b-localqueue   hyperpod-ns-team-b-clusterqueue   True                  11s
```
We can see that the workload for Job 2 has been set to `ADMITTED: False` because the newly submitted workload took precedence.

When we describe the suspended workload, we can see the reason it was preempted.
```
kubectl describe workload pytorchjob-hyperpod-cli-mnist-team-b-2c720 -n hyperpod-ns-team-b
```

```
Status:
  Conditions:
    Last Transition Time:  2025-02-04T19:06:25Z
    Message:               couldn't assign flavors to pod set worker: borrowing limit for nvidia.com/gpu in flavor ml.g5.8xlarge exceeded
    Observed Generation:   1
    Reason:                Pending
    Status:                False
    Type:                  QuotaReserved
    Last Transition Time:  2025-02-04T19:06:25Z
    Message:               Preempted to accommodate a workload (UID: d34468c2-1ce5-47cd-a61d-689be78b6121) due to prioritization in the ClusterQueue
    Observed Generation:   1
    Reason:                Preempted
    Status:                True
    Type:                  Evicted
    Last Transition Time:  2025-02-04T19:06:25Z
    Message:               The workload has no reservation
    Observed Generation:   1
    Reason:                NoReservation
    Status:                False
    Type:                  Admitted
    Last Transition Time:  2025-02-04T19:06:25Z
    Message:               Preempted to accommodate a workload (UID: d34468c2-1ce5-47cd-a61d-689be78b6121) due to prioritization in the ClusterQueue
    Reason:                InClusterQueue
    Status:                True
    Type:                  Preempted
    Last Transition Time:  2025-02-04T19:06:25Z
    Message:               Preempted to accommodate a workload (UID: d34468c2-1ce5-47cd-a61d-689be78b6121) due to prioritization in the ClusterQueue
    Observed Generation:   1
    Reason:                Preempted
    Status:                True
    Type:                  Requeued
```
