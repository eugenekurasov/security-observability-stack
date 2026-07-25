{{- define "observability-stack.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "observability-stack.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "observability-stack.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "observability-stack.labels" -}}
helm.sh/chart: {{ include "observability-stack.chart" . }}
{{ include "observability-stack.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Values.tenantId }}
compliance.io/tenant: {{ .Values.tenantId | quote }}
{{- end }}
{{- end }}

{{- define "observability-stack.selectorLabels" -}}
app.kubernetes.io/name: {{ include "observability-stack.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Resolve the effective collector groups.

A "group" is one collector Deployment. It owns a disjoint subset of the
ownership signals (logs, metrics, events, traces) and carries an optional
`overrides:` subtree that is deep-merged over the global values for that
group's pod. If .Values.collectorGroups is empty, synthesize a single group
named "collector" owning every signal whose global `enabled` flag is true —
so a zero-config install is just the one-group case.

Emits a YAML list; consume with:  include "observability-stack.groups" . | fromYamlArray
*/}}
{{- define "observability-stack.groups" -}}
{{- $root := . -}}
{{- if $root.Values.collectorGroups -}}
{{ $root.Values.collectorGroups | toYaml }}
{{- else -}}
{{- $signals := list -}}
{{- range $name := (list "logs" "metrics" "events" "traces") -}}
{{- if (index $root.Values.signals $name).enabled -}}
{{- $signals = append $signals $name -}}
{{- end -}}
{{- end -}}
- name: collector
  signals: {{ $signals | toJson }}
{{- end -}}
{{- end -}}

{{/*
Merge a group's `overrides` subtree over a deep copy of the global values,
yielding the effective values for that group's pod. deepCopy protects
.Values from mutation by mergeOverwrite.
Call with (dict "root" $root "group" $g); emits YAML, consume with fromYaml.
*/}}
{{- define "observability-stack.groupValues" -}}
{{ mergeOverwrite (deepCopy .root.Values) (default (dict) .group.overrides) | toYaml }}
{{- end -}}

{{/*
Per-group resource name: <fullname>-<group>. One Deployment/ConfigMap/Service
per group all share this stem so they line up.
Call with (dict "root" $root "group" $g).
*/}}
{{- define "observability-stack.groupFullname" -}}
{{- printf "%s-%s" (include "observability-stack.fullname" .root) .group.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Selector labels for a group: the shared selector plus a per-group component
label, so each group's Deployment/Service selects only its own pods.
Call with (dict "root" $root "group" $g).
*/}}
{{- define "observability-stack.groupSelectorLabels" -}}
{{ include "observability-stack.selectorLabels" .root }}
app.kubernetes.io/component: {{ .group.name }}
{{- end -}}

{{/*
Union of all signals owned across every group — the basis for the (global,
one-per-release) RBAC grant. Emits a YAML list; consume with fromYamlArray.
*/}}
{{- define "observability-stack.ownedSignals" -}}
{{- $union := list -}}
{{- range $g := (include "observability-stack.groups" . | fromYamlArray) -}}
{{- range $s := $g.signals -}}{{- $union = append $union $s -}}{{- end -}}
{{- end -}}
{{ $union | uniq | toYaml }}
{{- end -}}

{{/*
Fail the render if the groups are malformed: an unknown signal name, or the
same signal owned by two groups (which would double-collect). This is the
guard that makes split topologies safe to hand to a tenant.
*/}}
{{- define "observability-stack.validateGroups" -}}
{{- $known := list "logs" "metrics" "events" "traces" -}}
{{- $seenSignal := dict -}}
{{- $seenName := dict -}}
{{- range $g := (include "observability-stack.groups" . | fromYamlArray) -}}
{{- if not $g.name -}}
{{- fail "collectorGroups: every group must have a non-empty name" -}}
{{- end -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $g.name) -}}
{{- fail (printf "collectorGroups: group name %q is not a valid DNS-1123 label (lowercase alphanumeric and -, must start/end alphanumeric)" $g.name) -}}
{{- end -}}
{{- if hasKey $seenName $g.name -}}
{{- fail (printf "collectorGroups: duplicate group name %q; group names must be unique" $g.name) -}}
{{- end -}}
{{- $seenName = set $seenName $g.name true -}}
{{- if not $g.signals -}}
{{- fail (printf "collectorGroups: group %q owns no signals; give it at least one of %s or remove it" $g.name (join ", " $known)) -}}
{{- end -}}
{{- range $s := $g.signals -}}
{{- if not (has $s $known) -}}
{{- fail (printf "collectorGroups: group %q owns unknown signal %q (valid: %s)" $g.name $s (join ", " $known)) -}}
{{- end -}}
{{- if hasKey $seenSignal $s -}}
{{- fail (printf "collectorGroups: signal %q is owned by both %q and %q; each signal may belong to only one group" $s (index $seenSignal $s) $g.name) -}}
{{- end -}}
{{- $seenSignal = set $seenSignal $s $g.name -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "observability-stack.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "observability-stack.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
