# accounts-api

# Build stage
FROM golang:1.22-bookworm AS builder

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .

# Build a static Linux binary so the runtime image does not need CGO.
RUN CGO_ENABLED=0 \
    GOOS=linux \
    go build \
    -ldflags="-s -w" \
    -o /out/accounts-api \
    ./cmd/accounts-api


# Runtime stage
# Distroless keeps the runtime image minimal and does not include
# a shell or package manager.
FROM gcr.io/distroless/static-debian12:nonroot

USER 65532:65532

WORKDIR /app

COPY --from=builder \
    --chown=65532:65532 \
    /out/accounts-api \
    /app/accounts-api

EXPOSE 8443

ENTRYPOINT ["/app/accounts-api"]
