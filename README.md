[![CI](https://github.com/eugenekurasov/security-observability-stack/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/eugenekurasov/security-observability-stack/actions/workflows/ci.yml)

# Security Observability Stack

A Helm chart and a custom OpenTelemetry Collector receiver that collect
Kubernetes pod logs through the API server instead of the node filesystem —
no DaemonSet, no `hostPath`, no node-level privilege. Access is scoped by
ordinary Kubernetes RBAC on the `pods/log` subresource, which makes per-tenant
log collection an enforced boundary rather than a deployment convention, and
makes the stack deployable on serverless node pools (AWS Fargate, AKS Virtual
Nodes, GKE Autopilot) where DaemonSets are blocked or restricted.

## Why this exists

Most observability stacks assume a single tenant and a node-level collector:
broad RBAC plus host log access via a DaemonSet reading `/var/log/pods/`. That
assumption breaks in two places. It grants a workload read access to the host
root for what is functionally a narrow task, and it does not work at all on
serverless node pools — Fargate blocks DaemonSets outright, AKS Virtual Nodes
exclude them from ACI-backed nodes, and GKE Autopilot permits them only under
tight resource limits with read-only access to `/var/log`.

This project starts from the opposite end: RBAC-scoped, API-mediated collection
with no host access, then standard observability signals layered on top.
Because collection goes through the Kubernetes API rather than the node
filesystem, the same deployment works on standard, GPU, and serverless nodes
without modification.

The core component, [`k8spodlogreceiver`](https://github.com/eugenekurasov/k8spodlogreceiver), provides a working implementation
of the API-server-based log collection mode discussed in
[open-telemetry/opentelemetry-collector-contrib#23339](https://github.com/open-telemetry/opentelemetry-collector-contrib/issues/23339)
— an approach raised in that thread as an alternative to hostPath-based
collection, but never implemented.

Each serverless platform blocks the DaemonSet/hostPath approach differently:
Fargate does not support DaemonSets at all, AKS Virtual Nodes will not schedule
them onto ACI-backed nodes, and GKE Autopilot restricts `hostPath` to a
read-only `/var/log` while taints on specialized node types force a blanket
toleration. API-based collection sidesteps all three — on these platforms it is
not an alternative but the only viable path. See
[Serverless Kubernetes](docs/architecture.md#serverless-kubernetes-fargate-aks-virtual-nodes-gke-autopilot)
for the per-platform breakdown with sources, including why GKE Autopilot's
`/var/log` exception still does not remove the need for it.


### Practical benefits over DaemonSet-based collectors

| Benefit | Detail |
|---|---|
| **No collector on GPU nodes - ideal for AI clusters** | A DaemonSet schedules a collector pod on every node, including expensive GPU nodes (A100, H100). This wastes CPU and memory on nodes that should be 100% dedicated to training or inference. This stack runs as a single Deployment on a cheap CPU node and streams logs from GPU pods through the Kubernetes API — GPU nodes are never touched by the collector. |
| **No hostPath mount** | DaemonSet collectors read log files from the host filesystem (`/var/log/pods/`), requiring broad read access to the node root. This is a recurring finding in Kubernetes security review. |
| **Lower total resource footprint** | One collector Deployment instead of N DaemonSet pods (one per node). On EKS and GKE the managed API server handles streaming connections without dedicated cluster resources — there is no meaningful overhead for this use case. On self-hosted clusters, log data traverses the API server rather than being read locally, which is worth accounting for when sizing the control plane. |
| **Works on serverless node pools (Fargate, GKE Autopilot, AKS Virtual Nodes)** | AWS Fargate and AKS Virtual Nodes don't schedule DaemonSet pods at all, and GKE Autopilot restricts `hostPath` to read-only `/var/log` — so node-based collectors are either impossible or constrained on these platforms. Because this stack is a plain Deployment that reads through the Kubernetes API, it collects from pods on serverless nodes with no special configuration. Mixed-mode clusters (some standard nodes, some serverless) are the typical case: run the collector on one standard CPU node and it streams logs from pods on Fargate or virtual nodes automatically. |

## What it covers

Scoped to **tenant application observability** — signals a service team owns
from their own pods:

| Signal | Mechanism |
|---|---|
| **Container logs** | `k8spodlogreceiver` streams stdout/stderr via the Kubernetes API (same path as `kubectl logs`) — no hostPath mount, no DaemonSet |
| **Kubernetes events** | `k8seventsreceiver` watches Event objects in the tenant's namespace(s) — pod restarts, OOMKills, scheduling failures, quota violations |
| **Metrics** | Prometheus receiver scrapes pods annotated with `prometheus.io/scrape: "true"` |
| **Traces** | OTLP receiver accepts spans over gRPC/HTTP from application code |

### What it intentionally does not cover

Node logs, host-level metrics, control plane logs, and container runtime logs
are all out of scope — each needs the node-level trust this stack exists to
avoid. If you need them, they belong in a separate cluster-operator-managed
pipeline, not mixed into per-tenant collectors. See
[Scope](docs/architecture.md#scope) for the per-item reasoning.

## Components

| Component | Path | Status |
|---|---|---|
| Helm chart | [`helm/observability-stack/`](helm/observability-stack/) | Available |
| `k8spodlogreceiver` | [eugenekurasov/k8spodlogreceiver](https://github.com/eugenekurasov/k8spodlogreceiver) (separate repo) | See [receiver status](https://github.com/eugenekurasov/k8spodlogreceiver#status) |
| Examples | [`examples/`](examples/) | Available |
| Compliance mappings | [`docs/compliance/`](docs/compliance/) — [SOC 2](docs/compliance/soc2.md), [CISA LRA](docs/compliance/cisa-lra.md), [Pod Security Standards](docs/compliance/pod-security-standards.md) | Available |

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
   collector cannot read arbitrary node files. Every collector pod the chart
   renders satisfies the Kubernetes Pod Security Standards **Restricted**
   level; a collector that mounts `hostPath` fails even Baseline — see
   [the PSS mapping](docs/compliance/pod-security-standards.md).

2. **Tenant isolation is an RBAC boundary, not a convention.** In namespace
   mode the Helm chart generates a `Role` + `RoleBinding` scoped to the
   tenant's namespace(s). The RBAC grants only the permissions required by
   the signals that are enabled.

3. **Control mapping is explicit, not implied.** See
   [`docs/compliance/`](docs/compliance/) for how the stack's controls map to
   SOC 2 Trust Services Criteria and to CISA's Logging Reference Architecture —
   including, in both, where the mapping stops.

4. **Infrastructure and application code are versioned together.**
   Helm and the custom collector build manifest live in one repo so the
   deployed system is reproducible from source.

5. **Zero footprint on specialized nodes.** The collector never schedules
   onto GPU, high-memory, or otherwise tainted nodes. In AI/ML clusters
   this means inference and training nodes are fully dedicated to workloads —
   no DaemonSet pod competing for CPU or memory on a node that costs orders
   of magnitude more than a standard worker.

## Collector image

The Helm chart references `secobs-collector`, a custom distribution of the
OpenTelemetry Collector built with
[OpenTelemetry Collector Builder (OCB)](https://github.com/open-telemetry/opentelemetry-collector/tree/main/cmd/builder)
that includes `k8spodlogreceiver`, pulled from its own repository as a
pinned module — see [`builder-config.yaml`](builder-config.yaml).
Update `collector.image` in `values.yaml` once the image build is in place.

`k8seventsreceiver`, the Prometheus receiver, and the OTLP receiver all ship
in the standard `otel/opentelemetry-collector-contrib` image — a custom build
is only required for container log collection.

## Roadmap

`k8spodlogreceiver` moved to [its own repository](https://github.com/eugenekurasov/k8spodlogreceiver);
work on the receiver itself is tracked there. This list is the chart, the
collector image, and CI — what this repository actually ships.

### TODO

- [x] **Persist read cursors across collector restarts** —
  `signals.logs.cursorStorage` (on by default) gives `k8s_pod_log` a
  `file_storage` extension on its own volume. The default `emptyDir` keeps
  cursors across container restarts; `volume.type: persistentVolumeClaim` also
  keeps them across pod replacement, at the cost of `replicas: 1` and the
  `Recreate` strategy. No `hostPath`, so Pod Security Restricted still holds —
  see [the LRA mapping](docs/compliance/cisa-lra.md#delivery-assurance-logs-checkpointed-events-not).

- [ ] **TLS on the export hop by default** — `collector.export.tls.insecure`
  defaults to `true`, on the assumption that a service mesh supplies mTLS
  in-cluster. Without a mesh the first hop is plaintext, which fails the
  M-26-14 Log Management maturity level agencies are required to reach — see
  [the LRA mapping](docs/compliance/cisa-lra.md#log-management-maturity-the-chart-default-fails-level-3).
  Flip the default, and make running without TLS the explicit opt-out.

- [ ] **A redaction point before data leaves the boundary** — the collector
  forwards container stdout verbatim, including whatever PII or tokens an
  application prints, and the example gateway is the stock core image, which
  has no redaction or transform processor. Ship an example gateway built with
  one, so the documented pattern actually redacts — see
  [the LRA mapping](docs/compliance/cisa-lra.md#sensitive-data-protection).

- [ ] **Enforce Pod Security Restricted in CI** — every rendered collector pod
  satisfies Restricted today, but nothing checks it. Render each example in CI
  and fail on any PSS violation, and label the example namespaces
  `pod-security.kubernetes.io/enforce: restricted` so the examples demonstrate
  the claim instead of asserting it — see
  [the PSS mapping](docs/compliance/pod-security-standards.md).

- [ ] **Raise the Events restart gap upstream** — `k8s_events` drops every
  Event older than the receiver's start, and its `storage` option prevents
  duplicates on resume but does not recover the downtime window, so each
  collector restart is a permanent gap in Events. Not fixable from the chart;
  belongs in an issue on `opentelemetry-collector-contrib` — see
  [the LRA mapping](docs/compliance/cisa-lra.md#cluster-state-and-events-the-layer-this-stack-delivers).

- [ ] **Add renovate** — keep the pinned module versions in `builder-config.yaml`
  and the base images in `Dockerfile` current.

- [ ] **CI flow** — a GitHub Actions workflow to build and push images to
  ghcr.io, plus a release workflow for the Helm chart.

- [ ] **Node metrics: direct kubelet scraping** — in cluster mode the node scrape
  jobs route through the API server proxy (`/api/v1/nodes/$1/proxy/metrics`,
  `/api/v1/nodes/$1/proxy/metrics/cadvisor`). At scale every Prometheus scrape of
  every node passes through the control plane. Switch to direct kubelet scraping
  on port 10250 (same pattern as `kube-prometheus-stack`) to take the API server
  out of the node metrics path. Not tied to `k8spodlogreceiver` — feedback welcome.

### Constraints inherited from the receiver

These are not tracked here, but they shape how the chart is deployed. Full
detail in the [receiver's known limitations](https://github.com/eugenekurasov/k8spodlogreceiver#known-limitations).

- **Run a single replica per scope.** Stream ownership is in-process, so two
  replicas stream the same pods and duplicate every record. Scale by
  partitioning — one release per tenant or namespace group — which is the shape
  this chart is built for anyway.
- **One log record per line.** No multiline joining or structured parsing; do it
  downstream.
- **stdout and stderr arrive merged**, with no per-line marker — the `pods/log`
  endpoint does not expose which stream a line came from.

## Status

Early-stage, actively developed. For `k8spodlogreceiver`, the current status
and stable version are tracked in
[its README](https://github.com/eugenekurasov/k8spodlogreceiver#status) — check
it and the [known limitations](https://github.com/eugenekurasov/k8spodlogreceiver#known-limitations)
before using anything in production.

## License

Apache 2.0 — see [LICENSE](LICENSE).
