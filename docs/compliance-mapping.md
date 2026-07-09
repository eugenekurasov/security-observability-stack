# Compliance Mapping

Control-by-control mapping of the security-observability-stack to SOC 2
Trust Services Criteria. Intended as a starting point for audits — not a
substitute for a formal assessment.

**Status legend**

| Symbol | Meaning |
|---|---|
| ✅ | Addressed by the stack |
| ⚠️ | Partially addressed — gap documented |
| ❌ | Out of scope — must be addressed elsewhere |

---

## SOC 2 (Trust Services Criteria)

SOC 2 is organised around five Trust Services Categories. The ones most
relevant to an observability stack are **Security (CC)** and **Availability (A)**.

### Architectural note — what standard collectors cannot provide

Several controls below are only achievable because of the
**namespace-scoped, API-server-based architecture** of this stack. A
conventional node-level DaemonSet collector (which reads log files from the
host filesystem) cannot enforce per-tenant access boundaries: it reads every
pod on the node regardless of namespace, making structural tenant isolation
impossible at the collection layer.

The table column **"Requires this architecture"** marks controls where
deploying a standard contrib collector (e.g. `filelogreceiver` on a DaemonSet)
would leave the control unaddressed or require compensating controls outside
the collector itself.

---

### CC6 — Logical and Physical Access Controls

| Control | Description | Status | How the stack addresses it | Requires this architecture |
|---|---|---|---|---|
| CC6.1 | Logical access is restricted to authorised users | ✅ | Namespace-mode RBAC grants `pods/log` and `events` access only to the tenant's own ServiceAccount. No cross-tenant visibility by construction — not a filter rule, a structural boundary. | **Yes** — a node-level DaemonSet reads all pods on the node; namespace isolation is not enforceable at the collector level without the API-server approach. |
| CC6.2 | Authentication is required before granting access | ✅ | The collector authenticates to the Kubernetes API using a pod-mounted ServiceAccount token — standard k8s workload identity, short-lived and auto-rotated by the kubelet. | No — any collector using `serviceAccount` auth mode achieves this. |
| CC6.3 | Access is revoked promptly when no longer required | ✅ | Revoking access is a single `helm uninstall` — removes the Role, RoleBinding, and ServiceAccount atomically. No residual permissions, no filter rules to update. | **Yes** — with a DaemonSet collector, tenant separation relies on shared filter configuration; removing one tenant requires updating and redeploying that shared component, rather than deleting an isolated per-tenant resource. |
| CC6.6 | Security events are logged | ✅ | Kubernetes Events (OOMKills, scheduling failures, quota violations, RBAC deny events) are collected by `k8seventsreceiver` and forwarded to the backend. | No — `k8seventsreceiver` is a standard contrib component usable with any deployment model. |
| CC6.7 | Transmission of data is encrypted | ⚠️ | OTLP export supports TLS (`collector.export.tls.insecure: false`). Default in examples is `insecure: true` for local dev — **must be set to false in production**. In-cluster traffic (pod → API server) uses TLS managed by Kubernetes. | No — standard OTel exporter feature available in any collector. |

### CC7 — System Operations

| Control | Description | Status | How the stack addresses it | Requires this architecture |
|---|---|---|---|---|
| CC7.1 | System components are monitored | ✅ | `signals.selfMonitoring` exposes collector heap, pipeline throughput, and drop counts at port 8888. Scraped automatically when `signals.metrics.enabled: true`. | No — standard OTel `service.telemetry` feature. |
| CC7.2 | Anomalies and security incidents are detected | ⚠️ | Kubernetes Events cover pod-level anomalies (OOMKills, CrashLoopBackOff, image pull failures). Application-level anomaly detection depends on what the tenant instruments — not provided by this stack. | No — `k8seventsreceiver` is a standard contrib component. |
| CC7.3 | Detected incidents are evaluated and responded to | ❌ | Alerting and incident response are backend concerns (Grafana alerting, PagerDuty, etc.) — outside the scope of the collection layer. | — |
| CC7.4 | Incidents are contained | ❌ | Out of scope. | — |

### A1 — Availability

| Control | Description | Status | How the stack addresses it | Requires this architecture |
|---|---|---|---|---|
| A1.1 | System availability is monitored | ✅ | Self-monitoring metrics (`k8s_cluster` receiver) expose pod restarts, deployment availability, and resource saturation. | No — standard contrib components. |
| A1.2 | Environmental threats are identified | ⚠️ | Node-level threats (disk pressure, memory pressure) visible in cluster mode via `node_conditions_to_report`. Not available in namespace mode (requires cluster-scoped access). | No — standard `k8sclusterreceiver` feature. |

---

## Known gaps

These items are relevant to a full compliance posture but are outside the
scope of the observability collection layer:

| Gap | Where it belongs |
|---|---|
| Log retention and deletion policy | OTLP backend / object storage configuration |
| Alerting on audit trail gaps | Backend alerting rules (Grafana, etc.) |
| Encryption at rest | Backend storage (object store, time-series DB) |
| Access review process | Organisational process + Kubernetes RBAC audit |
| Incident response playbooks | Organisational process |
| Node-level audit logs (kubelet, containerd) | Separate privileged DaemonSet, operator-managed |
| Control plane audit logs (kube-apiserver) | Cloud provider audit log sink (CloudTrail, Cloud Audit Logs) |

---

## Planned

- Extend with CIS Kubernetes Benchmark controls once Terraform modules
  (cloud RBAC, network policies) are in place.
