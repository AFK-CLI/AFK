FROM golang:1.24-alpine@sha256:8bee1901f1e530bfb4a7850aa7a479d17ae3a18beb6e09064ed54cfd245b7191 AS builder

RUN apk add --no-cache gcc musl-dev

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .
ARG VERSION=dev
RUN CGO_ENABLED=1 go build -ldflags "-X main.Version=${VERSION}" -o afk-cloud ./cmd/server

FROM alpine:3.19@sha256:6baf43584bcb78f2e5847d1de515f23499913ac9f12bdf834811a3145eb11ca1

RUN apk add --no-cache sqlite-libs

WORKDIR /app
COPY --from=builder /app/afk-cloud .

EXPOSE 9847

ENV AFK_PORT=9847
ENV AFK_DB_PATH=/data/afk.db

VOLUME ["/data"]

ENTRYPOINT ["./afk-cloud"]
