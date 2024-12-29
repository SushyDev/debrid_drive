<div align="center">
  <p>Fileserver for `fuse_video_stream` that serves your media from real debrid</p>
</div>

---

## Table of Contents

- [What is Debrid Drive](#what-is-debrid_drive)
- [Getting Started](#getting-started)
  - [Docker Setup](#docker-setup)
  - [Native Setup](#native-setup)
- [Development](#development)
  - [Prerequisites](#prerequisites)
  - [Setup Instructions](#setup-instructions)
  - [Running the Project](#running-the-project)
- [Contributing](#contributing)
- [License](#license)

---

## What is Debrid Drive

Debrid Drive is a fileserver for `fuse_video_stream` that lists your media from real debrid, forwards deletions to the real debrid and keeps track of hardlinks.
- When a file hosted by debrid drive is deleted and it is linked to an entry in your real debrid account it will get removed from there too.
- When a file hosted by debrid drive is hardlinked it will "move" the file from the `media_manager` directory to the new path
  - Keep in mind you can only link to locations inside the `debrid_drive` folder

## Getting Started

### Docker Setup

The image for this project is available on Docker at `ghcr.io/sushydev/debrid_drive:latest`. Below is an example of a `docker-compose.yml` file to set up the project:

```yaml
debrid_drive:
  container_name: debrid_drive
  image: ghcr.io/sushydev/debrid_drive:latest
  restart: unless-stopped
  network_mode: host  # Preferable if using a specific network
  volumes:
    - ./debrid_drive.yml:/app/config.yml  # Bind configuration
    - ./filesystem.db:/app/filesystem.db # Persist DB
    - ./media.db:/app/media.db # Persist DB
    - ./logs/debrid_drive:/app/logs  # Store logs
  healthcheck:
    test: ["CMD-SHELL", "curl --fail http://localhost:6969 || exit 1"]
    interval: 1m00s
    timeout: 15s
    retries: 3
    start_period: 1m00s
```

### Native Setup

To build the project manually, you can use the following Go commands:

1. **Download Dependencies:**
    ```sh
    go mod download
    ```

2. **Build the Project:**
    ```sh
    CGO_ENABLED=0 GOOS=linux go build -o debrid_drive main.go
    ```

### Configuration

Debrid Drive uses a `config.yml` file (Very important its `yml` and not `yaml`) with the following properties

Example `config.yml`
```yaml
port: 6969

# Content-type is an identifier for Debrid Drive to identify its own files
content_type: "application/debrid-drive"

# Your Real Debrid API token
real_debrid_token: ""
```

#### Done
Now you're ready to use it
    
---

## Development

### Prerequisites

Ensure you have the following installed on your system:

- **Go** (version 1.23.2 or later)

### Setup Instructions

1. **Install Dependencies:**
    ```sh
    go mod download
    ```

### Running the Project

- **Start:**
    ```sh
    go run main.go
    ```

---

## Contributing

Contributions are welcome! Please follow the guidelines in the [CONTRIBUTING.md](CONTRIBUTING.md) for submitting changes.

---

## License

This project is licensed under the GNU GPLv3 License. See the [LICENSE](LICENSE) file for details.
