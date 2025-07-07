#!/usr/bin/env bash

# Copyright (c) 2021-2025 community-scripts ORG
# Author: Chandler Weiner (crweiner)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/automatic-ripping-machine/automatic-ripping-machine

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing dependencies"
$STD apt-get install -y \
  curl \
  gnupg2 \
  lsscsi \
  sudo

# Install Docker
msg_info "Installing Docker"
DOCKER_CONFIG_PATH='/etc/docker/daemon.json'
mkdir -p $(dirname $DOCKER_CONFIG_PATH)
echo -e '{\n  "log-driver": "journald"\n}' >/etc/docker/daemon.json
$STD sh <(curl -fsSL https://get.docker.com)
msg_ok "Installed Docker"

# Create ARM user and group
msg_info "Setting up ARM user and group"
$STD groupadd arm
$STD useradd -g arm -m arm
msg_ok "Set up ARM user and group"

# Get ARM user and group IDs
ARM_UID=$(id -u arm)
ARM_GID=$(id -g arm)

# Create directories for ARM
msg_info "Creating ARM directories"
mkdir -p /home/arm/config
mkdir -p /home/arm/media
mkdir -p /home/arm/completed
chown -R arm:arm /home/arm
msg_ok "Created ARM directories"

# Check for optical drives
msg_info "Checking for optical drives"
OPTICAL_DRIVES=$(lsscsi -g | grep -i cd/dvd | awk '{print $NF}')
if [ -z "$OPTICAL_DRIVES" ]; then
  msg_warn "No optical drives detected"
  read -r -p "${TAB3}Would you like to continue anyway? <y/N> " prompt
  if [[ ! ${prompt,,} =~ ^(y|yes)$ ]]; then
    echo -e "${NETWORK}Please ensure optical drives are properly connected and try again"
    exit 1
  fi
else
  msg_ok "Detected optical drives: $OPTICAL_DRIVES"
fi

# Create ARM Docker container
msg_info "Installing Automatic Ripping Machine"
DEVICE_ARGS=""
for drive in $OPTICAL_DRIVES; do
  DEVICE_ARGS+=" --device=$drive:$drive"
done

# Create the start_arm_container.sh script
cat <<EOF > /home/arm/start_arm_container.sh
#!/bin/bash
ARM_UID=\$(id -u arm)
ARM_GID=\$(id -g arm)

DEVICE_ARGS=""
for drive in \$(lsscsi -g | grep -i cd/dvd | awk '{print \$NF}'); do
  DEVICE_ARGS="\$DEVICE_ARGS --device=\$drive:\$drive"
done

docker run -d \\
  --name=arm \\
  -e ARM_UID="\$ARM_UID" \\
  -e ARM_GID="\$ARM_GID" \\
  -p 8080:8080 \\
  -v /home/arm/config:/config \\
  -v /home/arm/media:/media \\
  -v /home/arm/completed:/completed \\
  --restart unless-stopped \\
  \$DEVICE_ARGS \\
  automaticripmachine/automatic-ripping-machine:latest
EOF

chmod +x /home/arm/start_arm_container.sh
chown arm:arm /home/arm/start_arm_container.sh

# Create systemd service to start ARM on boot
msg_info "Creating ARM service"
cat <<EOF > /etc/systemd/system/arm-container.service
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
EOF

$STD systemctl daemon-reload
$STD systemctl enable arm-container.service
msg_ok "Created ARM service"

# Add update script
cat <<EOF > /usr/bin/update-arm
#!/bin/bash
echo "Stopping ARM container..."
docker stop arm
docker rm arm
echo "Pulling latest ARM image..."
docker pull automaticripmachine/automatic-ripping-machine:latest
echo "Starting ARM container..."
/home/arm/start_arm_container.sh
echo "ARM has been updated to the latest version."
EOF

chmod +x /usr/bin/update-arm

# Run the ARM container
msg_info "Starting ARM container"
$STD /home/arm/start_arm_container.sh
msg_ok "Started ARM container"

motd_ssh
customize

msg_info "Cleaning up"
$STD apt-get -y autoremove
$STD apt-get -y autoclean
msg_ok "Cleaned"
