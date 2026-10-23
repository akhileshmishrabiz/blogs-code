# Runbook: Pod stuck in Pending

A Pending pod has been accepted by the cluster but not scheduled onto a node.

## First check

Run `kubectl describe pod <name> -n <namespace>` and read the Events section at the bottom.
The scheduler writes the reason there.

## Common causes

Insufficient CPU or memory on every node. Fix by lowering requests or adding nodes.

A nodeSelector, affinity rule or taint that no node satisfies. Fix the selector or add a matching toleration.

An unbound PersistentVolumeClaim. Check `kubectl get pvc -n <namespace>` and the storage class.
