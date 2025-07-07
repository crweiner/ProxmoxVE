#!/usr/bin/env bash
source misc/arm-build.func
# 
# Author: Chandler Weiner (crweiner)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/automatic-ripping-machine/automatic-ripping-machine

APP="Automatic Ripping Machine"
var_tags="${var_tags:-media}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-8}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -d /var ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  
  msg_info "Updating Container OS"
  $STD apt-get update
  $STD apt-get -y upgrade
  msg_ok "Updated Container OS"
  
  # Check if Docker is installed, if not install it
  if ! command -v docker >/dev/null 2>&1; then
    msg_info "Installing Docker"
    DOCKER_CONFIG_PATH='/etc/docker/daemon.json'
    mkdir -p $(dirname $DOCKER_CONFIG_PATH)
    echo -e '{\n  "log-driver": "journald"\n}' >/etc/docker/daemon.json
    $STD sh <(curl -fsSL https://get.docker.com)
    msg_ok "Installed Docker"
  else
    msg_ok "Docker is already installed"
  fi

  # Create arm user and group if they don't exist
  msg_info "Setting up ARM user and group"
  if ! getent group arm >/dev/null 2>&1; then
    $STD groupadd arm
  fi
  if ! getent passwd arm >/dev/null 2>&1; then
    $STD useradd -g arm -m arm
  fi
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
  if ! command -v lsscsi >/dev/null 2>&1; then
    $STD apt-get -y install lsscsi
  fi

  OPTICAL_DRIVES=$(lsscsi -g | grep -i cd/dvd | awk '{print $NF}')
  if [ -z "$OPTICAL_DRIVES" ]; then
    msg_error "No optical drives detected"
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
docker run -d \\
  --name=arm \\
  -e ARM_UID="${ARM_UID}" \\
  -e ARM_GID="${ARM_GID}" \\
  -p 8080:8080 \\
  -v /home/arm/config:/config \\
  -v /home/arm/media:/media \\
  -v /home/arm/completed:/completed \\
  --restart unless-stopped \\
  ${DEVICE_ARGS} \\
  automaticripmachine/automatic-ripping-machine:latest
EOF

  chmod +x /home/arm/start_arm_container.sh
  chown arm:arm /home/arm/start_arm_container.sh

  # Run the ARM container
  $STD /home/arm/start_arm_container.sh
  msg_ok "Installed Automatic Ripping Machine"

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
  
  msg_info "Cleaning up"
  $STD apt-get -y autoremove
  $STD apt-get -y autoclean
  msg_ok "Cleaned"
  
  exit
}

start
build_container

# Run our update_script directly in the container
lxc-attach -n "$CTID" -- bash -c "$(declare -f update_script); update_script"
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8080${CL}"
echo -e "${INFO}${YW} Default login: ${CL}"
echo -e "${TAB}${GATEWAY}${BGN}admin / password${CL}"
