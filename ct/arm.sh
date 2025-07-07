#!/usr/bin/env bash

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
NSAPP=$(echo ${APP,,} | tr -d ' ')
var_install="${NSAPP}-install"

# Check for minimum system requirements
if ! command -v pveversion >/dev/null 2>&1; then echo "⚠️ This script requires Proxmox VE to run. Exiting..."; exit 1; fi
if (( $(pveversion | grep -Po '(?<=pve-manager\/)\d+\.\d+' | sed 's/\.//' | cut -c1) < 7 )); then echo "⚠️ This script requires Proxmox VE 7 or greater to run. Exiting..."; exit 1; fi
if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then echo "⚠️ This script will not work with $(dpkg --print-architecture) architecture. Exiting..."; exit 1; fi

# Load common functions
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

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

# Override the build_container function to skip downloading the installation script
function custom_build_container() {
  #  if [ "$VERBOSE" == "yes" ]; then set -x; fi

  NET_STRING="-net0 name=eth0,bridge=$BRG$MAC,ip=$NET$GATE$VLAN$MTU"
  case "$IPV6_METHOD" in
  auto) NET_STRING="$NET_STRING,ip6=auto" ;;
  dhcp) NET_STRING="$NET_STRING,ip6=dhcp" ;;
  static)
    NET_STRING="$NET_STRING,ip6=$IPV6_ADDR"
    [ -n "$IPV6_GATE" ] && NET_STRING="$NET_STRING,gw6=$IPV6_GATE"
    ;;
  none) ;;
  esac
  if [ "$CT_TYPE" == "1" ]; then
    FEATURES="keyctl=1,nesting=1"
  else
    FEATURES="nesting=1"
  fi

  if [ "$ENABLE_FUSE" == "yes" ]; then
    FEATURES="$FEATURES,fuse=1"
  fi

  if [[ $DIAGNOSTICS == "yes" ]]; then
    post_to_api
  fi

  TEMP_DIR=$(mktemp -d)
  pushd "$TEMP_DIR" >/dev/null
  if [ "$var_os" == "alpine" ]; then
    export FUNCTIONS_FILE_PATH="$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/alpine-install.func)"
  else
    export FUNCTIONS_FILE_PATH="$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/install.func)"
  fi

  export DIAGNOSTICS="$DIAGNOSTICS"
  export RANDOM_UUID="$RANDOM_UUID"
  export CACHER="$APT_CACHER"
  export CACHER_IP="$APT_CACHER_IP"
  export tz="$timezone"
  #export DISABLEIPV6="$DISABLEIP6"
  export APPLICATION="$APP"
  export app="$NSAPP"
  export PASSWORD="$PW"
  export VERBOSE="$VERBOSE"
  export SSH_ROOT="${SSH}"
  export SSH_AUTHORIZED_KEY
  export CTID="$CT_ID"
  export CTTYPE="$CT_TYPE"
  export ENABLE_FUSE="$ENABLE_FUSE"
  export ENABLE_TUN="$ENABLE_TUN"
  export PCT_OSTYPE="$var_os"
  export PCT_OSVERSION="$var_version"
  export PCT_DISK_SIZE="$DISK_SIZE"
  export PCT_OPTIONS="
    -features $FEATURES
    -hostname $HN
    -tags $TAGS
    $SD
    $NS
    $NET_STRING
    -onboot 1
    -cores $CORE_COUNT
    -memory $RAM_SIZE
    -unprivileged $CT_TYPE
    $PW
  "
  # This executes create_lxc.sh and creates the container and .conf file
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/create_lxc.sh)" $?

  LXC_CONFIG="/etc/pve/lxc/${CTID}.conf"

  # USB passthrough for privileged LXC (CT_TYPE=0)
  if [ "$CT_TYPE" == "0" ]; then
    cat <<EOF >>"$LXC_CONFIG"
