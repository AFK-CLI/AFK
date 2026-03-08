FROM node:22-alpine@sha256:e4bf2a82ad0a4037d28035ae71529873c069b13eb0455466ae0bc13363826e34 AS frontend

WORKDIR /admin
COPY admin/package.json admin/package-lock.json ./
RUN npm ci
COPY admin/ .
RUN npm run build

FROM golang:1.25-alpine@sha256:8e02eb337d9e0ea459e041f1ee5eece41cbb61f1d83e7d883a3e2fb4862063fa AS builder

RUN apk add --no-cache gcc musl-dev

WORKDIR /app

COPY backend/go.mod backend/go.sum ./
RUN go mod download

COPY backend/ .
COPY --from=frontend /backend/internal/handler/static/admin/ ./internal/handler/static/admin/
ARG VERSION=dev
RUN CGO_ENABLED=1 go build -ldflags "-X main.Version=${VERSION}" -o afk-cloud ./cmd/server

FROM alpine:3.19@sha256:6baf43584bcb78f2e5847d1de515f23499913ac9f12bdf834811a3145eb11ca1

RUN apk add --no-cache sqlite-libs

RUN addgroup -S afk && adduser -S afk -G afk
RUN mkdir -p /data && chown afk:afk /data

WORKDIR /app
COPY --from=builder /app/afk-cloud .

EXPOSE 9847

ENV AFK_PORT=9847
ENV AFK_DB_PATH=/data/afk.db

VOLUME ["/data"]

USER afk

ENTRYPOINT ["./afk-cloud"]
