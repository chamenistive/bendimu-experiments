FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/sut-v1 .

FROM scratch
USER 65532:65532
COPY --from=build /out/sut-v1 /sut-v1
EXPOSE 8080
ENTRYPOINT ["/sut-v1"]
