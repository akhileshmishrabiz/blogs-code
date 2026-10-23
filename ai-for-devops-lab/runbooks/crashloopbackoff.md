# Runbook: CrashLoopBackOff

CrashLoopBackOff means the container starts, exits, and Kubernetes keeps restarting it with a growing delay.

## First check

Read the logs of the previous crashed container: `kubectl logs <name> -n <namespace> --previous`.
The real error is almost always in the last few lines.

## Common causes

A missing environment variable or config file. Compare the deployment spec with what the app expects.

A failing liveness probe that kills a healthy but slow-starting app. Add a startupProbe or raise initialDelaySeconds.

The app cannot reach a dependency such as a database at startup.
