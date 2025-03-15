FROM golang:1.24.0 AS builder

# Set the Current Working Directory inside the container
WORKDIR /app

# Copy the go.mod and go.sum files
COPY go.mod go.sum ./

# Remove any "replace" directives for local development and tidy dependencies
RUN grep -v '^replace' go.mod > go.mod.tmp && mv go.mod.tmp go.mod && \
    go mod tidy && \
    go mod download

# Copy the source code into the container
COPY . .

# Ensure no "replace" directives remain in the go.mod
RUN grep -v '^replace' go.mod > go.mod.tmp && mv go.mod.tmp go.mod && \
    go mod tidy

# Build the Go app
RUN CGO_ENABLED=0 GOOS=linux go build -o /app/main .

# Stage 2: Run Stage
FROM alpine:latest

# Install ca-certificates to handle HTTPS requests
RUN apk add --no-cache ca-certificates

# Set the Current Working Directory inside the container
WORKDIR /app

# Copy the Pre-built binary file from the previous stage
COPY --from=builder /app/main /app/main

RUN adduser -D app
RUN chown -R app /app

USER app

# Command to run the executable
ENTRYPOINT ["/app/main"]
