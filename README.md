# Security Observability Stack

Infrastructure-as-code and custom OpenTelemetry Collector components for
deploying compliance-oriented, multi-tenant observability on Kubernetes —
built for regulated environments (finance, healthcare) where log access,
tenant isolation, and audit trails are first-class requirements, not
afterthoughts.

## Why this exists

Most observability stacks are built for a single-tenant, low-compliance
default: broad RBAC, host-level log access via DaemonSets, and no
built-in mapping to controls like SOC 2 or HIPAA. Retrofitting compliance
onto that default is expensive and error-prone.

This project takes the opposite approach: start from RBAC-scoped,
no-host-access collection and tenant isolation, then layer standard
observability signals on top.

### Practical benefits over DaemonSet-based collectors

| Benefit | Detail |
|---|---|
| **No collector on GPU nodes - ideal for AI clusters** | A DaemonSet schedules a collector pod on every node, including expensive GPU nodes (A100, H100). This wastes CPU and memory on nodes that should be 100% dedicated to training or inference. This stack runs as a single Deployment on a cheap CPU node and streams logs from GPU pods through the Kubernetes API — GPU nodes are never touched by the collector. |
| **No hostPath mount** | DaemonSet collectors read log files from the host filesystem (`/var/log/pods/`), requiring broad read access to the node root. This is a common security finding in regulated environments. |
| **Lower total resource footprint** | One collector Deployment instead of N DaemonSet pods (one per node). On EKS and GKE the managed API server handles streaming connections without dedicated cluster resources — there is no meaningful overhead for this use case. On self-hosted clusters, log data traverses the API server rather than being read locally, which is worth accounting for when sizing the control plane. |

## What it covers

Scoped to **tenant application observability** — signals a service team owns
from their own pods:

| Signal | Mechanism |
|---|---|
| **Container logs** | `k8sapilogreceiver` streams stdout/stderr via the Kubernetes API (same path as `kubectl logs`) — no hostPath mount, no DaemonSet |
| **Kubernetes events** | `k8seventsreceiver` watches Event objects in the tenant's namespace(s) — pod restarts, OOMKills, scheduling failures, quota violations |
| **Metrics** | Prometheus receiver scrapes pods annotated with `prometheus.io/scrape: "true"` |
| **Traces** | OTLP receiver accepts spans over gRPC/HTTP from application code |

### What it intentionally does not cover

| Out of scope | Why |
|---|---|
| Node logs (systemd journal, kubelet, containerd) | Requires hostPath mounts or a privileged DaemonSet — exactly the node-level trust this stack avoids |
| Host-level metrics (disk I/O, network interfaces, OS-layer CPU) | Node exporters need host namespace access |
| Control plane logs (kube-apiserver, etcd, scheduler) | Cluster operator concern, not tenant concern |
| Container runtime / image pull logs | Below the pod API boundary |

If node-level telemetry is needed, it belongs in a separate cluster-operator-managed pipeline — not mixed into per-tenant collectors.

## Components

| Component | Path | Status |
|---|---|---|
| Helm chart | [`helm/observability-stack/`](helm/observability-stack/) | Available |
| `k8sapilogreceiver` | [`otel-components/k8sapilogreceiver/`](otel-components/k8sapilogreceiver/) | Development / proof-of-concept |
| Examples | [`examples/`](examples/) | Available |
| Terraform modules | `terraform/` | Planned |
| Compliance mapping | `docs/compliance-mapping.md` | Planned |

### Examples

| Example | Path | Scenario |
|---|---|---|
| Namespace mode | [`examples/namespace-mode/`](examples/namespace-mode/) | Single tenant self-installs into their own namespace — no cluster-admin required |
| Cluster mode | [`examples/cluster-mode/`](examples/cluster-mode/) | Platform team collects from all namespaces, including GPU inference workloads, with the collector running on a CPU node |

See [`docs/architecture.md`](docs/architecture.md) for the system diagram and design principles.

## Quick start

