# Stage 1: Build Stage
FROM golang:1.23.2 AS builder

# Set the Current Working Directory inside the container
WORKDIR /app

# Copy the go.mod and go.sum files
COPY go.mod go.sum ./

# Search and replace any "replace" lines in the go mod for local development
RUN grep -v '^replace' go.mod > go.mod.tmp && mv go.mod.tmp go.mod

# Download all dependencies. Dependencies will be cached if the go.mod and go.sum files are not changed
RUN go mod download

# Copy the source code into the container
COPY . .

RUN grep -v '^replace' go.mod > go.mod.tmp && mv go.mod.tmp go.mod

# Build the Go app
RUN go build -o /main .

# Stage 2: Run Stage
FROM alpine:latest

# Install ca-certificates to handle HTTPS requests
RUN apk add --no-cache ca-certificates

# Set the Current Working Directory inside the container
WORKDIR /app

# Copy the Pre-built binary file from the previous stage
COPY --from=builder /main .

# Command to run the executable
ENTRYPOINT ["/app/main"]
