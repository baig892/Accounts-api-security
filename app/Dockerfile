# accounts-api container image
# Assumption: service is a Go HTTP service (stated per brief: "assume it exists").
# Multi-stage build so the runtime image ships no compiler, shell, or package manager -
# reduces the attack surface an attacker gets if they land a code-exec bug in the API.

# ---- build stage ----
FROM golang:1.22-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# CGO disabled -> fully static binary, works in a scratch/distroless runtime
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/accounts-api ./cmd/accounts-api

# ---- runtime stage ----
# distroless "nonroot" variant: no shell, no package manager, runs as uid 65532 by default.
# This is the compensating control for not running a full OS-level hardening pass on the
# base image (see DECISIONS.md - "Base image trust").
FROM gcr.io/distroless/static-debian12:nonroot AS runtime

# Explicit, not relying on the image default, so the intent survives a base-image swap.
USER 65532:65532

COPY --from=build --chown=65532:65532 /out/accounts-api /app/accounts-api

# No writable layer is expected at runtime; k8s SecurityContext enforces
# readOnlyRootFilesystem so this is defence in depth, not the primary control.
WORKDIR /app
EXPOSE 8443
ENTRYPOINT ["/app/accounts-api"]
