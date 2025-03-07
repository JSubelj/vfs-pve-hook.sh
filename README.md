# vfs-pve-hook.sh
## VirtioFs hook for Proxmox written in Bash

## Overview

This script is a Proxmox hook script designed to simplify the management of virtiofs mounts for virtual machines. It automates the creation of virtiofs sockets and configures the necessary QEMU arguments within the Proxmox VM configuration.  It also handles logging, configuration loading, and cleanup.

## Features

* **Automated Virtiofs Setup:** Creates virtiofs sockets and configures QEMU arguments for specified shared directories.
* **Flexible Configuration:** Reads configuration from `vfs-pve-hook.conf` to define shared paths, log levels, and additional virtiofs arguments per VM.
* **NUMA Support:**  Dynamically adds or removes NUMA configuration based on settings in the configuration file.
* **Logging:**  Provides detailed logging with different levels (DEBUG, INFO, WARN, ERROR) to `/dev/stdout` and `/dev/stderr`.
* **Argument Backup:** Backs up existing QEMU arguments before modifying them. Restoring arguments automatically is not supported because Proxmox does not support reloading config after `pre-start` natively.
* **Helper Script Output:** Prints a helper script with mount commands for the VM to easily mount the shared directories.
* **Cleanup:** Removes virtiofs services after the VM stops.
* **Handles Multiple Paths:** Supports multiple shared paths per VM, each with individual settings.
* **Robust Error Handling:** Includes error checking and cleanup to ensure the system remains stable.

## Prerequisites

- Proxmox Virtual Environment (PVE)
- `virtiofsd` executable located at `/usr/libexec/virtiofsd` (default install afaik)
- Proper permissions to read/write Proxmox configuration files
- `systemd` for managing VirtioFS services

## Installation

1. **Clone this repo:** `git clone https://github.com/JSubelj/vfs-pve-hook.sh.git vfs-pve-hook`
2. **Create snippets dir for Proxmox:** `mkdir -p /var/lib/vz/snippets`
3. **Copy script and make it executable to Proxmox dir:** `cp vfs-pve-hook/vfs-pve-hook.sh /var/lib/vz/snippets/ && chmod +x /var/lib/vz/snippets/vfs-pve-hook.sh`
4. **Create [config](#Config):** `vim /var/lib/vz/snippets/vfs-pve-hook.conf` 
5. **Configure the hook:** `qm set <vmid> -hookscript local:snippets/vfs-pve-hook.sh`

## Config

The file uses a simple colon separated key/value format, with sections. Each section is for its own VM. paths, loglevels and virtiofs_args are comma separated. NUMA can be enabled on all or on none.
```ini
[<vmid>]
paths: /path/to/share1, /path/to/share2,...  # Comma-separated list of shared paths
loglevel: debug, info,...  # Comma-separated list of log levels for each path, or a single log level for all. Defaults to 'info' if not set.
virtiofs_args: -args for path 1-,-args for path 2-,... # Comma-separated list of additional virtiofs arguments for each path, or a single list for all.
numa: true/false # Enable or disable NUMA support. Defaults to 'true' if not set.
```

## Usage

The script is automatically called by Proxmox during VM lifecycle events (pre-start, post-start, pre-stop, post-stop). No manual intervention is required. It works like this:
- **1st run**: Generates args and exits; Thats because Proxmox does not update config by default after pre-start
- **subsequent runs**: Checks args, then sets everything up and exists.

## Using other args on VM

You can add other args to `<vmid>.conf` and everything should work fine. The only time you would need to manually remove args from this script is when changing some env vars in script itself. (But then I think you know what you're doing.)

## Error codes

- **255:** Configuration was generated and saved, because PVE does not reload config pre-start has to exit. You need to start vm again.
- **1:** Unknown phase or other errors.
- **3:** Failed to start VirtioFS service.
- **5:** No configuration found for the VM.

## Changing env variables

If you want to change variables in a script, you can create .env file in `/var/lib/vz/snippets/` and change variables that this script uses. Be careful playing with vars and not knowing what your doing can break things.

Vargs that are ok to modify and their default vals:
```
LOGLEVEL="DEBUG"
DEFAULT_VFS_LOGLEVEL="info"
DEFAULT_NUMA="true"

VIRTIOFS_EXE="/usr/libexec/virtiofsd"
SOCKET_DIR="/run/vfs-pve-hook"

CONF_FILE="$RUNTIME_DIR/vfs-pve-hook.conf"

# if you have some special proxmox install:
PROXMOX_CONFIG_DIR="/etc/pve/qemu-server"
PROXMOX_CONFIG="$PROXMOX_CONFIG_DIR/$VMID.conf"
OLD_ARGS_FILE="$PROXMOX_CONFIG_DIR/$VMID.conf.old_args"


```

## License

Is GNU GPL v3, because original Perl script is under that license and this script is a spiritual successor to that hookscript so I honored the license. [Sikha's post about license.](https://forum.proxmox.com/threads/virtiofsd-in-pve-8-0-x.130531/page-5#post-729223)

## Links
- [Drallas's Mount Volumes into Proxmox VMs with Virtio-fs](https://gist.github.com/Drallas/7e4a6f6f36610eeb0bbb5d011c8ca0be)
- [BobC's virtiofsd in PVE 8.0.x](https://forum.proxmox.com/threads/virtiofsd-in-pve-8-0-x.130531/)
- [QEMU virtio-fs shared file system daemon](https://qemu-stsquad.readthedocs.io/en/doc-updates/tools/virtiofsd.html)