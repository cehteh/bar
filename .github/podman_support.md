# Podman Support Design for Bar

## Overview

This document describes the design for `Bar.d/podman` module that provides container-based build and test environments with support for multiple architectures, layered image construction, network isolation, and artifact collection.

## Requirements Analysis

### 1. Consistency and Completeness Review

The original requirements are generally sound but require some clarifications:

**Enhanced Requirements:**
- Multi-architecture support through QEMU user-mode emulation
- Declarative, rule-based image and container lifecycle management
- Layered image construction with snapshotting capabilities
- Network security through podman's built-in firewall integration
- Timeout-based container execution with output capture
- Artifact extraction from container filesystem layers

**Clarifications needed:**
- Firewall configuration: Podman uses netavark/aardvark-dns for network management; "firewall" rules are implemented via network configuration, not a separate firewall component
- Mutable layer access: Best achieved through volume mounts during container runs, rather than post-execution filesystem extraction

## Prior Art and Dependencies

### Dependencies

**Required:**
- `podman` (>= 4.0) - Container runtime (includes netavark and aardvark-dns for network management)
- `bash` (>= 4.4) - Shell execution
- `qemu-user-static` - Multi-architecture support (when building cross-platform)
- `bar` - Rule engine (self-dependency)

**Podman Components** (bundled with podman >= 4.0):
- `netavark` - Network stack for container networking
- `aardvark-dns` - DNS server for container name resolution

**Optional:**
- `buildah` - Advanced image building (podman includes buildah functionality)
- `skopeo` - Image inspection and copying
- `jq` - JSON parsing for podman inspect outputs

### Prior Art

1. **Docker Buildx** - Multi-platform builds using QEMU
2. **Nix containers** - Declarative container definitions
3. **Earthly** - Build automation with containers
4. **Dagger** - Programmable CI/CD with containers

### Podman Capabilities Assessment

**Strengths:**
- Native multi-architecture support via `--platform` and `--arch` flags
- Built-in timeout support via `--timeout` flag
- Volume mounts for artifact extraction
- Network isolation with custom networks
- Rootless execution capability
- OCI-compliant image format

**Approaches:**
- Image layering: Use multi-stage Containerfile or commit at each stage
- Networking: Use `podman network create` with custom configurations
- Firewall: Leverage podman's network filtering and DNS integration
- Snapshots: Use `podman commit` to create named intermediate images
- Output capture: Standard stdin/stdout redirection works natively

## Architecture Design

### Module Structure

```
Bar.d/
├── podman              # Main module with functions
└── podman_rules        # Integration with std_rules
```

### Core Concepts

#### 1. Image Layers (Inheritance Chain)

Images are built as a stack of layers, each snapshotted for reuse:

```
base-image:tag
  └─ bar-runtime:tag          (base + bar + bash)
      └─ toolchain:arch-tag   (runtime + compiler toolchain)
          └─ devtools:arch-tag (toolchain + debuggers, linters)
              └─ project:hash  (devtools + project files)
                  └─ build:run (project + built artifacts) [ephemeral]
```

#### 2. Container Configurations

Separate image definition from runtime configuration:
- **Image specification**: Declares what to install and how to build
- **Runtime configuration**: Declares network, timeout, volumes, command

#### 3. Rule-Based Workflow

All operations exposed as rules/functions:
- Image building: `podman_image_build`
- Layer snapshotting: `podman_image_snapshot`
- Container running: `podman_run`
- Artifact collection: `podman_artifact_fetch`

## Detailed Design

### 1. Multi-Architecture Support

**Implementation:**
```bash
# Use podman's native multi-arch support
podman build --platform=linux/arm64,linux/amd64 ...

# Or per-architecture with QEMU
podman build --arch=arm64 ...  # Uses qemu-aarch64-static automatically
```

**QEMU Setup:**
- Check for `qemu-user-static` package
- Register binfmt handlers (usually automatic with package)
- Validate with `podman run --rm --platform linux/arm64 alpine uname -m`

