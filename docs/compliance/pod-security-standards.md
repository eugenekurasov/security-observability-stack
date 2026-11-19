# Kubernetes Pod Security Standards

How the collector's pod measures against the Kubernetes
[Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)
(PSS), the policy levels that Kubernetes' built-in Pod Security Admission
enforces per namespace.

This is the framework that measures this project's central design decision
most directly. The README's claim — log collection with no node-level trust —
is, in PSS terms, a claim about which level the collector can run under. See
[the index](README.md) for what these mappings claim and what they do not.

---

## Result

**Every collector Deployment the chart renders satisfies the Restricted
level**, the strictest of the three.

| Configuration | Deployments | Baseline (11 controls) | Restricted (6 controls) |
|---|---|---|---|
| Chart defaults (namespace mode) | 1 | ✅ 11/11 | ✅ 6/6 |
| [`examples/namespace-mode`](../../examples/namespace-mode/values.yaml) | 1 | ✅ 11/11 | ✅ 6/6 |
| [`examples/cluster-mode`](../../examples/cluster-mode/values.yaml) | 1 | ✅ 11/11 | ✅ 6/6 |
| [`examples/split-mode`](../../examples/split-mode/values.yaml) | 3 (`singletons`, `logs`, `traces`) | ✅ 11/11 each | ✅ 6/6 each |

The example gateway pods (`otel-gateway` in both example directories) also
satisfy Restricted.

**How this was checked:** each configuration was rendered with `helm template`
and every resulting pod spec was evaluated against each PSS control, with a
negative control — a typical node-reading collector pod with a `hostPath`
volume — confirming the check fails what it should. That is an offline
evaluation, not Kubernetes' own admission controller. To confirm on a live
cluster, have the API server evaluate the release's namespace without changing
anything:

```bash
kubectl label --dry-run=server --overwrite namespace <ns> \
  pod-security.kubernetes.io/enforce=restricted
```

Any running pod that would violate Restricted is reported as a warning; no
warnings means the namespace's pods pass.

---

## Control by control

From the collector's rendered pod spec, which is the same in every
configuration — its `securityContext` is fixed in the template, not exposed
through values.

### Baseline

| Control | Requirement | Collector |
|---|---|---|
| Host namespaces | `hostNetwork`, `hostPID`, `hostIPC` unset or false | ✅ Unset |
| Privileged containers | `privileged` unset or false | ✅ Unset |
| Capabilities | No additions beyond the baseline set | ✅ None added |
| **HostPath volumes** | **Forbidden** | ✅ Only volume is a `configMap` |
| Host ports | Forbidden | ✅ `containerPort` only |
| AppArmor | Not `Unconfined` | ✅ Runtime default |
| SELinux | Restricted type; no user or role | ✅ Unset |
| `/proc` mount type | `Default` | ✅ Unset (default) |
| Seccomp | Not `Unconfined` | ✅ `RuntimeDefault` |
| Sysctls | Safe set only | ✅ None |
| HostProcess (Windows) | Not set | ✅ Unset |

### Restricted

| Control | Requirement | Collector |
|---|---|---|
| Volume types | `configMap`, `csi`, `downwardAPI`, `emptyDir`, `ephemeral`, `persistentVolumeClaim`, `projected`, `secret` only | ✅ `configMap` |
| Privilege escalation | `allowPrivilegeEscalation: false` | ✅ |
| Running as non-root | `runAsNonRoot: true` | ✅ |
| Non-root user | `runAsUser` not 0 | ✅ `10001` |
| Seccomp | `RuntimeDefault` or `Localhost` | ✅ `RuntimeDefault` |
| Capabilities | Drop `ALL`; add at most `NET_BIND_SERVICE` | ✅ Drops `ALL`, adds nothing |

Beyond Restricted, the container also sets `readOnlyRootFilesystem: true`,
which PSS does not require.

---

## Why this is the comparison that matters

A collector that reads container logs from the node filesystem has to mount
`/var/log/pods` (or the runtime's log directory) as a `hostPath` volume.
**HostPath volumes are forbidden at the Baseline level** — not Restricted, the
*minimum* policy level. No amount of other hardening changes that: a
node-reading collector can run as non-root, drop every capability, and set
seccomp, and it still fails Baseline on that one control. Its namespace has to
be labelled `privileged` — or exempted in the admission controller's
configuration — which removes every PSS control for every pod there.

So the practical difference is not "slightly more hardened." It is whether the
namespace that holds your logging pipeline can enforce any Pod Security level
at all:

| | Node-reading collector (`hostPath`) | This collector |
|---|---|---|
| Strictest PSS level it can pass | Privileged — i.e. no controls | Restricted |
| Namespace label needed | `enforce: privileged` | `enforce: restricted` |
| What the label means for the rest of the namespace | every pod in it is exempt from all controls | every pod in it is held to the strictest level |

This is also why the stack runs on platforms that restrict host access
themselves — GKE Autopilot limits `hostPath` to read-only `/var/log`, and
Fargate and AKS Virtual Nodes schedule no DaemonSets at all; see
[Serverless Kubernetes](../architecture.md#serverless-kubernetes-fargate-aks-virtual-nodes-gke-autopilot).

---

## Limits and caveats

**PSS covers the pod, not its permissions.** It says nothing about what the
collector's ServiceAccount may do through the API. That half of the design —
RBAC scoped to `pods/log` and events in the tenant's namespaces — is a separate
question, covered in the [SOC 2 mapping](soc2.md) (CC6.1) and planned for a
CIS Kubernetes Benchmark mapping. A pod can be Restricted and still hold a
cluster-wide ClusterRole; in cluster mode, this one does, by design.

**Fixed in the template, which cuts both ways.** Because the security context
is not exposed through values, no override can weaken it. But it also cannot be
adapted: platforms that assign UIDs per namespace — OpenShift's
`restricted-v2` SCC, for example — reject a pod that pins `runAsUser` outside
the assigned range, so the hard-coded `10001` may need to become configurable
there.

**Cursor storage stays Restricted.** `signals.logs.cursorStorage` mounts an
`emptyDir` or a `persistentVolumeClaim`, both allowed under Restricted, and the
chart rejects any other volume type at render time. On a PVC the pod also sets
`fsGroup: 10001`, which Restricted allows, so the claim is writable by the
non-root uid. A `hostPath` volume would drop the collector to failing Baseline
and undo the property this document describes. (The OTel `k8s_events` receiver's own documentation also warns that
node-pinned volumes tie the pod to one node.)

**Nothing enforces this yet.** The examples do not label their namespaces with
`pod-security.kubernetes.io/enforce`, and no CI check renders the chart and
evaluates it. Today the property holds because nobody has broken it, not
because anything would stop them.