### Namespace mode — tenant self-install

Each tenant installs into their own namespace. The chart creates a
`Role` + `RoleBinding` scoped to that namespace only — no cluster-admin
required.

```bash
helm install my-obs helm/observability-stack \
  --namespace payments \
  --create-namespace \
  --set tenantId=payments
```

All four signals (container logs, events, metrics, traces) are enabled by
default. Disable any you don't need:

```bash
helm install my-obs helm/observability-stack \
  --namespace payments \
  --set tenantId=payments \
  --set signals.traces.enabled=false
```

To watch additional namespaces owned by the same tenant:

```bash
helm install my-obs helm/observability-stack \
  --namespace payments \
  --set tenantId=payments \
  --set namespaces="{payments,payments-staging}"
```

### Cluster mode — platform admin install

Creates a `ClusterRole` + `ClusterRoleBinding`. Collects signals from all
namespaces and can additionally scrape node-level metrics.
`
```bash
helm install platform-obs helm/observability-stack \
  --namespace observability \
  --create-namespace \
  --set mode=cluster
```

### Configure the export endpoint

All signals are forwarded to a single OTLP endpoint:

```bash
helm install my-obs helm/observability-stack \
  --namespace payments \
  --set collector.export.endpoint="my-gateway:4317" \
  --set collector.export.tls.insecure=false
```

## Design principles

1. **No node-level trust by default.** Log and event collection use the
   Kubernetes API server, not host filesystem mounts, so a compromised
   collector cannot read arbitrary node files.

2. **Tenant isolation is an RBAC boundary, not a convention.** In namespace
   mode the Helm chart generates a `Role` + `RoleBinding` scoped to the
   tenant's namespace(s). The RBAC grants only the permissions required by
   the signals that are enabled.

3. **Compliance mapping is explicit, not implied.** See
   `docs/compliance-mapping.md` (planned) for a control-by-control mapping
   to SOC 2 requirements.

4. **Infrastructure and application code are versioned together.**
   Terraform, Helm, and the custom collector build manifest live in one
   repo so the deployed system is reproducible from source.

5. **Zero footprint on specialized nodes.** The collector never schedules
   onto GPU, high-memory, or otherwise tainted nodes. In AI/ML clusters
   this means inference and training nodes are fully dedicated to workloads —
   no DaemonSet pod competing for CPU or memory on a node that costs orders
   of magnitude more than a standard worker.

## Collector image

The Helm chart references a custom
[OpenTelemetry Collector Builder (OCB)](https://github.com/open-telemetry/opentelemetry-collector/tree/main/cmd/builder)
image that includes `k8sapilogreceiver`. Update `collector.image` in
`values.yaml` once the OCB manifest and image build are in place.

`k8seventsreceiver`, the Prometheus receiver, and the OTLP receiver all ship
in the standard `otel/opentelemetry-collector-contrib` image — a custom build
is only required for container log collection.

## Roadmap

### v1 (current)
- Single collector replica per tenant — `activeStreams` tracking is in-process only
- Raw log lines forwarded as-is, one OTel log record per line

### TODO

- [ ] **Rich filtering and parsing** — Stanza-style operator pipeline on top of the raw stream:
  multiline joining (stack traces, JSON blobs), structured log parsing, per-container format
  routing, and label/annotation-based filter rules. Goal: feature parity with
  `filelogreceiver` filtering without the hostPath requirement.

- [ ] **Load balancing / HA** — In the first version the collector is intentionally a single
  runner; stream state lives in-process so running two replicas would duplicate every log line.
  Planned approach: distribute pod ownership across replicas using a consistent-hash ring on
  pod UID, with a shared coordination layer (e.g. leader election via Kubernetes leases) so
  each container is owned by exactly one replica. This unlocks horizontal scaling for large
  tenants without sacrificing exactly-once delivery.

## Status

Early-stage, actively developed. See each component's README for current
status and known limitations before using anything in production.

## License

Apache 2.0 — see [LICENSE](LICENSE).
