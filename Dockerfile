FROM rust:1.83.0-alpine AS builder

# 添加构建依赖
RUN apk add --no-cache musl-dev

COPY . .

RUN cargo build


FROM alpine:latest

COPY --from=builder ./target/debug/rgb-lightning-node /usr/bin/rgb-lightning-node

RUN apk add --no-cache \
    ca-certificates openssl

ENTRYPOINT ["/usr/bin/rgb-lightning-node"]
