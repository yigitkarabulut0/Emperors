# Multi-stage, CGO-free, distroless.
#
# TARGETARCH comes from buildx and is what stops the failure the review caught:
# building on the Apple Silicon dev machine produces linux/arm64, which dies with
# "exec format error" on an amd64 VPS. Always build with an explicit --platform.
FROM golang:1.27-bookworm AS build

ARG TARGETARCH
ARG VERSION=dev
WORKDIR /src

# Dependency layer first so code edits do not re-download the module graph.
COPY server/go.mod server/go.sum ./
RUN go mod download

COPY server/ ./
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/api ./cmd/api
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags "-s -w" -o /out/migrate ./cmd/migrate

# static-debian12 rather than scratch: we need CA certificates to reach Neon
# over TLS, and /etc/passwd for the nonroot user.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/api /api
COPY --from=build /out/migrate /migrate
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/api"]
