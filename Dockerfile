# SwiftServe web server (Hummingbird): static site + POST /analyze.
# Multi-stage: heavy Swift toolchain to build, slim runtime to serve.
# Railway auto-detects this Dockerfile (pinned via railway.json).

FROM swift:6.0-noble AS build
WORKDIR /app

# Resolve dependencies in their own layer so code edits don't re-fetch them.
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources ./Sources
COPY Tests ./Tests
RUN swift build -c release --product SwiftServeServer

# Stage the binary plus any resource bundles its dependency graph emits.
RUN mkdir -p /staging \
  && cp .build/release/SwiftServeServer /staging/ \
  && find .build/release -maxdepth 1 -name '*.bundle' -exec cp -R {} /staging/ \;

FROM swift:6.0-noble-slim
WORKDIR /app
COPY --from=build /staging /app
COPY Public ./Public

ENV HOST=0.0.0.0
EXPOSE 8080
CMD ["./SwiftServeServer"]
