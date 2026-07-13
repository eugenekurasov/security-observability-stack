# Multi-stage build for the custom OTel Collector binary.
#
# Stage 1 (builder): installs OCB, copies the local receiver module,
#                    and produces a statically linked binary.
# Stage 2 (runtime): copies the binary into a minimal distroless image.
#
# Build:
#   docker build -t otelcol-security:0.1.0 .
#
# Run locally (requires a collector config at /etc/otelcol/collector.yaml):
#   docker run --rm \
#     -v $(pwd)/helm/observability-stack/templates:/etc/otelcol \
#     otelcol-security:0.1.0

FROM golang:1.26-alpine AS builder

RUN apk add --no-cache git ca-certificates

# Install OCB at the same version as the collector components.
# Bump this together with otelcol_version in otel-components/builder-config.yaml.
RUN go install go.opentelemetry.io/collector/cmd/builder@v0.156.0

WORKDIR /build

# Copy the OCB manifest and the local receiver.
# builder-config.yaml references k8spodlogreceiver via path: ./k8spodlogreceiver,
# so both must land at the same level here.
COPY otel-components/builder-config.yaml ./
COPY otel-components/k8spodlogreceiver   ./k8spodlogreceiver/

# Resolve and verify the local module's dependencies before OCB runs.
RUN cd k8spodlogreceiver && go mod tidy

# Override output_path so the binary lands predictably regardless of what
# the manifest says (the manifest uses ./otel-components/dist which is
# relative to the repo root, not this build directory).
RUN CGO_ENABLED=0 builder \
      --config=builder-config.yaml \
      --output-path=./dist

# ---- runtime image ----
# distroless/static has no shell, no libc — fits a CGO_ENABLED=0 binary.
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /build/dist/otelcol-security /otelcol-security

ENTRYPOINT ["/otelcol-security"]
CMD ["--config=/etc/otelcol/collector.yaml"]
