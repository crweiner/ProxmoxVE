#!/usr/bin/env bash

# 
# Author: Chandler Weiner (crweiner)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

APP="Automatic Ripping Machine"
var_disk="4"
var_cpu="2"
var_ram="2048"
var_os="debian"
var_version="12"
NSAPP=$(echo ${APP,,} | tr -d ' ')
var_install="${NSAPP}-install"

# Check for minimum system requirements
if ! command -v pveversion >/dev/null 2>&1; then echo "⚠️ This script requires Proxmox VE to run. Exiting..."; exit 1; fi
if (( $(pveversion | grep -Po '(?<=pve-manager\/)\d+\.\d+' | sed 's/\.//' | cut -c1) < 7 )); then echo "⚠️ This script requires Proxmox VE 7 or greater to run. Exiting..."; exit 1; fi
if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then echo "⚠️ This script will not work with $(dpkg --print-architecture) architecture. Exiting..."; exit 1; fi

# Load common functions
source /dev/stdin <<< "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)"

# Script functions
function default_settings() {
  CT_TYPE="1"
  PW=""
  CT_ID=$NEXTID
  HN=$NSAPP
  DISK_SIZE="$var_disk"
  CORE_COUNT="$var_cpu"
  RAM_SIZE="$var_ram"
  BRG="vmbr0"
  NET=dhcp
  GATE=""
  APT_CACHER=""
  DISABLEIP6="no"
  MTU=""
  SD=""
  NS=""
  MAC=""
  VLAN=""
  SSH="no"
  VERB="no"
  echo_default
}

function update_script() {
  if [[ "${VERB}" == "yes" ]]; then YW=" -v"; else YW=""; fi
  SPINNER_PID=$(show_spinner)
  if [ "$var_os" == "debian" ]; then
    msg_info "Updating Container OS"
    $STD apt-get update &>/dev/null
    $STD apt-get -y upgrade &>/dev/null
    msg_ok "Updated Container OS"
  fi
  msg_info "Installing Dependencies"
  $STD apt-get update &>/dev/null
  $STD apt-get -y install curl &>/dev/null
  $STD apt-get -y install sudo &>/dev/null
  msg_ok "Installed Dependencies"
  stop_spinner $SPINNER_PID
  msg_info "Downloading ${APP} LXC Install Script"
  $STD curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/install/$var_install.sh -o /tmp/$var_install.sh
  chmod +x /tmp/$var_install.sh
  msg_ok "Downloaded ${APP} LXC Install Script"
  msg_info "Running ${APP} LXC Install Script"
  $STD bash /tmp/$var_install.sh
  msg_ok "Completed ${APP} LXC Install Script"
  msg_info "Cleaning up"
  $STD rm -rf /tmp/$var_install.sh
  msg_ok "Cleaned"
}

start
build_container
description

msg_info "Starting LXC Container"
pct start $CTID
msg_ok "Started LXC Container"

lxc-attach -n $CTID -- bash -c "$(declare -f update_script); update_script"

IP=$(pct exec $CTID ip a s dev eth0 | sed -n '/inet / s/\// /p' | awk '{print $2}')
pct set $CTID -description "# ${APP} LXC
### https://github.com/community-scripts/ProxmoxVE
<a href='https://ko-fi.com/D1D7EP4GF'><img src='https://img.shields.io/badge/☕-Buy me a coffee-red' /></a>

Automatic Ripping Machine (ARM) is a program that automatically detects the insertion of an optical disc, identifies the type of media, and then rips it according to your preferences.

Web UI: http://${IP}:8080
Username: admin
Password: password"

echo -e "${GATEWAY}Automatic Ripping Machine is now available at ${BL}http://${IP}:8080${CL}"
echo -e "${GATEWAY}Default login: ${BL}admin / password${CL}"
