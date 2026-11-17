# --- build ---
FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/server .

# --- run ---
FROM alpine:3.20
RUN adduser -D -u 10001 app && mkdir /data && chown app /data
COPY --from=build /out/server /usr/local/bin/server
USER app
ENV ADDR=:8080 DATA_DIR=/data
EXPOSE 8080
VOLUME ["/data"]
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
ENTRYPOINT ["/usr/local/bin/server"]