# USB passthrough
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
lxc.cgroup2.devices.allow: c 188:* rwm
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.mount.entry: /dev/serial/by-id  dev/serial/by-id  none bind,optional,create=dir
lxc.mount.entry: /dev/ttyUSB0       dev/ttyUSB0       none bind,optional,create=file
lxc.mount.entry: /dev/ttyUSB1       dev/ttyUSB1       none bind,optional,create=file
lxc.mount.entry: /dev/ttyACM0       dev/ttyACM0       none bind,optional,create=file
lxc.mount.entry: /dev/ttyACM1       dev/ttyACM1       none bind,optional,create=file
EOF
  fi

  # Optical drive passthrough
  msg_info "Checking for optical drives on the host"
  if ! command -v lsscsi >/dev/null 2>&1; then
    $STD apt-get -y install lsscsi
  fi
  
  OPTICAL_DRIVES=$(lsscsi -g | grep -i cd/dvd | awk '{print $NF}')
  if [ -n "$OPTICAL_DRIVES" ]; then
    msg_info "Adding optical drive passthrough to LXC container"
    for drive in $OPTICAL_DRIVES; do
      # Get the major and minor numbers for the device
      MAJOR=$(stat -c %t "$drive" | sed 's/^0*//')
      MINOR=$(stat -c %T "$drive" | sed 's/^0*//')
      if [ -n "$MAJOR" ] && [ -n "$MINOR" ]; then
        echo "lxc.cgroup2.devices.allow: b $MAJOR:$MINOR rwm" >> "$LXC_CONFIG"
        echo "lxc.mount.entry: $drive $(echo $drive | sed 's|/dev/||') none bind,optional,create=file" >> "$LXC_CONFIG"
        msg_ok "Added optical drive $drive to container"
      fi
    done
  else
    msg_warn "No optical drives detected on the host"
  fi

  # VAAPI passthrough for privileged containers or known apps
  VAAPI_APPS=(
    "immich"
    "Channels"
    "Emby"
    "ErsatzTV"
    "Frigate"
    "Jellyfin"
    "Plex"
    "Scrypted"
    "Tdarr"
    "Unmanic"
    "Ollama"
    "FileFlows"
    "Open WebUI"
  )

  is_vaapi_app=false
  for vaapi_app in "${VAAPI_APPS[@]}"; do
    if [[ "$APP" == "$vaapi_app" ]]; then
      is_vaapi_app=true
      break
    fi
  done

  if ([ "$CT_TYPE" == "0" ] || [ "$is_vaapi_app" == "true" ]) &&
    ([[ -e /dev/dri/renderD128 ]] || [[ -e /dev/dri/card0 ]] || [[ -e /dev/fb0 ]]); then

    echo ""
    msg_custom "⚙️ " "\e[96m" "Configuring VAAPI passthrough for LXC container"

    if [ "$CT_TYPE" != "0" ]; then
      msg_custom "⚠️ " "\e[33m" "Container is unprivileged – VAAPI passthrough may not work without additional host configuration (e.g., idmap)."
    fi

    msg_custom "ℹ️ " "\e[96m" "VAAPI enables GPU hardware acceleration (e.g., for video transcoding in Jellyfin or Plex)."

    echo ""
    read -rp "➤ Automatically mount all available VAAPI devices? [Y/n]: " VAAPI_ALL

    if [[ "$VAAPI_ALL" =~ ^[Yy]$|^$ ]]; then
      # Mount all devices automatically
      if [[ -e /dev/dri/renderD128 ]]; then
        echo "lxc.cgroup2.devices.allow: c 226:128 rwm" >>"$LXC_CONFIG"
        echo "lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file" >>"$LXC_CONFIG"
      fi
      if [[ -e /dev/dri/card0 ]]; then
        echo "lxc.cgroup2.devices.allow: c 226:0 rwm" >>"$LXC_CONFIG"

        echo "lxc.mount.entry: /dev/dri/card0 dev/dri/card0 none bind,optional,create=file" >>"$LXC_CONFIG"
      fi
      if [[ -e /dev/fb0 ]]; then
        echo "lxc.cgroup2.devices.allow: c 29:0 rwm" >>"$LXC_CONFIG"
        echo "lxc.mount.entry: /dev/fb0 dev/fb0 none bind,optional,create=file" >>"$LXC_CONFIG"
      fi
      if [[ -d /dev/dri ]]; then
        echo "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir" >>"$LXC_CONFIG"
      fi
    else
      # Manual selection per device
      if [[ -e /dev/dri/renderD128 ]]; then
        read -rp "➤ Mount /dev/dri/renderD128 (GPU rendering)? [y/N]: " MOUNT_D128
        if [[ "$MOUNT_D128" =~ ^[Yy]$ ]]; then
          echo "lxc.cgroup2.devices.allow: c 226:128 rwm" >>"$LXC_CONFIG"
          echo "lxc.mount.entry: /dev/dri/renderD128 dev/dri/renderD128 none bind,optional,create=file" >>"$LXC_CONFIG"
        fi
      fi

      if [[ -e /dev/dri/card0 ]]; then
        read -rp "➤ Mount /dev/dri/card0 (GPU hardware interface)? [y/N]: " MOUNT_CARD0
        if [[ "$MOUNT_CARD0" =~ ^[Yy]$ ]]; then
          echo "lxc.cgroup2.devices.allow: c 226:0 rwm" >>"$LXC_CONFIG"
          echo "lxc.mount.entry: /dev/dri/card0 dev/dri/card0 none bind,optional,create=file" >>"$LXC_CONFIG"

        fi
      fi

      if [[ -e /dev/fb0 ]]; then
        read -rp "➤ Mount /dev/fb0 (Framebuffer, GUI)? [y/N]: " MOUNT_FB0
        if [[ "$MOUNT_FB0" =~ ^[Yy]$ ]]; then
          echo "lxc.cgroup2.devices.allow: c 29:0 rwm" >>"$LXC_CONFIG"
          echo "lxc.mount.entry: /dev/fb0 dev/fb0 none bind,optional,create=file" >>"$LXC_CONFIG"
        fi
      fi

      if [[ -d /dev/dri ]]; then
        echo "lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir" >>"$LXC_CONFIG"
      fi
    fi
  fi

  # TUN device passthrough
  if [ "$ENABLE_TUN" == "yes" ]; then
    cat <<EOF >>"$LXC_CONFIG"
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
EOF
  fi

  # This starts the container and executes <app>-install.sh
  msg_info "Starting LXC Container"
  pct start "$CTID"
  msg_ok "Started LXC Container"

  msg_info "Customizing LXC Container"
  : "${tz:=Etc/UTC}"
  if [ "$var_os" == "alpine" ]; then
    sleep 3
    pct exec "$CTID" -- /bin/sh -c 'cat <<EOF >/etc/apk/repositories
