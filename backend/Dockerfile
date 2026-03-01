FROM golang:1.24-alpine@sha256:ac60270c8394bda77031017f1adc2c2861f9300a12985055ec4d3e4725c18bb4 AS builder

RUN apk add --no-cache gcc musl-dev

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .
ARG VERSION=dev
RUN CGO_ENABLED=1 go build -ldflags "-X main.Version=${VERSION}" -o afk-cloud ./cmd/server

FROM alpine:3.19@sha256:13b7e62e8df80264dbb747995705a986aa530415763a6c58f84a3ca8af9a5bcd

RUN apk add --no-cache sqlite-libs

WORKDIR /app
COPY --from=builder /app/afk-cloud .

EXPOSE 9847

ENV AFK_PORT=9847
ENV AFK_DB_PATH=/data/afk.db

VOLUME ["/data"]

ENTRYPOINT ["./afk-cloud"]