**Rule Design:**
```bash
function podman_arch_available ## <arch> - Check if architecture is available
rule podman_require_arch: <arch> - Ensure QEMU support for architecture
```

### 2. Layered Image Construction

**Containerfile Generation Approach:**

Instead of manual multi-stage builds, generate Containerfiles programmatically:

```bash
function podman_image_layer_base ## <name:tag> <base-image> - Create base layer
function podman_image_layer_add ## <name:tag> <parent:tag> <packages..> - Add packages
function podman_image_layer_run ## <name:tag> <parent:tag> <commands..> - Run commands
function podman_image_layer_copy ## <name:tag> <parent:tag> <src> <dst> - Copy files
```

**Snapshot Strategy:**

Use `podman commit` to save intermediate states:

```bash
function podman_image_snapshot ## <container> <name:tag> - Snapshot container to image
```

**Example Workflow:**
```bash
# Build base with bar
rule podman_base_bar: -- '
    podman build -t bar-base:latest -f- . <<EOF
FROM debian:stable-slim
RUN apt-get update && apt-get install -y bash
COPY bar /usr/local/bin/bar
COPY Bar.d /usr/local/lib/bar/Bar.d
EOF
'

# Add toolchain
rule podman_toolchain_rust: podman_base_bar -- '
    podman build -t bar-rust:latest -f- . <<EOF
FROM bar-base:latest
RUN apt-get install -y cargo rustc
EOF
'
```

### 3. Network and Firewall Configuration

**Podman Network Stack:**

Podman (v4.0+) uses **netavark** and **aardvark-dns** for network management:

- **netavark**: Network stack providing network creation, configuration, and isolation. Replaces CNI (Container Network Interface) with native Rust implementation for better performance and rootless support.
- **aardvark-dns**: Container-aware DNS server providing name resolution, custom DNS entries, and DNS-based access control within container networks.

These components enable:
- Automatic container-to-container DNS resolution
- Network isolation between different podman networks
- Custom DNS configuration per network
- Rootless networking support
- Port forwarding and NAT

**Network Creation:**

Podman networks support custom configuration via JSON or CLI, leveraging netavark:

```bash
function podman_network_create ## <name> [options..] - Create isolated network
{
    local name="$1"
    shift
    # Netavark handles network creation with automatic DNS via aardvark-dns
    podman network create "$name" "$@"
}
```

**Port Mapping:**
```bash
function podman_port_map ## <container-port>[/<proto>]:<host-port> - Map port
```

**Network Restrictions:**

Network security is implemented through netavark/aardvark-dns configuration:

1. **DNS-based filtering**: aardvark-dns can restrict name resolution to specific domains
2. **Network isolation**: netavark creates isolated network namespaces per network
3. **Container-level modes**:
   - `none` - No networking (no netavark/DNS)
   - `private` - Isolated network with DNS (default)
   - `host` - Host networking (bypasses netavark)
4. **DNS overrides**: Use `--add-host` to inject custom DNS entries into aardvark-dns
5. **External firewall**: Leverage iptables/nftables for packet filtering (optional enhancement)

**Simplified Firewall Interface:**
```bash
function podman_firewall_config ## <name> - Create firewall configuration object
{
    # Configuration stored as associative array or file
    # Applied during container creation
}

function podman_firewall_allow_port ## <config> <port> [proto] - Allow port
function podman_firewall_allow_network ## <config> <cidr|name> - Allow network range
function podman_firewall_deny_all ## <config> - Default deny policy
```

**Network Presets:**

Predefined network policies for common security scenarios:

