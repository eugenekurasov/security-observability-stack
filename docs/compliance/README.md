# Compliance and framework mappings

How this stack lines up against external frameworks — and, more usefully, where
it stops.

| Mapping | Framework | Kind |
|---|---|---|
| [SOC 2](soc2.md) | AICPA Trust Services Criteria | Audit control set |
| [CISA LRA](cisa-lra.md) | CISA Logging Reference Architecture (Aug 2026) / OMB M-26-14 | Architecture decision framework |
| [Pod Security Standards](pod-security-standards.md) | Kubernetes Pod Security Standards | Workload policy levels, enforced by Kubernetes itself |

## What these documents claim

They are engineering documents, not attestations. Nothing here has been
reviewed by an auditor, an assessor, or CISA. Treat each mapping as the
maintainers' reading of where the stack's design decisions land against a
published framework — a starting point for your own assessment, and a record of
which trade-offs were made deliberately.

## The boundary that matters most

This repository is a **collection and first-hop transport** component. It reads
container logs, Kubernetes events, and metrics through the Kubernetes API
server, batches them, and exports them over OTLP to something else.

That "something else" is where most framework requirements actually land:
retention windows, search performance, normalization to a durable schema,
encryption at rest, immutability and evidentiary handling, alerting, access
review. A mapping that claimed those controls on behalf of the collection layer
would be wrong, and both documents say so explicitly rather than leaving the
reader to work it out.

What the collection layer *can* be held to is narrower and sharper: does it read
from an authoritative source, does it preserve provenance, does it lose data
silently when something breaks, and can it be compromised into reading more than
it should. Those are the questions both mappings spend their time on.
