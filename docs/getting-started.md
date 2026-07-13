# Getting Started

This guide walks you through deploying the security-observability-stack in a
local or cloud Kubernetes cluster. Two paths are covered:

- **Namespace mode** — a single tenant self-installs into their own namespace
- **Cluster mode** — a platform team installs cluster-wide, including GPU workloads

---

## Prerequisites

| Tool | Minimum version | Purpose |
|---|---|---|
| `kubectl` | 1.27+ | Applying manifests and verifying resources |
| `helm` | 3.12+ | Installing the observability chart |
| `docker` | 24+ | Building the custom collector image |
| `go` | 1.26+ | Running unit tests locally |
| Kubernetes cluster | 1.27+ | EKS, GKE, k3d, kind, or minikube |

Clone the repository:

```bash
git clone https://github.com/eugenekurasov/security-observability-stack.git
cd security-observability-stack
```

---

## Step 1 — Build the collector image

The Helm chart requires a custom OpenTelemetry Collector binary that includes
`k8spodlogreceiver`. The upstream `otel/opentelemetry-collector-contrib` image
does not include it and will fail to start.

```bash
# Build the image (runs OCB inside Docker — no local Go toolchain needed)
docker build -t otelcol-security:0.1.0 .

# Push to your registry
docker tag otelcol-security:0.1.0 ghcr.io/eugenekurasov/security-observability-stack/collector:0.1.0
docker push ghcr.io/eugenekurasov/security-observability-stack/collector:0.1.0
```

> **Local testing shortcut** — if you are using kind or k3d you can load the
> image directly instead of pushing:
> ```bash
> kind load docker-image otelcol-security:0.1.0
> # or
> k3d image import otelcol-security:0.1.0 -c <cluster-name>
> ```

---

## Step 2 — Install the Helm chart

### Namespace mode

```bash
helm install payments-obs helm/observability-stack \
  --namespace payments \
  -f examples/namespace-mode/values.yaml \
  --set collector.image.repository=otelcol-security \
  --set collector.image.tag=0.1.0 \
  --set collector.export.endpoint="<your-otlp-gateway>:4317"
```

### Cluster mode

```bash
kubectl create namespace observability

helm install platform-obs helm/observability-stack \
  --namespace observability \
  -f examples/cluster-mode/values.yaml \
  --set collector.image.repository=otelcol-security \
  --set collector.image.tag=0.1.0 \
  --set collector.export.endpoint="<your-otlp-gateway>:4317"
```

---

## Step 3 — Verify the deployment

### Check the collector pod is running

```bash
# Namespace mode
kubectl get pods -n payments

# Cluster mode
kubectl get pods -n observability
```

Expected output includes a `*-collector` pod in `Running` state.

### Check the collector logs

```bash
# Namespace mode
kubectl logs -n payments -l app.kubernetes.io/component=collector -f

# Cluster mode
kubectl logs -n observability -l app.kubernetes.io/component=collector -f
```

Look for lines like:
```
Everything is ready. Begin running and processing data.
```

Warnings about `stream failed, will retry` are normal on the first few seconds
while pods are initialising.

### Verify signals are flowing

**Logs** — trigger a log line from the sample app and confirm the collector picks it up:

```bash
# Generate a request to the nginx pod
kubectl exec -n payments deploy/payments-api -c api -- \
  wget -qO- http://localhost:8080/ 2>&1 || true

# Tail the collector log and look for the forwarded line
kubectl logs -n payments -l app.kubernetes.io/component=collector --tail=20
```

**Metrics** — check the self-monitoring endpoint is reachable:

```bash
kubectl port-forward -n payments svc/$(kubectl get svc -n payments -o name | grep collector) 8888:8888 &
curl -s http://localhost:8888/metrics | grep otelcol_receiver_accepted_log_records
```

**Events** — check Kubernetes events are being picked up:

```bash
# Force a visible event by scaling the deployment
kubectl scale deploy/payments-api -n payments --replicas=0
kubectl scale deploy/payments-api -n payments --replicas=2

# Look for ScalingReplicaSet events in the collector log
kubectl logs -n payments -l app.kubernetes.io/component=collector --tail=50 | grep event
```

---

## Troubleshooting

> Work in progress.

---

## Next steps

- Read [`docs/architecture.md`](architecture.md) for a full diagram of the signal pipeline and deployment modes
- See the [Roadmap](../README.md#roadmap) for planned features (rich filtering, HA load balancing)