```bash
# public: Internet access only, blocks private/local networks
# - Allows: Public internet addresses (for package fetching, external APIs, etc.)
# - Blocks: RFC1918 private ranges (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)
# - Blocks: Localhost (127.0.0.0/8, ::1)
# - Blocks: Link-local (169.254.0.0/16, fe80::/10)
# - Use case: Untrusted containers that need internet but shouldn't access local network
podman_network_public

# private: Private network access only, blocks public internet
# - Allows: RFC1918 private ranges (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)
# - Blocks: Public internet addresses
# - Use case: Internal services that communicate within organization
podman_network_private

# local: Localhost access only
# - Allows: Only 127.0.0.0/8 and ::1
# - Blocks: All other addresses
# - Use case: Testing, local development
podman_network_local

# isolated: No network access
# - Blocks: All network access
# - Use case: Maximum security, offline builds
podman_network_isolated
```

### 4. Container Execution

**Core Execution Function:**
```bash
function podman_run ## <image:tag> [--option..] <rule> [args..] - Run bar in container
{
    ## Executes bar with specified rule inside container
    ## Options:
    ##   --timeout <seconds>   - Maximum runtime (default: none)
    ##   --platform <arch>     - Target architecture
    ##   --network <name>      - Network configuration
    ##   --volume <src:dst>    - Mount volumes
    ##   --env <VAR=value>     - Environment variables
    ##   --artifact <path>     - Collect artifacts from path
    ##   --snapshot <name:tag> - Snapshot final state as image
    
    local image=""
    local timeout=""
    local platform=""
    local network="private"
    local -a volumes=()
    local -a env_vars=()
    local -a artifacts=()
    local snapshot=""
    local bar_rule=""
    local -a bar_args=()
    
    # Parse options...
    # Build podman run command
    # Execute and capture output
    # Handle artifacts
    # Optional snapshot
}
```

**Timeout Implementation:**
```bash
podman run --timeout="${timeout}" ...
```

**Output Capture:**
```bash
# Stdout/stderr are captured naturally
podman run ... 2>&1 | tee /path/to/log
```

### 5. Artifact Collection

**Volume Mount Approach (Preferred):**
```bash
# Mount artifact directory during execution
local artifact_dir="$(mktemp -d)"
podman run --volume "$artifact_dir:/artifacts:z" ... \
    bar build && cp target/release/binary /artifacts/
```

**Commit and Export Approach (Alternative):**
```bash
# Run container
container_id=$(podman run -d ...)
podman wait "$container_id"

# Export filesystem
podman export "$container_id" -o /tmp/export.tar
tar -xf /tmp/export.tar --strip-components=N path/to/artifacts

# Or commit and copy using new container
podman commit "$container_id" temp-artifact-image:latest
podman run --rm -v "$PWD:/output:z" temp-artifact-image:latest \
    cp /path/to/artifact /output/
```

**Artifact Rule:**
```bash
rule podman_artifact_fetch: <container> <source-path> <dest-path> - Extract artifacts
```

### 6. Configuration Objects

Use files or environment to define reusable configurations:

**Image Configuration (Barf):**
```bash
# Define image specifications as rules
rule podman_image_debian_base: -- '
    podman_image_from debian:stable-slim
    podman_image_run "apt-get update && apt-get install -y bash"
    podman_image_copy ./bar /usr/local/bin/bar
    podman_image_copy ./Bar.d /usr/local/lib/bar/
    podman_image_tag bar-base:latest
'

rule podman_image_rust_toolchain: podman_image_debian_base -- '
    podman_image_from bar-base:latest
    podman_image_run "apt-get install -y cargo rustc"
    podman_image_tag bar-rust:latest
'
```

**Container Configuration:**
```bash
# Declare configurations as variables or functions
declare -A PODMAN_CONFIG_BUILD=(
    [image]="bar-rust:latest"
    [timeout]=300
    [network]="private"
    [volumes]="$PWD:/workspace:z"
    [rule]="build"
)

function podman_run_with_config ## <config-name> [args..] - Run with named configuration
{
    local config_name="$1"
    shift
    # Load configuration and execute
}
```

## Module API

### Core Functions

