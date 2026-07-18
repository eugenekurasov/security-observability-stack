[![CI](https://github.com/eugenekurasov/security-observability-stack/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/eugenekurasov/security-observability-stack/actions/workflows/ci.yml)
[![K8s compatibility tests](https://github.com/eugenekurasov/security-observability-stack/actions/workflows/integration.yml/badge.svg?branch=main)](https://github.com/eugenekurasov/security-observability-stack/actions/workflows/integration.yml)
[![Lint](https://github.com/eugenekurasov/security-observability-stack/actions/workflows/lint.yml/badge.svg?branch=main)](https://github.com/eugenekurasov/security-observability-stack/actions/workflows/lint.yml)


# Security Observability Stack

A Helm chart and custom OpenTelemetry Collector receiver for
compliance-oriented, multi-tenant observability on Kubernetes —
built for regulated environments (finance, healthcare) and serverless
platforms (AWS Fargate, GKE Autopilot, AKS Virtual Nodes) where
DaemonSets are restricted or unavailable, host access is limited by design,
and tenant isolation is a first-class requirement.

## Why this exists

Most observability stacks are built for a single-tenant, low-compliance
default: broad RBAC, host-level log access via DaemonSets, and no
built-in mapping to controls like SOC 2. Retrofitting compliance
onto that default is expensive and error-prone. DaemonSet-based collectors
also run into trouble on serverless node pools: Fargate blocks DaemonSets
outright, AKS Virtual Nodes exclude them from ACI-backed nodes, and GKE
Autopilot allows them only under tight resource limits with no write
access to the host filesystem.

This project takes the opposite approach: start from RBAC-scoped,
no-host-access collection and tenant isolation, then layer standard
observability signals on top. Because collection goes through the
Kubernetes API rather than the node filesystem, the same stack works
on standard nodes, GPU nodes, and serverless nodes without modification.

The core component, `k8spodlogreceiver`, provides a working implementation
of the API-server-based log collection mode discussed in
[open-telemetry/opentelemetry-collector-contrib#23339](https://github.com/open-telemetry/opentelemetry-collector-contrib/issues/23339)
— an approach raised in that thread as an alternative to hostPath-based
collection, but never implemented. Each serverless platform blocks the
DaemonSet/hostPath approach differently:

| Platform | What's blocked | API-based approach | Source |
|---|---|---|---|
| **AWS Fargate** | DaemonSets aren't supported at all | Deployment + API server, no per-node agent | [AWS EKS docs](https://docs.aws.amazon.com/eks/latest/userguide/fargate.html) |
| **AKS Virtual Nodes** | DaemonSets won't deploy pods to virtual nodes | Same Deployment, no node-resident collector needed | [Microsoft Learn](https://learn.microsoft.com/en-us/azure/aks/virtual-nodes) |
| **GKE Autopilot** | `hostPath` is read-only, `/var/log` only; reaching any tainted node type (GPU, spot, etc.) needs an explicit blanket toleration on top of that | No host mount, no DaemonSet, no tolerations to maintain | [GKE Autopilot security](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/autopilot-security) |

See [Serverless Kubernetes](docs/architecture.md#serverless-kubernetes-fargate-aks-virtual-nodes-gke-autopilot)
for the full breakdown, including why GKE Autopilot's `/var/log` exception still
doesn't remove the need for API-based collection. API-based collection sidesteps
all three constraints — on these platforms it's not an alternative but the only
viable path.


### Practical benefits over DaemonSet-based collectors

| Benefit | Detail |
|---|---|
| **No collector on GPU nodes - ideal for AI clusters** | A DaemonSet schedules a collector pod on every node, including expensive GPU nodes (A100, H100). This wastes CPU and memory on nodes that should be 100% dedicated to training or inference. This stack runs as a single Deployment on a cheap CPU node and streams logs from GPU pods through the Kubernetes API — GPU nodes are never touched by the collector. |
| **No hostPath mount** | DaemonSet collectors read log files from the host filesystem (`/var/log/pods/`), requiring broad read access to the node root. This is a common security finding in regulated environments. |
| **Lower total resource footprint** | One collector Deployment instead of N DaemonSet pods (one per node). On EKS and GKE the managed API server handles streaming connections without dedicated cluster resources — there is no meaningful overhead for this use case. On self-hosted clusters, log data traverses the API server rather than being read locally, which is worth accounting for when sizing the control plane. |
| **Works on serverless node pools (Fargate, GKE Autopilot, AKS Virtual Nodes)** | AWS Fargate, GKE Autopilot, and AKS Virtual Nodes block DaemonSet scheduling and disallow hostPath mounts — making node-based collectors incompatible by design. Because this stack is a plain Deployment that reads through the Kubernetes API, it collects from pods on serverless nodes with no special configuration. Mixed-mode clusters (some standard nodes, some serverless) are the typical case: run the collector on one standard CPU node and it streams logs from pods on Fargate or virtual nodes automatically. |

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
| `k8spodlogreceiver` | [`otel-components/k8spodlogreceiver/`](otel-components/k8spodlogreceiver/) | Development / proof-of-concept |
| Examples | [`examples/`](examples/) | Available |
| Terraform modules | `terraform/` | Planned |
| Compliance mapping | [`docs/compliance-mapping.md`](docs/compliance-mapping.md) | Available |

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
image that includes `k8spodlogreceiver`. Update `collector.image` in
`values.yaml` once the OCB manifest and image build are in place.

`k8seventsreceiver`, the Prometheus receiver, and the OTLP receiver all ship
in the standard `otel/opentelemetry-collector-contrib` image — a custom build
is only required for container log collection.

## Roadmap

### v1 (current)
- Single collector replica per tenant — `activeStreams` tracking is in-process only
- Raw log lines forwarded as-is, one OTel log record per line

### TODO

- [ ] **Add renovate** we need to be able keep up in date the package and docker image

- [ ] **CI flow** Add a GitHub Actions workflow to build and push images to ghcr.io. Also add a release workflow for the Helm chart and the Otel Component(`k8spodlogreceiver`)

- [ ] **Rich filtering and parsing** — Stanza-style operator pipeline on top of the raw stream:
  multiline joining (stack traces, JSON blobs), structured log parsing, per-container format
  routing, and label/annotation-based filter rules. Goal: feature parity with
  `filelogreceiver` filtering without the hostPath requirement.

- [X] **Label filtering** - Maybe we want also to be able filter pod by label. Possibly out of scope — feedback welcome.

- [ ] **Load balancing / HA** - Add load balancing to support running multiple instances concurrently, and configure high availability (HA) so that replication continues if one of the instances fails. Possible `HA` will be implemented similar to K8sLeaderElector in the `k8sclusterreceiver` in the future.

- [ ] **Terraform** - add tf modules for EKS and GKE cluster init with all required combinations.

- [ ] **Benchmark test** - prepare a benchmark test for the new component.

- [ ] **Node metrics: direct kubelet scraping** — In cluster mode the node scrape jobs currently route through the API server proxy (`/api/v1/nodes/$1/proxy/metrics`, `/api/v1/nodes/$1/proxy/metrics/cadvisor`). At scale every Prometheus scrape of every node passes through the control plane. Switch to direct kubelet scraping on port 10250 (same pattern as `kube-prometheus-stack`) to remove the API server from the node metrics path entirely. Possibly out of scope — feedback welcome

## Status

Early-stage, actively developed. See each component's README for current
status and known limitations before using anything in production.

## License

Apache 2.0 — see [LICENSE](LICENSE).
