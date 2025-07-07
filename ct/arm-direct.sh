#!/usr/bin/env bash

# 
# Author: Chandler Weiner (crweiner)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/automatic-ripping-machine/automatic-ripping-machine

APP="Automatic Ripping Machine"
var_tags="media"
var_cpu="2"
var_ram="2048"
var_disk="8"
var_os="debian"
var_version="12"
var_unprivileged="1"
NSAPP=$(echo ${APP,,} | tr -d ' ')

# Check for minimum system requirements
if ! command -v pveversion >/dev/null 2>&1; then echo "⚠️ This script requires Proxmox VE to run. Exiting..."; exit 1; fi
if (( $(pveversion | grep -Po '(?<=pve-manager\/)\d+\.\d+' | sed 's/\.//' | cut -c1) < 7 )); then echo "⚠️ This script requires Proxmox VE 7 or greater to run. Exiting..."; exit 1; fi
if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then echo "⚠️ This script will not work with $(dpkg --print-architecture) architecture. Exiting..."; exit 1; fi

# Define colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
RESET='\033[0m'

# Define message functions
msg_info() {
  echo -e "${BLUE}[INFO]${RESET} $1"
}

msg_ok() {
  echo -e "${GREEN}[OK]${RESET} $1"
}

msg_error() {
  echo -e "${RED}[ERROR]${RESET} $1"
}

msg_warn() {
  echo -e "${YELLOW}[WARN]${RESET} $1"
}

# Display header
echo -e "${MAGENTA}"
echo -e "  _____                                      __      ________ "
echo -e " |  __ \                                     \ \    / /  ____|"
echo -e " | |__) | __ _____  ___ __ ___   _____  __   \ \  / /| |__   "
echo -e " |  ___/ '__/ _ \ \/ / '_ \` _ \ / _ \ \/ /    \ \/ / |  __|  "
echo -e " | |   | | | (_) >  <| | | | | | (_) >  <      \  /  | |____ "
echo -e " |_|   |_|  \___/_/\_\_| |_| |_|\___/_/\_\      \/   |______|"
echo -e "${RESET}"
echo -e "${CYAN}Automatic Ripping Machine LXC - Installer${RESET}"
echo

# Get the next available container ID
CTID=$(pvesh get /cluster/nextid)
msg_info "Container ID: $CTID"

# Get storage location
msg_info "Getting storage location..."
STORAGE_LIST=$(pvesm status -content rootdir | awk 'NR>1 {print $1}')
if [ $(echo $STORAGE_LIST | wc -w) -eq 0 ]; then
  msg_error "No storage with content 'rootdir' found. Please create one."
  exit 1
elif [ $(echo $STORAGE_LIST | wc -w) -eq 1 ]; then
  STORAGE=$STORAGE_LIST
else
  echo -e "${YELLOW}More than one storage with content 'rootdir' found. Please select one:${RESET}"
  select STORAGE in $STORAGE_LIST; do
    if [ -n "$STORAGE" ]; then
      break
    fi
    echo -e "${RED}Invalid selection. Please try again.${RESET}"
  done
fi
msg_ok "Using storage: $STORAGE"

# Create container
msg_info "Creating LXC container..."
pct create $CTID ${STORAGE}:vztmpl/debian-${var_version}-standard_${var_version}*.tar.zst \
  --arch amd64 \
  --cores $var_cpu \
  --hostname arm \
  --memory $var_ram \
  --swap 0 \
  --storage $STORAGE \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --unprivileged $var_unprivileged \
  --features nesting=1 \
  --onboot 1 \
  --ostype $var_os \
  --password "password" \
  --tags $var_tags \
  --rootfs $STORAGE:$var_disk
msg_ok "Created LXC container"

# Check for optical drives on the host
msg_info "Checking for optical drives on the host"
if ! command -v lsscsi >/dev/null 2>&1; then
  apt-get -y install lsscsi >/dev/null 2>&1
fi

OPTICAL_DRIVES=$(lsscsi -g | grep -i cd/dvd | awk '{print $NF}')
if [ -n "$OPTICAL_DRIVES" ]; then
  msg_info "Adding optical drive passthrough to LXC container"
  for drive in $OPTICAL_DRIVES; do
    # Get the major and minor numbers for the device
    MAJOR=$(stat -c %t "$drive" | sed 's/^0*//')
    MINOR=$(stat -c %T "$drive" | sed 's/^0*//')
    if [ -n "$MAJOR" ] && [ -n "$MINOR" ]; then
      echo "lxc.cgroup2.devices.allow: b $MAJOR:$MINOR rwm" >> /etc/pve/lxc/${CTID}.conf
      echo "lxc.mount.entry: $drive $(echo $drive | sed 's|/dev/||') none bind,optional,create=file" >> /etc/pve/lxc/${CTID}.conf
      msg_ok "Added optical drive $drive to container"
    fi
  done