```bash
# Architecture Support
is_podman_arch_available <arch>       # Check arch availability
podman_arch_setup <arch>              # Setup QEMU for arch

# Image Building
podman_image_from <base-image>        # Start image definition
podman_image_run <command>            # Add RUN instruction
podman_image_copy <src> <dst>         # Add COPY instruction
podman_image_env <key> <value>        # Add ENV instruction
podman_image_build <name:tag>         # Build defined image
podman_image_snapshot <name:tag>      # Snapshot current container

# Image Layer Helpers
podman_layer_bar <name:tag> <base>              # Add bar runtime
podman_layer_toolchain <name:tag> <parent> <tool>  # Add toolchain
podman_layer_dev <name:tag> <parent>            # Add dev tools

# Network Configuration (via netavark/aardvark-dns)
podman_network_create <name> [options]  # Create network
podman_network_preset <name> <preset>   # Use network preset
podman_firewall_allow_port <net> <port> # Allow port
podman_firewall_allow_cidr <net> <cidr> # Allow network range

# Container Execution
podman_run <image> [options] <rule> [args]  # Run bar in container
podman_exec <container> <command>           # Execute in running container

# Artifact Management
podman_artifact_fetch <container> <src> <dst>  # Fetch artifacts
podman_artifact_mount <path>                   # Prepare artifact mount

# Lifecycle
podman_container_list                      # List containers
podman_container_stop <container>          # Stop container
podman_container_cleanup <container>       # Remove container
podman_image_list                          # List images
podman_image_remove <image>                # Remove image
```

### Standard Rules Integration

```bash
# Bar.d/podman_rules

rule is_podman_installed: 'is_command_installed podman'

rule podman_check_deps: is_podman_installed -- '
    require podman
    is_podman_arch_available $(uname -m)
'

# Example integration with std_rules
rule build_in_container: podman_check_deps -- '
    podman_run bar-rust:latest --timeout=300 build
'

rule test_in_container: podman_check_deps -- '
    podman_run bar-rust:latest --timeout=600 tests
'
```

## Implementation Phases

### Phase 1: Basic Infrastructure
- [ ] `is_podman_installed` detection
- [ ] `podman_run` basic execution
- [ ] Simple image building from Containerfile
- [ ] Output capture
- [ ] Basic timeout support

### Phase 2: Multi-Architecture
- [ ] QEMU detection and setup
- [ ] `is_podman_arch_available`
- [ ] Cross-architecture image building
- [ ] Architecture-specific rule execution

### Phase 3: Image Layering
- [ ] Image layer helper functions
- [ ] Snapshot functionality
- [ ] Programmatic Containerfile generation
- [ ] Layer caching strategy

### Phase 4: Network Configuration
- [ ] Network creation and management
- [ ] Port mapping
- [ ] Network presets (public, private, local, isolated)
- [ ] Basic firewall rule abstraction

### Phase 5: Artifact Management
- [ ] Volume mount for artifacts
- [ ] Artifact fetch from stopped containers
- [ ] Automatic artifact directory management

### Phase 6: Advanced Features
- [ ] Container configuration templates
- [ ] Parallel container execution
- [ ] Container resource limits
- [ ] Integration with memodb for background jobs

## Usage Examples

### Example 1: Simple Build in Container

```bash
# In Barf
rule container_build: -- '
    podman_run debian:stable bash -c "
        apt-get update && 
        apt-get install -y build-essential &&
        make
    "
'
```

### Example 2: Multi-Architecture Test Matrix

```bash
# In Barf
rule test_matrix: test_x86 test_arm64

rule test_x86: -- '
    podman_run --platform linux/amd64 bar-rust:latest tests
'

rule test_arm64: 'is_podman_arch_available arm64' -- '
    podman_run --platform linux/arm64 bar-rust:latest tests
'
```

### Example 3: Layered Development Environment

