# CISA Logging Reference Architecture - design rationale

A reading of this stack against the [CISA Logging Reference Architecture
(LRA)](https://www.cisa.gov/resources-tools/resources/logging-reference-architecture),
published August 2026 under OMB Memorandum
[M-26-14](https://www.whitehouse.gov/wp-content/uploads/2026/05/m-26-14-ensuring-effective-and-efficient-agency-logging-and-network-visibility-to-defend-against-evolving-cyber-threats.pdf).

**This is not a compliance claim.** The LRA is written for Federal Civilian
Executive Branch agencies building an enterprise logging capability; this
repository is one open-source component such a capability might contain.
Nothing here has been reviewed by CISA. It is included because the LRA is an
unusually concrete rubric for a log collector, and because measuring against it
shows the stack's real limits more clearly than a feature list does.

Section numbers refer to the LRA. This reading is against the August 2026
edition; M-26-14 requires the LRA to be re-evaluated at least annually, so this
document needs revisiting whenever the LRA changes.

---

## At a glance

**What this stack is, in LRA terms:** one collector among several. It collects
workload logs, Kubernetes Events and cluster state through the Kubernetes API,
without node privilege, and forwards them over OTLP. An LRA-aligned capability
also needs the sources marked ❌ below from other tools, and a backend for
storage, normalization and alerting.

| | Signal | Details |
|---|---|---|
| ✅ | Container stdout and stderr from any pod, serverless nodes included | [Workloads](#workloads-and-in-cluster-security-tools-transported-not-produced) |
| ✅ | Alerts from in-cluster security tools that write to stdout or Events, such as Falco or Gatekeeper | [Workloads](#workloads-and-in-cluster-security-tools-transported-not-produced) |
| ⚠️ | Kubernetes Events and resource state: what happened, not who caused it, and a gap at every collector restart | [Cluster state and events](#cluster-state-and-events-the-layer-this-stack-delivers) |
| ❌ | kube-apiserver audit log: who called the API | [Control plane](#control-plane-the-highest-value-layer-out-of-reach) |
| ❌ | Node OS, kubelet and container runtime logs | [Nodes](#nodes-given-up-by-design) |
| ❌ | Network flows, DNS, east-west traffic | [Network](#network-structural) |
| ❌ | Retention, normalization, hashing, alerting | [Out of scope](#out-of-scope-entirely) |

**What you can do for the strongest alignment:**

1. **Export every release to one agency gateway.** Per-tenant collection
   counts as federated collection only if it converges. See [Namespace
   mode](#namespace-mode-federated-collection-on-one-condition).
2. **Have the platform team install the collectors.** One namespace-mode
   release per tenant, in a platform-owned namespace, keeps tenant isolation
   and separation of duties. See [Who installs the
   collector](#who-installs-the-collector-matters-as-much-as-the-mode).
3. **In cluster mode, weigh `signals.metrics` against `nodes/proxy`.** While
   metrics are on, the ClusterRole grants `nodes/proxy`, which allows command
   execution in every pod. Turning metrics off removes it, along with that
   release's Prometheus scraping and cluster-state metrics. See [Cluster
   mode](#cluster-mode-the-lras-natural-subject).
4. **Encrypt the first hop.** The default export is plaintext, which fails
   maturity Level 3. Run a service mesh with mTLS, or set
   `collector.export.tls.insecure: false`. The chart cannot mount a private CA
   yet, so the second option works only with a certificate the collector
   already trusts. See [Log management
   maturity](#log-management-maturity-the-chart-default-fails-level-3).
5. **Put log cursors on a PVC.** With
   `signals.logs.cursorStorage.volume.type: persistentVolumeClaim`, collection
   resumes where it stopped after a rollout, eviction or drain. See [Delivery
   assurance](#delivery-assurance-logs-checkpointed-events-not).
6. **Redact at the gateway.** The collector forwards lines verbatim, so mask
   sensitive data in a gateway inside your boundary, built with a redaction or
   transform processor. See [Sensitive data
   protection](#sensitive-data-protection).
7. **Alert on the collector's own metrics.** Export failures, stream
   connection errors and active stream counts are your evidence of transport
   health and coverage. See [How the stack collects](#how-the-stack-collects).
8. **Collect audit, node and network logs with other tools,** into the same
   backend. See [Out of scope entirely](#out-of-scope-entirely).

The rest of this document is the detailed reading, section by section of the
LRA, for anyone assessing the stack.

## Contents

- [At a glance](#at-a-glance) — what the stack covers and what to configure
- [The LRA is a platform-monitoring framework](#the-lra-is-a-platform-monitoring-framework) — why this reading is organised by layer
- [Cluster level and tenant level](#cluster-level-and-tenant-level) — which mode to deploy, and who should install it
  - [Cluster mode: the LRA's natural subject](#cluster-mode-the-lras-natural-subject)
  - [Namespace mode: federated collection, on one condition](#namespace-mode-federated-collection-on-one-condition)
  - [Who installs the collector matters as much as the mode](#who-installs-the-collector-matters-as-much-as-the-mode)
  - [Verdicts that change with the mode](#verdicts-that-change-with-the-mode)
- [Kubernetes platform, layer by layer](#kubernetes-platform-layer-by-layer) — each layer, what the stack reaches, and why
  - [Control plane: the highest-value layer, out of reach](#control-plane-the-highest-value-layer-out-of-reach)
  - [Cluster state and events: the layer this stack delivers](#cluster-state-and-events-the-layer-this-stack-delivers)
  - [Nodes: given up by design](#nodes-given-up-by-design)
  - [Network: structural](#network-structural)
  - [Workloads and in-cluster security tools: transported, not produced](#workloads-and-in-cluster-security-tools-transported-not-produced)
  - [Images and supply chain](#images-and-supply-chain)
- [Baseline activity coverage](#baseline-activity-coverage) — M-26-14's baseline activities, one by one
- [How the stack collects](#how-the-stack-collects) — collection, transport and protection mechanics
- [Delivery assurance: logs checkpointed, Events not](#delivery-assurance-logs-checkpointed-events-not) — what survives a restart and what is lost
- [Requirements that land on the collector](#requirements-that-land-on-the-collector) — sensitive data, encryption, coverage
  - [Sensitive data protection](#sensitive-data-protection)
  - [Log management maturity: the chart default fails Level 3](#log-management-maturity-the-chart-default-fails-level-3)
  - [Measuring coverage against inventory](#measuring-coverage-against-inventory)
- [M-26-14 requirements, row by row](#m-26-14-requirements-row-by-row) — every Table A-1 row with a verdict
- [Out of scope entirely](#out-of-scope-entirely) — what to get from other tools or the backend

---

## The LRA is a platform-monitoring framework

Read the LRA's baseline categories (§6.2) and what they describe is the
platform: identity and authentication, network activity, endpoint and system
activity, privileged and administrative actions, cloud and SaaS control-plane
activity, security tool output. Applications appear in two places only — as the
"Application Level" rows of the Table A-2 crosswalk, and as the possible
*content* of §6.2.3 object and data activity, if an application chooses to log
it.

So the question this document answers is framed by layer: **which layers of
Kubernetes platform monitoring does this stack deliver, and which can it not
reach?** Application logs are one of those layers, and they map to the LRA
through the Application Level rows and §6.2.3.

The short answer: it delivers the **cluster-state layer** — Kubernetes Events
and resource state — and **transports** whatever workloads and in-cluster
security tools print. The layers the LRA weights most heavily for a Kubernetes
platform — the control plane's audit trail, the nodes, the network — are out of
its reach, some by design and some structurally.

The stack also has two deployment modes, and the LRA places them differently.
Cluster mode is a platform operator's collector. Namespace mode is one tenant's
feed into a federated capability. [Cluster level and tenant
level](#cluster-level-and-tenant-level) sets out where each sits and which
verdicts in this document change with the mode. The layer analysis after it is
a cluster-mode reading.

---

## Cluster level and tenant level

The LRA never says "tenant" and never mentions deployment modes. It does
describe the situation. Its intended audience includes "platform operators"
(§2.1), and its first recommended use case is "to build or redesign an
enterprise, federated, or shared logging architecture" (§2.2). This chart's two
modes are two positions in that kind of architecture.

| | Cluster mode | Namespace mode |
|---|---|---|
| **Installed by** | Platform or SRE team, with cluster-admin | A tenant with admin rights in its own namespaces, or the platform team on the tenant's behalf |
| **Collects from** | Every namespace, `kube-system` included; node conditions; kubelet and cAdvisor metrics by default | Only the namespaces in `namespaces`; nothing cluster-scoped |
| **LRA role** | The platform operator's collector for a Kubernetes platform | One source-appropriate feed into the agency's enterprise capability (§5.1) |
| **LRA sections that do the work** | §6.2 categories and the Table A-2 container rows: the [layer analysis](#kubernetes-platform-layer-by-layer) below | Table A-2 *Application Level* rows, §6.2.3, the §5.4.5 segregated-access overlay, and §8.1 |
| **What it is not** | The platform's whole logging pipeline. Control plane, nodes and network stay out of reach | A logging capability. The LRA assesses the agency's capability, not one team's feed |

### Cluster mode: the LRA's natural subject

A platform team running one collector across the cluster is what the LRA means
by a platform operator collecting from an agency system. Only cluster mode
collects across all namespaces, sees Events in `kube-system`, and reports node
conditions (`Ready`, `MemoryPressure`, `DiskPressure`) and allocatable
resources. Namespace mode reaches none of the cluster-scoped part of the
[cluster-state layer](#cluster-state-and-events-the-layer-this-stack-delivers).

**Its default RBAC is broader than the rest of this document assumes.** With
`signals.metrics` enabled, which is the default, the ClusterRole grants `get`,
`list` and `watch` on `nodes/proxy` for every node. The chart uses it to scrape
kubelet and cAdvisor metrics through the API server proxy, and grants it even
when `scrapeNodes: false`. The Kubernetes [RBAC good
practices](https://kubernetes.io/docs/concepts/security/rbac-good-practices/#access-to-proxy-subresource-of-nodes)
guide says access to `nodes/proxy` "allows for command execution on every pod on
the node(s) to which they have rights", that it "bypasses audit logging and
admission control", and that `get` on it "is not a read-only permission." A
compromised cluster-mode collector can therefore run commands in any pod in the
cluster, outside the audit trail. That is node-level trust reached through the
API instead of `hostPath`. It also cuts against §8.1's "logging and monitoring
of privileged activity affecting the logging infrastructure": the collector
holds a privilege whose use the cluster's audit log does not record.

Until the chart narrows this grant, the [least-privilege
verdict](#how-the-stack-collects) holds for namespace mode, and for cluster
mode only with `signals.metrics.enabled: false`. Scraping the kubelet directly
on port 10250 needs only `nodes/metrics`, at the cost of network reachability
from the collector to every node.

### Namespace mode: federated collection, on one condition

§5.1 calls "source-appropriate collection with common downstream handling" the
strongest default for a maturing agency: telemetry collected "using methods
appropriate for the source and environment," then moved into shared
processing. §5.3 adds that a central design that "creates a fragile chokepoint
is weaker than a more federated design with strong common governance and shared
operational handling." One release per tenant is that federated design, and its
failure domain is one tenant rather than the cluster (Appendix E.10.4).

The condition is convergence. M-26-14 requires required logs to be readily
available to the top-level SOC "even when storage is decentralized or
federated" (App. B Req. 2), and §5.1 warns against "letting every source evolve
its own isolated ingestion path, schema handling, and routing logic." Every
release sets its own `collector.export.endpoint`. Unless all of them point at
the same agency gateway, namespace mode is the isolated-ingestion pattern the
LRA warns against. Nothing in the chart checks this.

### Who installs the collector matters as much as the mode

§8.1 asks for "separation of duties where practical" and "protections against
unauthorized change, deletion, or silent bypass." A tenant self-install meets
neither, by construction. The team whose workloads are monitored owns the
collector. It can uninstall the release, narrow `podLabelSelector`, or repoint
the exporter, and each of those is a Helm upgrade in its own namespace. That is
the right model for a team's own operational observability. As the agency's
security logging for that tenant, it is the monitored party controlling its own
monitoring.

The same chart closes most of the gap when the platform team installs it. A
namespace-mode release in a platform-owned namespace, with `namespaces` set to
the tenant's namespaces, keeps the RBAC boundary and moves control of the
collector to the platform. One residue remains: the Role and RoleBinding live in
the tenant's namespace, and Kubernetes' default `admin` role lets a namespace
admin delete them. Collection then fails with authorization errors rather than
silently, which helps only if something alerts on the collector's errors.

### Verdicts that change with the mode

Where a verdict elsewhere in this document depends on the mode, this table is
the reference.

| LRA expectation | Cluster mode | Namespace mode, tenant-installed | Namespace mode, platform-installed |
|---|---|---|---|
| §8.1 Least privilege | ❌ at defaults: `nodes/proxy` cluster-wide. ✅ with `signals.metrics` off | ✅ `pods/log`, Events and workload objects in the tenant's namespaces only | ✅ Same |
| §8.1 Segmentation | ❌ at collection. One collector reads every tenant, so segmentation has to be a §5.4.5 overlay downstream | ✅ Other tenants' logs are unreachable, not filtered | ✅ Same |
| §8.1 Separation of duties | ✅ The platform operates the collector | ❌ The monitored team operates its own monitoring | ✅ The platform operates it, with the RoleBinding residue above |
| §8.1 Silent bypass | ⚠️ `podLabelSelector` and the export endpoint, in the platform's hands | ❌ All of them, and the release itself, in the tenant's hands | ⚠️ As cluster mode, plus RoleBinding deletion by the tenant |
| App. B Req. 2 Top-level SOC availability | ⚠️ One endpoint, set by the platform | ❌ unless enforced: each tenant picks its endpoint | ⚠️ The platform sets every endpoint |
| App. B Req. 4 Coverage | ⚠️ Measurable: one collector sees every container | ❌ A namespace with no release is invisible to every collector and to the measurement | ⚠️ As tenant-installed, unless the platform measures against a cluster-level inventory |
| App. A Sensitive data protection | ❌ Every container's stdout by default | ⚠️ Scope-level minimization by Role; no content-level control | ⚠️ Same |
| App. E.10.4 Single-point fragility | ❌ One logs collector for the whole cluster | ✅ One tenant per collector | ✅ Same |
| Cluster-state layer | ⚠️ All namespaces, `kube-system`, node conditions | ⚠️ Tenant namespaces only. No node conditions, no `kube-system` Events | ⚠️ Same as tenant-installed |

**The strongest position against the LRA is the platform-installed column.**
One namespace-mode release per tenant, installed by the platform team and
exporting to one agency gateway, gets segmentation at collection, separation of
duties, a one-tenant failure domain, and federated collection under common
handling, without `nodes/proxy`. It cannot see a namespace nobody installed a
release for, and it collects no cluster-scoped state. A cluster-mode release
with only `signals.events` enabled adds cluster-wide Events, `kube-system`
included, without `nodes/proxy`; the per-tenant releases then turn
`signals.events` off so Events are not collected twice. Node conditions need
`signals.metrics`, and with it, today, `nodes/proxy`.

Tenant self-install remains the right model for a team's own observability. It
is not the agency's security logging for that tenant unless the platform
collects as well.

---

## Kubernetes platform, layer by layer

| Layer | LRA categories | Table A-2 row | Operated by (managed K8s) | This stack | Limit |
|---|---|---|---|---|---|
| [Control plane and API audit](#control-plane-the-highest-value-layer-out-of-reach) | 6.2.1, 6.2.4, 6.2.7 | Container Cluster/Pod Events (identity half) | Provider | ❌ | Structural |
| [Cluster state and events](#cluster-state-and-events-the-layer-this-stack-delivers) | 6.2.1–6.2.4, 6.2.7, 6.2.8 | Container Cluster/Pod Events (operational half) | Provider API, agency objects | ⚠️ delivered, weakly | Delivery |
| [Nodes: OS, kubelet, runtime](#nodes-given-up-by-design) | 6.2.5 | Container OS, Container Engine | Agency (standard) / provider (serverless) | ❌ | By design |
| [Network: CNI, flows, DNS](#network-structural) | 6.2.2 | — | Agency / provider | ❌ | Structural |
| [In-cluster security tools](#workloads-and-in-cluster-security-tools-transported-not-produced) | 6.2.6 | — | Agency | ⚠️ transported | Tool-dependent |
| [Workloads: container stdout](#workloads-and-in-cluster-security-tools-transported-not-produced) | 6.2.1, 6.2.3, 6.2.4, 6.2.6 | Application Level | Agency | ⚠️ transported | App-dependent |
| [Images and supply chain](#images-and-supply-chain) | 6.2.3, 6.2.7 | Container – Image, Container Supply Chain | Agency / registry | ❌ | Out of scope |

**Limit** is the column to read before judging the ❌s. *Structural* means no
collector running inside the cluster under Kubernetes RBAC could do better: on
managed Kubernetes the data is not behind the Kubernetes API at all. *By design*
means this project gave it up deliberately. The difference matters — a
different in-cluster collector would not close a structural gap; a different
design choice would close a by-design one, at a cost.

### Control plane: the highest-value layer, out of reach

The kube-apiserver audit log records who called the Kubernetes API, from where,
and with what result. In LRA terms it is the single highest-value Kubernetes
source: it is what §6.2.1 identity, §6.2.4 privileged activity, and §6.2.7
cloud administrative activity — "core enterprise telemetry rather than… a
specialized add-on" — mean for a cluster. The LRA's own crosswalk maps
*Container Cluster/Pod Events* to those same three categories.

On cloud-hosted EKS, GKE, and AKS the control plane does not run as pods in the
cluster, so there is nothing for `pods/log` to stream: `k8spodlogreceiver`
cannot reach control plane logs there by any configuration. What does appear in
`kube-system` — `coredns`, `kube-proxy`, `konnectivity-agent`, CNI and CSI
pods — are node components and add-ons, and the `kubernetes` Service in
`default` has no pods behind it at all. The logs live with the provider:

| | Destination | Default |
|---|---|---|
| **EKS** | CloudWatch Logs, `/aws/eks/<cluster>/cluster` — log types `api`, `audit`, `authenticator`, `controllerManager`, `scheduler` | **Off.** Enabled per log type |
| **GKE** | Cloud Audit Logs and Cloud Logging | Admin Activity audit logs **always on** and cannot be disabled. Data Access audit logs and control plane component logs off |
| **AKS** | Diagnostic settings to Log Analytics, Storage, or Event Hubs | Off |

M-26-14 still puts them in scope: CEM and THIRF apply to "agency-owned,
agency-operated, and third-party operated systems" (Table A-1, *Scope of
Systems*), and §1.3.1 says agencies "must ensure logging, retention, and
visibility decisions also apply to these delegated or externally operated
systems." Access goes through cloud IAM — IRSA or EKS Pod Identity, GKE Workload
Identity, Azure managed identity — never Kubernetes RBAC. That is the real cost
of covering this layer from this design: the project's central premise is that
Kubernetes RBAC is the collector's only access boundary. Reaching the control
plane means a second identity in a second permission system, with a far wider
blast radius than `pods/log` on a namespace. An agency should collect these
logs; it is a deliberate call for this project not to do it in the same
collector.

**Self-managed clusters are a partial exception.** On kubeadm-style clusters —
including kind — and on EKS Anywhere or GKE on-prem, the API server, scheduler,
and controller manager run as static pods in `kube-system`, and their component
logs *are* behind `pods/log`; cluster mode collects them unless
`podLabelSelector` excludes them. The audit log is reachable only if the API
server is started with `--audit-log-path=-`, writing audit events to stdout.
That works, and it is a weak transport for an audit trail: stdout and stderr
arrive merged, so audit JSON is interleaved with klog output, and every caveat
in [Delivery assurance](#delivery-assurance-logs-checkpointed-events-not)
applies to the dataset §8.2 most expects to be integrity-protected. The API
server's webhook audit backend exists for this purpose.

### Cluster state and events: the layer this stack delivers

This is the stack's real platform contribution. `k8s_events` collects
Kubernetes Events — pod lifecycle, scheduling failures, OOMKills, image pull
errors, quota violations, failed mounts. `k8s_cluster` collects resource state —
pod, deployment, and job status, restart counts, and in cluster mode node
conditions and allocatable resources. These are produced by the control plane,
and their fidelity does not depend on how any application was written.

Two things keep it from a ✅.

**It is the operational half of the category only.** An Event names the
controller that reported it (`source.component`, `reportingController`) and the
object it concerns — never the principal who caused it. "Deployment scaled to
0" arrives; *who* scaled it does not. The identity half is in the audit log,
above.

**It is the stack's weakest-delivered signal:**

- The API server keeps an Event only for `--event-ttl`, one hour by default.
  Whatever no collector has read by then is gone at the source.
- `k8s_events` drops every Event timestamped before the receiver started. In
  the pinned v0.165.0 that start time is set once and never moved, and the
  receiver's optional `storage` setting does not relax it — it persists a
  resourceVersion to prevent *duplicates* on resume, as its own README says,
  not to recover the downtime window. Every collector restart is a permanent
  gap in Events.
- This chart configures no storage for `k8s_events` either.

Container logs, by contrast, resume from per-container cursors. The signal the
LRA would value most from this stack is the one it delivers least reliably — and
because the gap comes from upstream receiver design, no chart setting closes it.

### Nodes: given up by design

Node OS logs, kubelet, and the container runtime are what Table A-2 calls
*Container OS* and *Container Engine*, and what §6.2.5 means by endpoint and
system activity for a cluster: process lineage, command-line arguments,
parent-child relationships, file context (Appendix D.6.3).

This stack gives that layer up on purpose. Reading it needs `hostPath` or a
privileged DaemonSet — the node-level trust the project exists to avoid. That
is the central trade-off of the design, and the LRA prices both sides of it:
the decision that earns the strongest alignment in this document,
[§8.1](#how-the-stack-collects), is the same decision that forfeits §6.2.5.
Neither half should be quoted without the other. In cluster mode at chart
defaults the trade is lopsided: the collector gives up node logs and still
holds `nodes/proxy`. See [Cluster mode](#cluster-mode-the-lras-natural-subject).

On serverless node pools — Fargate, GKE Autopilot, AKS Virtual Nodes — the
node layer moves to the provider and the agency has no node access at all. What
the agency still operates there is the workload layer, and that is exactly where
a node-agent model cannot go: Fargate and AKS Virtual Nodes do not schedule
DaemonSets, and Autopilot restricts `hostPath` to read-only `/var/log`.
API-mediated collection reaches those pods unchanged. On these platforms this
stack covers the one layer that remains the agency's to collect, through a path
DaemonSet-based collectors do not have. The node layer, now third-party
operated, comes from the provider where the provider exposes it — under the
*Scope of Systems* row, as for the control plane.

### Network: structural

§6.2.2 wants source and destination, protocol, port, and session attributes,
and Appendix D.3.4 warns specifically about invisible east-west traffic. For a
cluster that means CNI flow logs, DNS, and service-mesh telemetry — node-level
capture (eBPF, CNI plugins) or cloud VPC flow logs. None of it is behind the
Kubernetes API. This is also the gap that matters most for zero trust:
workload-to-workload access decisions are network-layer facts.

### Workloads and in-cluster security tools: transported, not produced

`k8s_pod_log` moves whatever a container writes to stdout and stderr. For
ordinary workloads that maps to Table A-2's *Application Level* rows — and
whether the stream contains an authentication outcome, a privileged action, or
an object access is a property of the application, not the collector. The stack
can carry it faithfully; it cannot cause it to exist. §6.2 says the same in
general terms: a source "can technically be onboarded but still be operationally
weak when key fields are missing."

The same holds for **security tools running in the cluster**, which is the more
useful case for platform monitoring. Falco writes alerts to stdout by default;
admission controllers such as Gatekeeper can emit Kubernetes Events on denials.
The stack collects both, and that is genuine §6.2.6 coverage — but only for
tools deployed inside the cluster and configured to emit through one of those
two channels.

It holds for **AI workloads** too. §5.5 asks for user and system prompts, model
outputs, agent actions, model versions and lineage, and non-human identities.
Streaming an inference server's stdout delivers those only if the server writes
them. Live streaming does match the LRA's timing concern — records "recorded
before they expire or are recycled" — but a container that starts and exits
before its stream attaches is still missed.

### Images and supply chain

Image scanning, signature verification, and registry activity are outside the
cluster's runtime API and outside this stack.

---

## Baseline activity coverage

M-26-14 Appendix B Requirement 5 lists the activities baseline logging must
support (summarised in Table A-1). Against that list:

| Baseline activity | This stack | Limit | Why |
|---|---|---|---|
| Identity attribution | ❌ | Structural for Events; app-dependent for logs | Events carry no actor; container logs carry one only if the application writes it |
| Network attribution | ❌ | Structural | See [Network](#network-structural) |
| Object / resource / data activity | ❌ | App-dependent | Only if an application logs it |
| Privilege changes | ❌ | Structural | In the audit log — see [Control plane](#control-plane-the-highest-value-layer-out-of-reach) |
| Infrastructure changes | ⚠️ | Structural for the *who* | Effects are visible — a deployment scaled, a pod rescheduled, a node condition — but not who caused them |
| Security-tool visibility | ⚠️ | Tool-dependent | In-cluster tools emitting to stdout or Events, yes; anything else, no |
| IOC hunting | ⚠️ | App-dependent | To the extent workload logs contain indicators — client IPs in an access log, say |
| Anomaly detection | ⚠️ | — | Operational anomalies — OOMKills, crash loops, restart counts, node pressure — yes. Security anomalies, no |
| Impact assessment | ⚠️ | — | Which pods and nodes were affected, yes. Which data, no |
| Attack-vector determination | ❌ | Structural | Needs the identity and network data above |

None fully, five partially, five not at all — and three of those five are
structural. The partial ones share a reason: Kubernetes Events and container
logs describe *what happened to workloads*, while the LRA's baseline is mostly
about *who did what, from where, to which data*.

---

## How the stack collects

The layer analysis above is about *what* the stack collects. This section is
about *how*: the collection, transport, and protection mechanics the LRA sets
out in §4.2, §4.3, §7, and §8. Each row is
tagged with where the control lands: **Collector** (this repository can satisfy
or fail it), **Backend** (the OTLP destination), or **Org** (organisational
process).

| LRA expectation | Lands | Assessment |
|---|---|---|
| §4.2 Collect "as close to the authoritative source as practical" | Collector | ✅ `pods/log` is the kubelet's own read path, the one `kubectl logs` uses, and Events come from the API server directly. Note that a DaemonSet reading `/var/log/pods/` is equally authoritative; authoritativeness is not what separates the two designs — privilege is |
| §4.2 Provenance: "the originating system or service, the event time, the collection path" | Collector | ⚠️ The receiver stamps `k8s.namespace.name`, `k8s.pod.name`, `k8s.pod.uid`, `k8s.container.name`, `k8s.node.name`, and `k8s.container.restart_count` on the Resource, and the instrumentation scope carries the receiver's module path — a weak collection-path marker. Nothing records *which collector instance* read the record, which is the provenance question in a federated install. The chart's `tenantId` does not answer it: it is a `compliance.io/tenant` label on the chart's Kubernetes objects, not an attribute on records |
| §4.2 "Any meaningful transformation or enrichment" | Collector | ✅ None to record. No enrichment processor runs; lines are forwarded byte-for-byte, one record per line. The one transformation is documented: a line over `maxLogSize` is split (default) or truncated, never silently dropped |
| §4.3 Prefer event-driven delivery over polling | Collector | ✅ Logs are a live stream per container and Events arrive over a watch. Figure 2 names event-driven delivery's best fit as identity events, cloud control-plane activity, security alerts, and endpoint detections — of those, only in-cluster security alerts pass through this stack. Metrics are Prometheus-scraped, which is polling by design |
| §4.3 Encryption in transit | Collector | ❌ at chart defaults. See [Log management maturity](#log-management-maturity-the-chart-default-fails-level-3) |
| §4.3 Durable handoff, buffering, checkpointing, replay, back pressure | Collector | ⚠️ `memory_limiter` applies back pressure before anything buffers. Log cursors are checkpointed to `file_storage`, durable across pod replacement only on a PVC — see [Delivery assurance](#delivery-assurance-logs-checkpointed-events-not). The exporter runs OTel defaults — in-memory sending queue and retry — since the chart sets no `sending_queue`, `retry_on_failure`, or storage extension; nothing on that side survives a pod restart, and there is no replay |
| §4.3 Monitoring of transport health | Collector | ✅ `service.telemetry` exposes `otelcol_exporter_sent_*`, `otelcol_exporter_send_failed_*`, and `otelcol_exporter_queue_size` on port 8888; the receiver adds `active_log_streams`, `log_connection_errors_total`, and `log_connection_reconnects_total` |
| §8.3 "Overreliance on direct point-to-point integrations" | Collector | ⚠️ The chart exports to exactly one OTLP endpoint — point-to-point by construction. The examples point it at a gateway rather than a final backend, but the chart neither enforces nor checks that |
| §7.4 Avoid "becoming operationally dependent on proprietary structures that make it difficult to export, validate, or reinterpret security-relevant data"; §8.3 avoid "vendor-dependent handling that leaves essential telemetry outside agency control" | Collector | ✅ at the collection layer. Output is OTLP, the open wire protocol of the CNCF OpenTelemetry project, and every component in the pipeline is upstream OpenTelemetry or open source under Apache 2.0 — the receiver included, pinned in `builder-config.yaml` and rebuildable from source. There is no vendor agent and no proprietary format: the destination is any OTLP-capable backend, and changing it is an exporter setting, not a re-collection. Backends that need authentication headers go through a gateway, since the chart's exporter sets only an endpoint and TLS. Attribute keys follow the OTel semantic conventions and carry a `SchemaUrl`. §7.4 also asks for a durable *normalized* record that exports without losing meaning, and for lawful production of logs on request — those land on the backend and the organisation |
| §8.1 Least privilege for service accounts | Collector | ✅ in namespace mode; ❌ in cluster mode at defaults. Collection is authorised by Kubernetes RBAC on `pods/log`: no `hostPath`, no host namespace, no node root. In namespace mode the chart grants only what the enabled signals need, and a compromised collector reads what its Role allows and nothing else on the node. In cluster mode with `signals.metrics` enabled, the ClusterRole also grants `nodes/proxy`, which is command execution in every pod; see [Cluster mode](#cluster-mode-the-lras-natural-subject). The namespace-mode posture is the strongest alignment in the document — and it is an alignment of the collector's own posture, which §8.1 asks of every component regardless of the value of the data passing through. It is also the decision that [gives up the node layer](#nodes-given-up-by-design) |
| §8.1 Segmentation appropriate to sensitivity | Collector | ✅ in namespace mode; ❌ at collection in cluster mode. In namespace mode the boundary is a Role in the tenant's namespace; other tenants' logs are unreachable, not filtered. §5.4.5 describes this segregated-access pattern as a layer over storage and analytics; here it is applied one layer earlier, at collection — at the cost the LRA names, more governance overhead: one release per tenant. A cluster-mode collector reads every tenant, so there the overlay has to be built downstream |
| §8.1 Separation of duties "where practical" | Org / Collector | ⚠️ Depends on who installs. Cluster mode, and namespace mode installed by the platform team, keep the collector out of the monitored team's hands. A tenant self-install is the monitored team operating its own monitoring; see [Who installs the collector](#who-installs-the-collector-matters-as-much-as-the-mode) |
| §8.1 Protection against "silent bypass" | Collector / Backend | ⚠️ The collector holds no durable state to tamper with. But `podLabelSelector` can quietly exclude a source with no audit trail beyond the Helm values. In a tenant self-install the tenant holds that setting, the export endpoint, and the release itself |
| §8.1 Administrative access control, monitoring of privileged changes to the logging infrastructure | Org / Backend | ❌ Who may change the Helm release is a cluster RBAC question; changes to it are audit-log events, which this stack does not collect |
| §6.3 Reliable timestamp | Collector / Org | ⚠️ Every record carries `Timestamp`, the line's time from the container runtime (falling back to receipt time if absent), and `ObservedTimestamp`, when the collector read it — so collection lag is visible per record. NTP synchronisation to a traceable source, and documenting how it is monitored, is node and organisational configuration |
| §6.3 Identity or system context, affected resource | Collector | ✅ for *system* context: which workload emitted the line, set from the pod object rather than inferred. Not identity in the actor sense — `pods/log` carries no principal |
| §6.3 Event type, outcome | Backend | ❌ A raw log line has neither until something parses it |
| §7.1 Durable normalized representation | Backend | ❌ Not produced here. No OCSF, no ECS, no field extraction. Forwarding raw and normalizing downstream is a legitimate answer to §8.3's warning against "normalization that discards investigative context," but only if the downstream stage exists |
| §7.2 Recoverable source-native context | Collector | ✅ What is forwarded *is* the source-native record |
| §7.3 Schema handoff | Collector / Backend | ⚠️ Attribute keys come from the OTel semantic conventions, and each batch carries the matching `SchemaUrl`, so a downstream schema processor can translate across convention versions. Governing the mappings is the backend's job |

---

## Delivery assurance: logs checkpointed, Events not

§4.2:

> "Collection design should address interruption considerations, including
> buffering, persistent restart, retry mechanisms, and verification of
> successful delivery — these are fundamental operational requirements rather
> than optional features… If an outage or pipeline failure can silently drop
> important data, then the logging capability is not sufficiently reliable for
> mature incident operations."

**For logs, the receiver answers this well.** Each container stream tracks the
timestamp of the last line delivered and resumes from it on reconnect, rather
than re-reading `since_seconds`. The cursor is keyed by namespace, pod name, pod
UID, and container name, and advances as each batch is *accepted by the
pipeline*, not when the connection ends. Given a storage extension, positions
survive a collector restart, flushed every 30 seconds and on shutdown. `SinceTime`
is truncated to whole seconds, so a resume re-delivers a line or two rather than
risking a skip — *"duplicates are recoverable downstream, gaps are not,"* which
is §4.2's own posture. Storage failures are non-fatal and fall back to
`since_seconds`.

**The chart turns it on, and the volume decides how far it reaches.**
`signals.logs.cursorStorage` is enabled by default: it sets `storage:
file_storage` on `k8s_pod_log` and mounts a volume for the extension. In-memory
cursors already cover reconnects and broken watches (API server rollouts,
idle-timeout reaps). The volume adds the restart cases:

- **`emptyDir` (default).** Survives a container restart in the same pod:
  OOMKill, liveness failure, crash. A rollout, eviction or node drain creates a
  new pod with an empty volume, so it falls back to `since_seconds` (300s).
- **`persistentVolumeClaim`.** Also survives pod replacement. file_storage
  holds an exclusive lock on its file, so the chart switches the Deployment to
  `Recreate` and refuses `replicas > 1`. The cost is a short collection pause
  on every rollout, which the resumed cursor then backfills.

An install that needs §4.2's "persistent restart" end to end should use the
PVC.

**For Events, nothing equivalent exists** — see
[Cluster state and events](#cluster-state-and-events-the-layer-this-stack-delivers).

Residual limits inherent to API-mediated collection, which no checkpoint closes:

- **Log rotation.** A stream down longer than the kubelet's log retention loses
  those lines at the source. Bound it with aggressive `reconnectBackoff` and
  generous kubelet `containerLogMaxFiles` / `containerLogMaxSize`.
- **Previous container instance.** After a container restart only the new
  instance is streamed; what the crashed instance wrote before the stream
  attached is not backfilled, though `kubectl logs --previous` could still show
  it. For crash-loop forensics (§3.4) that is the window an investigator wants.
- **Single replica.** Stream ownership is in-process; two replicas duplicate
  every record. Appendix E.10.4 asks whether one component's failure causes
  silent loss; here the collector for a scope is a single point. The mitigation
  — partitioning, one collector per tenant — is a deployment decision.

---

## Requirements that land on the collector

Most M-26-14 requirements land on the backend or the organisation. Three land
squarely here.

### Sensitive data protection

M-26-14 Appendix A titles it *"Log Collection Containing Risk of Incidental
Sensitive Data Exposure"*; Table A-1 summarises it as avoiding "unlawful log
capture or exposure" and protecting "confidentiality and integrity of sensitive
log data." That is about *capture*, and capture is what this stack does.

It offers scope-level minimization, which is a real control at coarse grain:
namespace mode collects only what a tenant's Role allows, and
`podLabelSelector` narrows further. It has no content-level control — no
redaction, no masking, no drop rules. Whatever PII, session identifiers, or
tokens a workload prints are forwarded verbatim, and cluster mode — the
platform-monitoring mode — collects every container's stdout by default.

§4.6 places the policy enforcement point "before it crosses agency-controlled
boundaries." If the collector exports straight to a SaaS backend, no such point
exists. The mitigation is a gateway inside the boundary — the shape the examples
already have — but the examples' gateway is the stock core image, which ships no
redaction or transform processor. Relying on it for this requirement needs a
contrib build with one.

### Log management maturity: the chart default fails Level 3

M-26-14 Appendix C Log Management, Level 2: *"Logs are stored and encrypted at
rest."* Level 3: *"Logs are encrypted in transit and at rest, and regularly
hashed for veracity."* LRA §5.3: agencies are required to reach Advanced —
Level 3 — within 320 days.

The chart default is `collector.export.tls.insecure: true`, on the assumption
that a service mesh provides mTLS on the in-cluster hop. Without a mesh — or
without evidence of one, which is what an assessment needs — a default install's
first hop is plaintext and does not meet a mandatory maturity level. Nothing in
this stack hashes records; that belongs to the backend.

### Measuring coverage against inventory

App. B Requirement 4 asks agencies to use CDM, HWAM, and SWAM data to determine
whether log coverage encompasses agency IT; Appendix C grades collection
coverage at 50, 80, 90, and 95 percent of assets.

The receiver exposes how many streams are active, not how many it *should* be
running, so no coverage ratio comes out of it directly. One can be computed
downstream — `active_log_streams` against the container count `k8s_cluster`
reports — with two caveats:

- **Which denominator.** Against an unfiltered container count, deliberate
  exclusions (`podLabelSelector`, the gateway exclusion in the cluster-mode
  example) appear as the gap they are. Against the same filtered scope, they
  vanish from the measurement.
- **Which inventory.** Kubernetes' object list is not the CDM, HWAM, or SWAM
  inventory the requirement names, and pods are too ephemeral to be assets in
  those systems' sense. Mapping workloads onto inventoried hosts is an
  organisational task.
- **Which collector.** In a per-tenant install no single collector sees the
  whole cluster, and a namespace with no release is outside every collector's
  RBAC. It is missing from the numerator and the denominator alike. Coverage
  across tenants can only be measured against a cluster-level inventory:
  `k8s_cluster` in a cluster-mode release, or the agency's own.

Containers that exit before their stream attaches appear in neither count.

---

## M-26-14 requirements, row by row

Table A-1 maps every M-26-14 requirement to the LRA sections addressing it. All
28 rows:

| Table A-1 topic | M-26-14 | Lands | Verdict |
|---|---|---|---|
| Policy and transition context | Main body | Org | — |
| CEM objective | Objective 1 | Collector / Backend | ⚠️ Timely workload logs and Events; operational anomalies only. See [Baseline activity coverage](#baseline-activity-coverage) |
| THIRF objective | Objective 2 | Collector / Backend | ⚠️ Reconstruction needs identity and network layers this stack cannot reach; restarts gap Events |
| Scope of systems | Prioritization | Collector / Org | ⚠️ Agency-operated layers only; the provider-operated control plane is in scope but out of reach. See [Control plane](#control-plane-the-highest-value-layer-out-of-reach) |
| LRA implementation role | Reference Architecture | — | — |
| Agency Logging Plan | Agency Logging Plan | Org | This document can feed a plan's collection section; it is not one |
| Prioritization: HVAs and High-Impact Systems | App. A | Collector | ⚠️ Collected like everything else; nothing marks a workload as high-value |
| Zero trust alignment | App. A | Collector / Backend | ⚠️ The collector's own access is least-privilege in namespace mode, not in cluster mode at defaults. ZT logging means policy-decision context: Kubernetes authorization decisions are in the audit log, east-west access in network data — neither collected |
| Centralized access and visibility | App. A; App. B Req. 2 | Backend / Org | ❌ here |
| **Sensitive data protection** | App. A | **Collector** | ⚠️ See [above](#sensitive-data-protection) |
| IoT and OT logging | App. A | — | ❌ Out of scope |
| AI-enabled enhancement | App. A | Backend | — No AI in the collector |
| Self-assessment | App. A | Org | Collector health metrics are usable evidence for App. E.10.1 |
| Above-minimum retention | App. A | Backend | ❌ here |
| Annual LRA update cycle | App. A | Org | Applies to this document — see the header |
| Actively searchable and retrievable retention | App. B Req. 1 | Backend | ❌ here |
| Top-level SOC availability | App. B Req. 2 | Backend / Org / Collector | ❌ here. In a per-tenant install it is also a collector setting, since each release chooses its export endpoint. See [Namespace mode](#namespace-mode-federated-collection-on-one-condition) |
| Timestamp accuracy | App. B Req. 3 | Collector / Org | ⚠️ See [How the stack collects](#how-the-stack-collects) |
| **Coverage using CDM/HWAM/SWAM** | App. B Req. 4 | **Collector** / Org | ⚠️ See [above](#measuring-coverage-against-inventory) |
| Baseline activity coverage | App. B Req. 5(a)–(j) | Collector | ⚠️ None fully, five partially. See [Baseline activity coverage](#baseline-activity-coverage) |
| Automated alerts | App. B Req. 5(k) | Backend | ❌ here |
| Log access for federal response | Main memo | Backend / Org | ❌ here |
| Maturity model alignment | Main memo; App. C | Org | Five elements; the collector bears on two — collection coverage and log management |
| Maturity: inventory visibility | App. C | Org | ❌ CDM/HWAM/SWAM programme |
| Maturity: collection coverage | App. C | Collector / Backend | ⚠️ See [above](#measuring-coverage-against-inventory) |
| Maturity: collection operations | App. C | Backend | ❌ here |
| Maturity: data retention | App. C | Backend | ❌ here |
| **Maturity: log management** | App. C | **Collector** / Backend | ❌ at chart defaults. See [above](#log-management-maturity-the-chart-default-fails-level-3) |

"Backend" says where a control is implemented, not whose obligation it is. When
the OTLP destination is a SaaS backend, retention, integrity, access logging,
and lawful production of logs (§7.4) are third-party-operated — and under the
*Scope of Systems* row the agency must still ensure them, typically by contract.

---

## Out of scope entirely

Listed so that silence is not mistaken for coverage.

| LRA section | Requirement | Where it belongs |
|---|---|---|
| §6.2.1, §6.2.4, §6.2.7 | kube-apiserver audit log | Provider log service or a control-plane pipeline — see [Control plane](#control-plane-the-highest-value-layer-out-of-reach) |
| §6.2.5 | Node OS, kubelet, container runtime | A separate, privileged, operator-managed pipeline — or the provider, on serverless node pools |
| §6.2.2 | Network flows, DNS, east-west traffic | CNI or eBPF tooling, cloud flow logs |
| §4.5, §5.3 | Actively searchable ≥ 6 months; retrievable ≥ 1 year (App. B Req. 1) | Backend storage tiering |
| §5.1, §5.3 | Required logs available to the top-level SOC (App. B Req. 2) | Backend / Org |
| §4.6 | Policy enforcement point for minimization, redaction, tagging, routing | A gateway inside the agency boundary, or the backend — see [Sensitive data protection](#sensitive-data-protection) |
| §8.2 | Hashing, signing, immutable handling, auditable transfer paths | Backend |
| §7.3 | Schema governance, parser maintenance, drift detection | Backend / Org |
| §7.4 | Portability of the durable normalized record; lawful production of logs to CISA and FBI. Portability at the collection layer is covered in [How the stack collects](#how-the-stack-collects) | Backend / Org |
| §4.7, App. E | Coverage validation, synthetic events, replay tests, controlled rollout | Org — the collector supplies health metrics, not a validation programme |
| §9, §11, App. B | Above-baseline decisions, maturity assessment, the Agency Logging Plan | Org |
| §5.5, §6.2.9 | IoT and OT | Out of scope |