else
  msg_warn "No optical drives detected on the host"
fi

# Start container
msg_info "Starting LXC container..."
pct start $CTID
sleep 5
msg_ok "Started LXC container"

# Install ARM
msg_info "Installing Automatic Ripping Machine..."
pct exec $CTID -- bash -c "apt-get update && apt-get install -y sudo curl gnupg2 lsscsi"

# Install Docker
pct exec $CTID -- bash -c "mkdir -p /etc/docker && echo -e '{\n  \"log-driver\": \"journald\"\n}' > /etc/docker/daemon.json && curl -fsSL https://get.docker.com | sh"

# Create ARM user and group
pct exec $CTID -- bash -c "groupadd arm && useradd -g arm -m arm"

# Create directories for ARM
pct exec $CTID -- bash -c "mkdir -p /home/arm/config /home/arm/media /home/arm/completed && chown -R arm:arm /home/arm"

# Check for optical drives in the container
OPTICAL_DRIVES_CONTAINER=$(pct exec $CTID -- lsscsi -g | grep -i cd/dvd | awk '{print $NF}')
if [ -z "$OPTICAL_DRIVES_CONTAINER" ]; then
  msg_warn "No optical drives detected in the container"
  pct exec $CTID -- bash -c "read -r -p 'Would you like to continue anyway? <y/N> ' prompt && [[ ! \${prompt,,} =~ ^(y|yes)$ ]] && echo 'Please ensure optical drives are properly connected and try again' && exit 1"
else
  msg_ok "Detected optical drives in container: $OPTICAL_DRIVES_CONTAINER"
fi

# Create the start_arm_container.sh script
pct exec $CTID -- bash -c "cat > /home/arm/start_arm_container.sh << 'EOF'
#!/bin/bash
ARM_UID=\$(id -u arm)
ARM_GID=\$(id -g arm)

DEVICE_ARGS=\"\"
for drive in \$(lsscsi -g | grep -i cd/dvd | awk '{print \$NF}'); do
  DEVICE_ARGS=\"\$DEVICE_ARGS --device=\$drive:\$drive\"
done

docker run -d \\
  --name=arm \\
  -e ARM_UID=\"\$ARM_UID\" \\
  -e ARM_GID=\"\$ARM_GID\" \\
  -p 8080:8080 \\
  -v /home/arm/config:/config \\
  -v /home/arm/media:/media \\
  -v /home/arm/completed:/completed \\
  --restart unless-stopped \\
  \$DEVICE_ARGS \\
  automaticripmachine/automatic-ripping-machine:latest
EOF"

# Make the script executable
pct exec $CTID -- bash -c "chmod +x /home/arm/start_arm_container.sh && chown arm:arm /home/arm/start_arm_container.sh"

# Create systemd service
pct exec $CTID -- bash -c "cat > /etc/systemd/system/arm-container.service << 'EOF'
[Unit]
Description=Automatic Ripping Machine Container
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/home/arm
ExecStart=/home/arm/start_arm_container.sh
ExecStop=/usr/bin/docker stop arm
ExecStopPost=/usr/bin/docker rm arm
User=arm
Group=arm

[Install]
WantedBy=multi-user.target
EOF"

# Enable and start the service
pct exec $CTID -- bash -c "systemctl daemon-reload && systemctl enable arm-container.service"

# Create update script
pct exec $CTID -- bash -c "cat > /usr/bin/update-arm << 'EOF'
#!/bin/bash
echo \"Stopping ARM container...\"
docker stop arm
docker rm arm
echo \"Pulling latest ARM image...\"
docker pull automaticripmachine/automatic-ripping-machine:latest
echo \"Starting ARM container...\"
/home/arm/start_arm_container.sh
echo \"ARM has been updated to the latest version.\"
EOF"

# Make the update script executable
pct exec $CTID -- bash -c "chmod +x /usr/bin/update-arm"

# Run the ARM container
pct exec $CTID -- bash -c "/home/arm/start_arm_container.sh"
msg_ok "Installed Automatic Ripping Machine"

# Get container IP
IP=$(pct exec $CTID -- ip a s dev eth0 | sed -n '/inet / s/\// /p' | awk '{print $2}')

# Set container description
pct set $CTID -description "# ${APP} LXC
### https://github.com/community-scripts/ProxmoxVE
<a href='https://ko-fi.com/D1D7EP4GF'><img src='https://img.shields.io/badge/☕-Buy me a coffee-red' /></a>

Automatic Ripping Machine (ARM) is a program that automatically detects the insertion of an optical disc, identifies the type of media, and then rips it according to your preferences.

Web UI: http://${IP}:8080
Username: admin
Password: password"

echo -e "${GREEN}Automatic Ripping Machine is now available at ${BLUE}http://${IP}:8080${RESET}"
echo -e "${GREEN}Default login: ${BLUE}admin / password${RESET}"