http://dl-cdn.alpinelinux.org/alpine/latest-stable/main
http://dl-cdn.alpinelinux.org/alpine/latest-stable/community
EOF'
    pct exec "$CTID" -- ash -c "apk add bash newt curl openssh nano mc ncurses >/dev/null"
  else
    sleep 3
    pct exec "$CTID" -- bash -c "sed -i '/$LANG/ s/^# //' /etc/locale.gen"
    pct exec "$CTID" -- bash -c "locale_line=\$(grep -v '^#' /etc/locale.gen | grep -E '^[a-zA-Z]' | awk '{print \$1}' | head -n 1) && \
    echo LANG=\$locale_line >/etc/default/locale && \
    locale-gen >/dev/null && \
    export LANG=\$locale_line"

    if [[ -z "${tz:-}" ]]; then
      tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Etc/UTC")
    fi
    if pct exec "$CTID" -- test -e "/usr/share/zoneinfo/$tz"; then
      pct exec "$CTID" -- bash -c "tz='$tz'; echo \"\$tz\" >/etc/timezone && ln -sf \"/usr/share/zoneinfo/\$tz\" /etc/localtime"
    else
      msg_warn "Skipping timezone setup – zone '$tz' not found in container"
    fi

    pct exec "$CTID" -- bash -c "apt-get update >/dev/null && apt-get install -y sudo curl mc gnupg2 >/dev/null"
  fi
  msg_ok "Customized LXC Container"

  # Run our update_script directly in the container
  lxc-attach -n "$CTID" -- bash -c "$(declare -f update_script); update_script"
}

# Use our custom build function instead of the original
start
custom_build_container
description

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