```bash
# In Barf

# Base layer with bar
rule image_bar_base: -- '
    podman build -t bar-base:$(git rev-parse --short HEAD) -f- . <<EOF
FROM debian:stable-slim
RUN apt-get update && apt-get install -y bash git
COPY bar /usr/local/bin/bar
COPY Bar.d /usr/local/lib/bar/Bar.d
EOF
'

# Rust toolchain layer
rule image_rust: image_bar_base -- '
    podman build -t bar-rust:latest -f- . <<EOF
FROM bar-base:$(git rev-parse --short HEAD)
RUN apt-get install -y cargo rustc
EOF
'

# Development tools layer
rule image_rust_dev: image_rust -- '
    podman build -t bar-rust-dev:latest -f- . <<EOF
FROM bar-rust:latest
RUN cargo install cargo-audit cargo-outdated
EOF
'

# Run in dev container
rule dev_shell: image_rust_dev -- '
    podman run -it --rm \
        --volume "$PWD:/workspace:z" \
        --workdir /workspace \
        bar-rust-dev:latest bash
'

rule dev_test: image_rust_dev -- '
    podman_run --timeout=300 \
        --volume "$PWD:/workspace:z" \
        --artifact /workspace/target \
        bar-rust-dev:latest \
        tests
'
```

### Example 4: Network-Isolated Build

```bash
# In Barf
rule secure_build: -- '
    # Create isolated network
    podman network create build-isolated || true
    
    # Run build with no internet access
    podman run --rm \
        --network build-isolated \
        --volume "$PWD:/build:z" \
        --workdir /build \
        bar-rust:latest \
        bar build
'
```

### Example 5: Artifact Collection

```bash
# In Barf
rule build_release: -- '
    # Create artifact directory
    mkdir -p artifacts
    
    # Build in container and collect artifacts
    podman run --rm \
        --volume "$PWD:/workspace:z" \
        --volume "$PWD/artifacts:/artifacts:z" \
        --workdir /workspace \
        bar-rust:latest \
        bash -c "bar build --release && cp target/release/myapp /artifacts/"
'
```

## Security Considerations

1. **Rootless Execution**: Prefer rootless podman when possible
2. **Volume Mounts**: Use `:z` or `:Z` for SELinux contexts
3. **Network Isolation**: Default to isolated networks for builds
4. **Image Verification**: Consider signature verification for base images
5. **Resource Limits**: Set CPU/memory limits for untrusted code
6. **Timeout Enforcement**: Always use timeouts for container execution

## Testing Strategy

1. **Unit Tests**: Individual function testing
2. **Integration Tests**: Full workflow testing
3. **Multi-Architecture Tests**: ARM64, x86_64, others (when QEMU available)
4. **Network Tests**: Isolation verification
5. **Performance Tests**: Build time benchmarks

## Open Questions

1. **Caching Strategy**: How aggressively should we cache images?
2. **Cleanup Policy**: When to remove intermediate containers/images?
3. **Registry Integration**: Push/pull from remote registries?
4. **Compose Support**: Should we support pod/compose workflows?
5. **Resource Monitoring**: Should we expose container resource usage?

## Future Enhancements

1. **Podman Pods**: Support for multi-container pods
2. **Registry Publishing**: Push images to registries
3. **Secrets Management**: Secure secret injection
4. **Build Cache**: Advanced layer caching strategies
5. **Remote Execution**: Execute on remote podman hosts
6. **Container Debugging**: Interactive debugging support
7. **Health Checks**: Container health monitoring

## Conclusion

This design provides a comprehensive, rule-based approach to container management within the Bar ecosystem. The implementation prioritizes:

- **Simplicity**: Minimal abstractions, leveraging podman's native features
- **Modularity**: Composable functions following Bar's rule system
- **Flexibility**: Support for various workflows without prescriptive constraints
- **Safety**: Secure defaults with network isolation and timeouts

The phased implementation allows incremental development and testing, with each phase building upon the previous while remaining independently useful.
