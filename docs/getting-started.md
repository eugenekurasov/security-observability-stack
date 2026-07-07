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
git clone https://github.com/YOUR_GITHUB_HANDLE/security-observability-stack.git
cd security-observability-stack
```

---

## Step 1 — Build the collector image

The Helm chart requires a custom OpenTelemetry Collector binary that includes
`k8sapilogreceiver`. The upstream `otel/opentelemetry-collector-contrib` image
does not include it and will fail to start.

```bash
# Build the image (runs OCB inside Docker — no local Go toolchain needed)
docker build -t otelcol-security:0.1.0 .

# Push to your registry
docker tag otelcol-security:0.1.0 ghcr.io/YOUR_GITHUB_HANDLE/security-observability-stack/collector:0.1.0
docker push ghcr.io/YOUR_GITHUB_HANDLE/security-observability-stack/collector:0.1.0
```

> **Local testing shortcut** — if you are using kind or k3d you can load the
> image directly instead of pushing:
> ```bash
> kind load docker-image otelcol-security:0.1.0
> # or
> k3d image import otelcol-security:0.1.0 -c <cluster-name>
> ```

---

## Step 2 — Deploy the sample application

Both examples include ready-to-apply Kubernetes manifests. Pick one.

### Namespace mode (single tenant)

```bash
kubectl apply -f examples/namespace-mode/manifests/
```

This creates:
- `payments` namespace
- `payments-api` Deployment (nginx + metrics exporter sidecar)

### Cluster mode (multi-tenant + GPU workload)

```bash
kubectl apply -f examples/cluster-mode/manifests/
```

This creates:
- `payments`, `fraud-detection`, and `inference` namespaces
- Sample app in each namespace
- `llm-inference` Deployment in `inference` — scheduled on GPU nodes
  (requires nodes with `accelerator: nvidia-gpu` label and GPU capacity;
  skip or modify `03-inference-gpu.yaml` if your cluster has no GPU nodes)

---

## Step 3 — Install the Helm chart

### Namespace mode

```bash
helm install payments-obs helm/observability-stack \
  --namespace payments \
  -f examples/namespace-mode/values.yaml \
  --set collector.image.repository=ghcr.io/YOUR_GITHUB_HANDLE/security-observability-stack/collector \
  --set collector.image.tag=0.1.0 \
  --set collector.export.endpoint="<your-otlp-gateway>:4317"
```

### Cluster mode

```bash
kubectl create namespace observability

helm install platform-obs helm/observability-stack \
  --namespace observability \
  -f examples/cluster-mode/values.yaml \
  --set collector.image.repository=ghcr.io/YOUR_GITHUB_HANDLE/security-observability-stack/collector \
  --set collector.image.tag=0.1.0 \
  --set collector.export.endpoint="<your-otlp-gateway>:4317"
```

---

## Step 4 — Verify the deployment

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

## Step 5 — Configure a real export endpoint

The examples default to `otel-gateway:4317` which only works if you have an
OTLP gateway running inside the cluster. For a real backend:

| Backend | Endpoint | Notes |
|---|---|---|
| Grafana Cloud | `otlp-gateway-prod-xx.grafana.net:443` | Requires `Authorization` header — add via `collector.export.headers` |
| Jaeger | `jaeger-collector:4317` | In-cluster Jaeger deployment |
| Prometheus + Tempo | Grafana Agent OTLP endpoint | Agent translates OTLP → remote write |
| OpenTelemetry Collector (gateway) | `otel-gateway:4317` | Deploy a separate gateway collector |

Enable TLS for production:

```yaml
# In your values override
collector:
  export:
    endpoint: "otlp-gateway-prod-xx.grafana.net:443"
    tls:
      insecure: false
```

---

## Troubleshooting

### Collector pod is in `CrashLoopBackOff`

```bash
kubectl describe pod -n payments -l app.kubernetes.io/component=collector
kubectl logs -n payments -l app.kubernetes.io/component=collector --previous
```

Common causes:

| Symptom in logs | Cause | Fix |
|---|---|---|
| `unknown component type "k8sapilog"` | Image is upstream contrib, not the custom OCB build | Rebuild and push the custom image; update `collector.image` |
| `failed to build kube client config` | Not running in-cluster (local test without kubeconfig) | Set `api_config.in_cluster: false` and provide `kubeconfig_path` |
| `ensure the ServiceAccount has RBAC permission` | Role or RoleBinding not created | Run `helm status` to confirm chart installed; check `kubectl get role -n payments` |
| `connection refused` on export endpoint | OTLP gateway unreachable | Check endpoint address; verify `tls.insecure` matches gateway config |

### No logs arriving at the backend

1. Confirm pods exist in the watched namespaces:
   ```bash
   kubectl get pods -n payments
   ```
2. Check the collector accepted log records:
   ```bash
   curl -s http://localhost:8888/metrics | grep otelcol_receiver_accepted_log_records
   ```
3. Check the exporter sent them (non-zero means data reached the pipeline):
   ```bash
   curl -s http://localhost:8888/metrics | grep otelcol_exporter_sent_log_records
   ```
4. If accepted > 0 but sent = 0, the issue is between the collector and the backend — check TLS config and endpoint reachability.

### `helm install` fails with `forbidden`

Namespace mode requires only namespace-admin rights in the target namespace.
Cluster mode requires `cluster-admin`. Verify your kubeconfig context:

```bash
kubectl auth can-i create clusterrole --all-namespaces   # cluster mode
kubectl auth can-i create role -n payments               # namespace mode
```

---

## Next steps

- Read [`docs/architecture.md`](architecture.md) for a full diagram of the signal pipeline and deployment modes
- Read [`docs/compliance-mapping.md`](compliance-mapping.md) for SOC 2 control coverage
- See the [Roadmap](../README.md#roadmap) for planned features (rich filtering, HA load balancing)
