# Automatic Ripping Machine (ARM) for Proxmox

This repository contains scripts to install [Automatic Ripping Machine (ARM)](https://github.com/automatic-ripping-machine/automatic-ripping-machine) on Proxmox VE using LXC containers.

## What is Automatic Ripping Machine?

Automatic Ripping Machine (ARM) is a program that automatically detects the insertion of an optical disc, identifies the type of media, and then rips it according to your preferences. It's designed to make it easy to back up your DVD and Blu-ray collections.

## Installation

To install ARM on your Proxmox host, run the following command:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/crweiner/ProxmoxVE/refs/heads/automatic-ripping-machine/ct/arm.sh)"
```

This will create a Debian 12 LXC container with ARM installed via Docker.

## Features

- Automatically detects optical drives
- Runs ARM in a Docker container for easy management
- Creates a systemd service to start ARM on boot
- Provides an update script to keep ARM up to date

## Usage

Once installed, you can access the ARM web interface at:

```
http://[container-ip]:8080
```

Default login credentials:
- Username: admin
- Password: password

## Updating ARM

To update ARM to the latest version, run the following command inside the container:

```bash
update-arm
```

## Requirements

- Proxmox VE 7.0 or later
- At least one optical drive (DVD/Blu-ray) connected to your Proxmox host
- Container requires:
  - 2 CPU cores
  - 2GB RAM
  - 8GB disk space

## Troubleshooting

If no optical drives are detected during installation, the script will prompt you to continue anyway or abort. If you continue without optical drives, you'll need to manually configure them later.

## License

MIT License - See LICENSE file for details.
