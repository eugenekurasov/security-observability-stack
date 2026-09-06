# Multi-stage build for secobs-collector, a custom distribution of the
# OpenTelemetry Collector.
#
# Stage 1 (builder): installs OCB and produces a statically linked binary
#                    from builder-config.yaml. Every component, including
#                    k8spodlogreceiver, is resolved from the Go module
#                    proxy — nothing is built from local sources.
# Stage 2 (runtime): copies the binary into a minimal distroless image.
#
# Build:
#   docker build -t secobs-collector:0.1.0 .
#
# Run locally (requires a collector config at /etc/otelcol/collector.yaml):
#   docker run --rm \
#     -v $(pwd)/helm/observability-stack/templates:/etc/otelcol \
#     secobs-collector:0.1.0

FROM golang:1.26-alpine AS builder

RUN apk add --no-cache git ca-certificates

# Install OCB at the same version as the collector components.
# Bump this together with otelcol_version in builder-config.yaml.
RUN go install go.opentelemetry.io/collector/cmd/builder@v0.159.0

WORKDIR /build

COPY builder-config.yaml ./

# The manifest's output_path (./dist) is relative to the working directory,
# so the binary lands at /build/dist — same place the runtime stage copies
# from, and the same ./dist the repo's .gitignore covers when building
# outside Docker.
RUN CGO_ENABLED=0 builder --config=builder-config.yaml

# ---- runtime image ----
# distroless/static has no shell, no libc — fits a CGO_ENABLED=0 binary.
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /build/dist/secobs-collector /secobs-collector

ENTRYPOINT ["/secobs-collector"]
CMD ["--config=/etc/otelcol/collector.yaml"]
