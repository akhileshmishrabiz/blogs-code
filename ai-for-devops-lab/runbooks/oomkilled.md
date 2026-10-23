# Runbook: Container OOMKilled

OOMKilled (exit code 137) means the container used more memory than its limit and the kernel killed it.

## First check

Run `kubectl describe pod <name> -n <namespace>` and look for "Last State: Terminated, Reason: OOMKilled".
Compare the memory limit with real usage from `kubectl top pod`.

## Fix

If usage is legitimately higher, raise the memory limit and request together.

If usage keeps growing until the kill, it is likely a memory leak. Capture a heap profile before raising limits.
