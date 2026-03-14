#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "[ERRORE] Esegui come root."
  exit 1
fi

STATE_DIR="/etc/xray-bundle"
STATE_FILE="$STATE_DIR/state.env"
WG_NAME="wgpf"
WG_PORT="65523"
WG_SERVER_IP="10.200.0.1/30"
WG_SERVER_PEER_IP="10.200.0.2/32"
WG_CLIENT_IP="10.200.0.2/30"
WG_MTU="1380"
WG_KEEPALIVE="1"
XRAY_PORT="443"
SSH_NEW_PORT="65522"
GL_XRAY_SCRIPT="/root/glinet_xray_client_setup.sh"
GL_WG_CONF="/root/glinet_pf_wg_client.conf"
OMR_KERNEL_BASE_URL="https://repoomr.3klab.com/kernel"
OMR_KERNEL_IMAGE_PKG="linux-image-6.12.67-x64v3-omr-3ktest-xanmod1_6.12.67-7_amd64.deb"
OMR_KERNEL_HEADERS_PKG="linux-headers-6.12.67-x64v3-omr-3ktest-xanmod1_6.12.67-7_amd64.deb"
OMR_KERNEL_VERSION="6.12.67-x64v3-omr-3ktest-xanmod1"

ask_yes_no() {
  local prompt="$1"
  local ans
  while true; do
    read -r -p "$prompt [s/n]: " ans
    case "${ans,,}" in
      s|si|y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "Rispondi s o n." ;;
    esac
  done
}

save_state() {
  local server_endpoint="$1"
  local uuid="$2"
  local ssh_port="$3"
  local public_if="$4"
  local gl_wg_pubkey="$5"

  install -d -m 700 "$STATE_DIR"
  cat >"$STATE_FILE" <<EOF
INSTALLED=1
SERVER_ENDPOINT="$server_endpoint"
UUID="$uuid"
SSH_PORT="$ssh_port"
PUBLIC_IF="$public_if"
GL_WG_PUBKEY="$gl_wg_pubkey"
GL_XRAY_SCRIPT="$GL_XRAY_SCRIPT"
GL_WG_CONF="$GL_WG_CONF"
EOF
  chmod 600 "$STATE_FILE"
}

load_state() {
  if [[ -s "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    return 0
  fi
  return 1
}

check_environment() {
  local os_id version_id arch virt

  if [[ ! -r /etc/os-release ]]; then
    echo "[ERRORE] /etc/os-release non trovato."
    exit 1
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  os_id="${ID:-}"
  version_id="${VERSION_ID:-0}"
  arch="$(uname -m)"

  if [[ "$os_id" != "debian" ]]; then
    echo "[ERRORE] Sistema non supportato: richiesto Debian, trovato ${os_id:-sconosciuto}."
    exit 1
  fi

  if [[ "${version_id%%.*}" -lt 11 ]]; then
    echo "[ERRORE] Versione Debian non supportata: richiesto Debian 11 o superiore, trovata ${VERSION_ID:-sconosciuta}."
    exit 1
  fi

  if [[ "$arch" != "x86_64" ]]; then
    echo "[ERRORE] Architettura non supportata: richiesto x86_64, trovata $arch."
    exit 1
  fi

  if command -v systemd-detect-virt >/dev/null 2>&1; then
    virt="$(systemd-detect-virt 2>/dev/null || true)"
    case "$virt" in
      ""|none|kvm|qemu|vmware|microsoft|oracle|amazon|parallels|bhyve|zvm) ;;
      openvz|lxc|lxc-libvirt|systemd-nspawn|uml)
        echo "[ERRORE] Virtualizzazione non supportata per questo setup WireGuard: $virt."
        exit 1
        ;;
      *)
        echo "[ERRORE] Ambiente virtualizzato non verificato per WireGuard: $virt."
        exit 1
        ;;
    esac
  fi
}

install_base_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    curl ca-certificates gnupg lsb-release jq unzip iptables-persistent \
    wireguard-tools
}

configure_ssh_port_optional() {
  echo "[ATTENZIONE] SSH verra spostato su $SSH_NEW_PORT."
  echo "[ATTENZIONE] Verifica la porta $SSH_NEW_PORT prima di chiudere la sessione."
  cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%F-%H%M%S)

  if grep -Eq '^[#[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config; then
    sed -i -E "0,/^[#[:space:]]*Port[[:space:]]+[0-9]+/s//Port $SSH_NEW_PORT/" /etc/ssh/sshd_config
    sed -i -E '/^[#[:space:]]*Port[[:space:]]+[0-9]+/d' /etc/ssh/sshd_config
    echo "Port $SSH_NEW_PORT" >>/etc/ssh/sshd_config
  else
    echo "Port $SSH_NEW_PORT" >>/etc/ssh/sshd_config
  fi

  sshd -t
  systemctl restart ssh 2>/dev/null || systemctl restart sshd

  iptables -C INPUT -p tcp --dport "$SSH_NEW_PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$SSH_NEW_PORT" -j ACCEPT
  iptables -D INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
  netfilter-persistent save >/dev/null 2>&1 || true

  echo "[OK] SSH su $SSH_NEW_PORT. Login: ssh -p $SSH_NEW_PORT root@<IP_VPS>"
  echo "$SSH_NEW_PORT"
}

install_custom_kernel_optional() {
  if ! ask_yes_no "Vuoi configurare il kernel modificato per best performance"; then
    return
  fi

  local workdir image_deb headers_deb
  workdir="$(mktemp -d /tmp/omr-kernel.XXXXXX)"
  image_deb="$workdir/$OMR_KERNEL_IMAGE_PKG"
  headers_deb="$workdir/$OMR_KERNEL_HEADERS_PKG"

  echo "[INFO] Download kernel OMR da $OMR_KERNEL_BASE_URL"
  curl -fL "$OMR_KERNEL_BASE_URL/$OMR_KERNEL_IMAGE_PKG" -o "$image_deb"
  curl -fL "$OMR_KERNEL_BASE_URL/$OMR_KERNEL_HEADERS_PKG" -o "$headers_deb"

  apt-get install -y "$image_deb" "$headers_deb"

  if command -v grub-set-default >/dev/null 2>&1 && [[ -f /etc/default/grub ]]; then
    local grub_entry="Advanced options for Debian GNU/Linux>Debian GNU/Linux, with Linux $OMR_KERNEL_VERSION"
    if grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
      sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
    else
      echo 'GRUB_DEFAULT=saved' >>/etc/default/grub
    fi
    grub-set-default "$grub_entry"
    update-grub
    echo "[INFO] GRUB default impostato su: $grub_entry"
  else
    echo "[ATTENZIONE] grub-set-default non disponibile: imposta manualmente il kernel di default."
  fi

  rm -rf "$workdir"
  echo "[INFO] Kernel OMR installato:"
  echo "       $OMR_KERNEL_IMAGE_PKG"
  echo "       $OMR_KERNEL_HEADERS_PKG"
  echo "[INFO] Serve reboot per attivarlo."
}

install_xray_core() {
  bash <(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) install
}

detect_public_if() {
  PUBLIC_IF="$(ip -4 route show default | awk 'NR==1{print $5}')"
  [[ -n "$PUBLIC_IF" ]] || { echo "[ERRORE] Interfaccia default non trovata."; exit 1; }
}

detect_public_ip() {
  SERVER_ENDPOINT="$(ip -4 -o addr show dev "$PUBLIC_IF" scope global | awk 'NR==1{print $4}' | cut -d/ -f1)"
  [[ -n "$SERVER_ENDPOINT" ]] || { echo "[ERRORE] IP pubblico non trovato su $PUBLIC_IF."; exit 1; }
}

configure_xray_server() {
  local uuid="$1"

  install -d -m 755 /usr/local/etc/xray
  cat >/usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "port": $XRAY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$uuid", "level": 0 }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      },
      "sniffing": {
        "enabled": false
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]
}
EOF

  /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
  systemctl enable --now xray
  systemctl restart xray
}

generate_wg_keys() {
  install -d -m 700 /etc/wireguard

  if [[ ! -s /etc/wireguard/${WG_NAME}_server.key ]]; then
    wg genkey | tee /etc/wireguard/${WG_NAME}_server.key | wg pubkey >/etc/wireguard/${WG_NAME}_server.pub
  fi

  if [[ ! -s /etc/wireguard/${WG_NAME}_client.key ]]; then
    wg genkey | tee /etc/wireguard/${WG_NAME}_client.key | wg pubkey >/etc/wireguard/${WG_NAME}_client.pub
  fi

  chmod 600 /etc/wireguard/${WG_NAME}_server.key /etc/wireguard/${WG_NAME}_client.key

  WG_SERVER_PRIVKEY="$(< /etc/wireguard/${WG_NAME}_server.key)"
  WG_SERVER_PUBKEY="$(< /etc/wireguard/${WG_NAME}_server.pub)"
  WG_CLIENT_PRIVKEY="$(< /etc/wireguard/${WG_NAME}_client.key)"
  WG_CLIENT_PUBKEY="$(< /etc/wireguard/${WG_NAME}_client.pub)"
}

configure_wg_server() {
  local public_if="$1"

  cat >/etc/wireguard/${WG_NAME}.conf <<EOF
[Interface]
Address = $WG_SERVER_IP
ListenPort = $WG_PORT
PrivateKey = $WG_SERVER_PRIVKEY
MTU = $WG_MTU
SaveConfig = false

PostUp = sysctl -w net.ipv4.ip_forward=1 >/dev/null
PostUp = iptables -C INPUT -p udp --dport $WG_PORT -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport $WG_PORT -j ACCEPT
PostUp = iptables -C FORWARD -i $WG_NAME -j ACCEPT 2>/dev/null || iptables -I FORWARD -i $WG_NAME -j ACCEPT
PostUp = iptables -C FORWARD -o $WG_NAME -j ACCEPT 2>/dev/null || iptables -I FORWARD -o $WG_NAME -j ACCEPT
PostUp = iptables -t nat -C POSTROUTING -o $WG_NAME -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o $WG_NAME -j MASQUERADE
PostUp = iptables -t nat -C PREROUTING -i $public_if -p tcp --dport 1:442 -j DNAT --to-destination 10.200.0.2 2>/dev/null || iptables -t nat -A PREROUTING -i $public_if -p tcp --dport 1:442 -j DNAT --to-destination 10.200.0.2
PostUp = iptables -t nat -C PREROUTING -i $public_if -p tcp --dport 444:65521 -j DNAT --to-destination 10.200.0.2 2>/dev/null || iptables -t nat -A PREROUTING -i $public_if -p tcp --dport 444:65521 -j DNAT --to-destination 10.200.0.2
PostUp = iptables -t nat -C PREROUTING -i $public_if -p tcp --dport 65524:65535 -j DNAT --to-destination 10.200.0.2 2>/dev/null || iptables -t nat -A PREROUTING -i $public_if -p tcp --dport 65524:65535 -j DNAT --to-destination 10.200.0.2
PostUp = iptables -t nat -C PREROUTING -i $public_if -p udp --dport 1:442 -j DNAT --to-destination 10.200.0.2 2>/dev/null || iptables -t nat -A PREROUTING -i $public_if -p udp --dport 1:442 -j DNAT --to-destination 10.200.0.2
PostUp = iptables -t nat -C PREROUTING -i $public_if -p udp --dport 444:65521 -j DNAT --to-destination 10.200.0.2 2>/dev/null || iptables -t nat -A PREROUTING -i $public_if -p udp --dport 444:65521 -j DNAT --to-destination 10.200.0.2
PostUp = iptables -t nat -C PREROUTING -i $public_if -p udp --dport 65524:65535 -j DNAT --to-destination 10.200.0.2 2>/dev/null || iptables -t nat -A PREROUTING -i $public_if -p udp --dport 65524:65535 -j DNAT --to-destination 10.200.0.2
PostDown = iptables -D INPUT -p udp --dport $WG_PORT -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i $WG_NAME -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -o $WG_NAME -j ACCEPT 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -o $WG_NAME -j MASQUERADE 2>/dev/null || true
PostDown = iptables -t nat -D PREROUTING -i $public_if -p tcp --dport 1:442 -j DNAT --to-destination 10.200.0.2 2>/dev/null || true
PostDown = iptables -t nat -D PREROUTING -i $public_if -p tcp --dport 444:65521 -j DNAT --to-destination 10.200.0.2 2>/dev/null || true
PostDown = iptables -t nat -D PREROUTING -i $public_if -p tcp --dport 65524:65535 -j DNAT --to-destination 10.200.0.2 2>/dev/null || true
PostDown = iptables -t nat -D PREROUTING -i $public_if -p udp --dport 1:442 -j DNAT --to-destination 10.200.0.2 2>/dev/null || true
PostDown = iptables -t nat -D PREROUTING -i $public_if -p udp --dport 444:65521 -j DNAT --to-destination 10.200.0.2 2>/dev/null || true
PostDown = iptables -t nat -D PREROUTING -i $public_if -p udp --dport 65524:65535 -j DNAT --to-destination 10.200.0.2 2>/dev/null || true

[Peer]
PublicKey = $WG_CLIENT_PUBKEY
AllowedIPs = $WG_SERVER_PEER_IP
PersistentKeepalive = $WG_KEEPALIVE
EOF

  systemctl enable wg-quick@${WG_NAME}
  systemctl restart wg-quick@${WG_NAME}
}

generate_gl_wg_client_conf() {
  local server_endpoint="$1"

  cat >"$GL_WG_CONF" <<EOF
[Interface]
Address = $WG_CLIENT_IP
PrivateKey = $WG_CLIENT_PRIVKEY
MTU = $WG_MTU

[Peer]
PublicKey = $WG_SERVER_PUBKEY
Endpoint = ${server_endpoint}:${WG_PORT}
AllowedIPs = 10.200.0.1/32
PersistentKeepalive = $WG_KEEPALIVE
EOF

  chmod 600 "$GL_WG_CONF"
}

generate_gl_xray_script() {
  local server_endpoint="$1"
  local uuid="$2"

  cat >"$GL_XRAY_SCRIPT" <<EOF
#!/bin/sh
set -eu

SERVER_ENDPOINT="$server_endpoint"
SERVER_PORT="$XRAY_PORT"
UUID="$uuid"

STATE_DIR="/etc/xray-client-bundle"
STATE_FILE="\$STATE_DIR/state.env"
WATCHDOG_SCRIPT="/root/xray_watchdog.sh"
WATCHDOG_INIT="/etc/init.d/xray-watchdog"

save_state() {
  mkdir -p "\$STATE_DIR"
  cat >"\$STATE_FILE" <<EOT
INSTALLED=1
SERVER_ENDPOINT="\$SERVER_ENDPOINT"
SERVER_PORT="\$SERVER_PORT"
UUID="\$UUID"
EOT
  chmod 600 "\$STATE_FILE"
}

load_state() {
  [ -s "\$STATE_FILE" ] || return 1
  # shellcheck disable=SC1090
  . "\$STATE_FILE"
  return 0
}

write_xray_config() {
  mkdir -p /etc/xray
  cat >/etc/xray/config.json <<'JSON'
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "tproxy-in",
      "port": 12345,
      "listen": "0.0.0.0",
      "protocol": "dokodemo-door",
      "settings": { "network": "tcp,udp", "followRedirect": true }
    },
    {
      "tag": "socks-in",
      "port": 1080,
      "listen": "0.0.0.0",
      "protocol": "socks",
      "settings": { "auth": "noauth", "udp": true }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "__SERVER_ENDPOINT__",
            "port": __SERVER_PORT__,
            "users": [
              { "id": "__UUID__", "encryption": "none", "level": 0 }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      }
    },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["tproxy-in", "socks-in"],
        "ip": ["geoip:private"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "inboundTag": ["tproxy-in", "socks-in"],
        "outboundTag": "proxy"
      }
    ]
  }
}
JSON

  sed -i "s#__SERVER_ENDPOINT__#\$SERVER_ENDPOINT#g" /etc/xray/config.json
  sed -i "s#__SERVER_PORT__#\$SERVER_PORT#g" /etc/xray/config.json
  sed -i "s#__UUID__#\$UUID#g" /etc/xray/config.json
}

configure_xray_uci() {
  cat >/etc/config/xray <<'UCIEOF'
config enabled 'enabled'
	option enabled '1'

config config 'config'
	option datadir '/usr/share/xray'
	list conffiles '/etc/xray/config.json'
	option format 'json'
UCIEOF
}

write_firewall_user() {
  cat >/etc/firewall.user <<'FW'
#!/bin/sh
VPS_IP="__VPS_IP__"
LAN_IF="br-lan"
TPORT="12345"

ip rule add fwmark 1 table 100 2>/dev/null
ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null

iptables -t nat -N XRAY 2>/dev/null
iptables -t nat -F XRAY
for NET in \
  0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 \
  172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4 "\$VPS_IP"/32; do
  iptables -t nat -A XRAY -d "\$NET" -j RETURN
done
iptables -t nat -A XRAY -p tcp -j REDIRECT --to-ports "\$TPORT"
iptables -t nat -D PREROUTING -i "\$LAN_IF" -p tcp -j XRAY 2>/dev/null
iptables -t nat -A PREROUTING -i "\$LAN_IF" -p tcp -j XRAY

iptables -t mangle -N XRAY_MASK 2>/dev/null
iptables -t mangle -F XRAY_MASK
for NET in \
  0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 \
  172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4 "\$VPS_IP"/32; do
  iptables -t mangle -A XRAY_MASK -d "\$NET" -j RETURN
done
iptables -t mangle -A XRAY_MASK -p udp -j TPROXY --on-port "\$TPORT" --tproxy-mark 0x1/0x1
iptables -t mangle -D PREROUTING -i "\$LAN_IF" -p udp -j XRAY_MASK 2>/dev/null
iptables -t mangle -A PREROUTING -i "\$LAN_IF" -p udp -j XRAY_MASK
FW
  sed -i "s#__VPS_IP__#\$SERVER_ENDPOINT#g" /etc/firewall.user
  chmod 700 /etc/firewall.user
}

write_watchdog_files() {
  cat >"\$WATCHDOG_SCRIPT" <<'WDOG'
#!/bin/sh
set -eu

STATE_FILE=/tmp/xray-watchdog.state
LOCK_DIR=/tmp/xray-watchdog.lock
LOG_FILE=/tmp/xray-watchdog.log
GRACE_SECONDS=60
FAIL_THRESHOLD=4
SUCCESS_THRESHOLD=2
SOCKS_TIMEOUT=8
SOCKS_URL=https://api.ipify.org
LAN_IF=br-lan

log() {
  printf '%s %s\n' "\$(date '+%F %T')" "\$1" >> "\$LOG_FILE"
}

proxy_rules_present() {
  iptables -t nat -S PREROUTING 2>/dev/null | grep -q -- "-i \$LAN_IF -p tcp -j XRAY" && \
  iptables -t mangle -S PREROUTING 2>/dev/null | grep -q -- "-i \$LAN_IF -p udp -j XRAY_MASK"
}

enable_proxy_rules() {
  /etc/firewall.user >/dev/null 2>&1 || true
  /etc/init.d/firewall restart >/dev/null 2>&1 || true
}

disable_proxy_rules() {
  iptables -t nat -D PREROUTING -i "\$LAN_IF" -p tcp -j XRAY 2>/dev/null || true
  iptables -t mangle -D PREROUTING -i "\$LAN_IF" -p udp -j XRAY_MASK 2>/dev/null || true
}

load_state() {
  if [ -f "\$STATE_FILE" ]; then
    . "\$STATE_FILE"
  else
    FAIL_COUNT=0
    OK_COUNT=0
    MODE=unknown
    STARTED_AT=\$(date +%s)
  fi
}

save_state_file() {
  cat >"\$STATE_FILE" <<EOT
FAIL_COUNT=\${FAIL_COUNT:-0}
OK_COUNT=\${OK_COUNT:-0}
MODE=\${MODE:-unknown}
STARTED_AT=\${STARTED_AT:-\$(date +%s)}
EOT
}

health_ok() {
  pidof xray >/dev/null 2>&1 || return 1
  curl -sS --max-time "\$SOCKS_TIMEOUT" --socks5-hostname 127.0.0.1:1080 "\$SOCKS_URL" >/dev/null 2>&1
}

mkdir "\$LOCK_DIR" 2>/dev/null || exit 0
trap 'rmdir "\$LOCK_DIR"' EXIT INT TERM

load_state
NOW=\$(date +%s)
if [ \$((NOW - STARTED_AT)) -lt "\$GRACE_SECONDS" ]; then
  save_state_file
  exit 0
fi

if health_ok; then
  FAIL_COUNT=0
  OK_COUNT=\$((OK_COUNT + 1))
  if [ "\$MODE" != "proxy_on" ] && [ "\$OK_COUNT" -ge "\$SUCCESS_THRESHOLD" ]; then
    enable_proxy_rules
    MODE=proxy_on
    log 'proxy_on'
  fi
else
  OK_COUNT=0
  FAIL_COUNT=\$((FAIL_COUNT + 1))
  if [ "\$MODE" != "proxy_off" ] && [ "\$FAIL_COUNT" -ge "\$FAIL_THRESHOLD" ]; then
    disable_proxy_rules
    MODE=proxy_off
    log 'proxy_off'
  fi
fi

if [ "\$MODE" = "unknown" ]; then
  if proxy_rules_present; then
    MODE=proxy_on
  else
    MODE=proxy_off
  fi
fi

save_state_file
WDOG
  chmod 700 "\$WATCHDOG_SCRIPT"

  cat >"\$WATCHDOG_INIT" <<'PROCD'
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=99

start_service() {
  procd_open_instance
  procd_set_param command /bin/sh -c 'while true; do /root/xray_watchdog.sh; sleep 15; done'
  procd_set_param respawn
  procd_close_instance
}
PROCD
  chmod 755 "\$WATCHDOG_INIT"
}

xray_start_safe() {
  /etc/init.d/xray enable >/dev/null 2>&1 || true
  /etc/init.d/xray restart >/dev/null 2>&1 || {
    /etc/init.d/xray stop >/dev/null 2>&1 || true
    /etc/init.d/xray start >/dev/null 2>&1 || true
  }
}

clear_transparent_rules() {
  iptables -t nat -D PREROUTING -i br-lan -p tcp -j XRAY 2>/dev/null || true
  iptables -t mangle -D PREROUTING -i br-lan -p udp -j XRAY_MASK 2>/dev/null || true
  iptables -t nat -F XRAY 2>/dev/null || true
  iptables -t nat -X XRAY 2>/dev/null || true
  iptables -t mangle -F XRAY_MASK 2>/dev/null || true
  iptables -t mangle -X XRAY_MASK 2>/dev/null || true
  ip rule del fwmark 1 table 100 2>/dev/null || true
  ip route flush table 100 2>/dev/null || true
}

start_tunnel() {
  xray_start_safe
  /etc/init.d/firewall restart >/dev/null 2>&1 || true
  echo "[OK] Tunnel avviato."
}

stop_tunnel() {
  /etc/init.d/xray stop >/dev/null 2>&1 || true
  clear_transparent_rules
  echo "[OK] Tunnel fermato."
}

restart_tunnel() {
  xray_start_safe
  /etc/init.d/firewall restart >/dev/null 2>&1 || true
  echo "[OK] Tunnel riavviato."
}

toggle_tunnel() {
  if pidof xray >/dev/null 2>&1; then
    stop_tunnel
  else
    start_tunnel
  fi
}

show_status() {
  echo
  echo "=== CLIENT STATUS ==="
  if pidof xray >/dev/null 2>&1; then
    echo "xray: running (pid: \$(pidof xray))"
  else
    echo "xray: stopped"
  fi
  if iptables -t nat -S PREROUTING 2>/dev/null | grep -q -- "-i br-lan -p tcp -j XRAY"; then
    echo "transparent tcp: ON"
  else
    echo "transparent tcp: OFF"
  fi
  if iptables -t mangle -S PREROUTING 2>/dev/null | grep -q -- "-i br-lan -p udp -j XRAY_MASK"; then
    echo "transparent udp: ON"
  else
    echo "transparent udp: OFF"
  fi
  if [ -x "\$WATCHDOG_INIT" ]; then
    echo "watchdog: $(/etc/init.d/xray-watchdog status 2>/dev/null || echo unknown)"
  fi
  echo "server endpoint: \$SERVER_ENDPOINT"
  echo -n "socks test ip: "
  curl -sS --max-time 12 --socks5-hostname 127.0.0.1:1080 https://api.ipify.org || echo "failed"
  echo
}

install_mode() {
  opkg update
  opkg install xray-core xray-geodata ca-bundle curl
  write_xray_config
  configure_xray_uci
  write_firewall_user
  write_watchdog_files
  /usr/bin/xray run -test -config /etc/xray/config.json
  start_tunnel
  /etc/init.d/xray-watchdog enable >/dev/null 2>&1 || true
  /etc/init.d/xray-watchdog start >/dev/null 2>&1 || true
  save_state
  echo "Setup GL.iNet completato."
  echo "SOCKS test: curl --socks5-hostname 127.0.0.1:1080 https://api.ipify.org"
}

cleanup_mode() {
  echo "[ATTENZIONE] Questa azione rimuove xray, config e regole transparent dal router."
  printf "Scrivi CLEANCLIENT per confermare: "
  read -r token
  [ "\$token" = "CLEANCLIENT" ] || { echo "[ABORT] Conferma errata."; return; }

  /etc/init.d/xray stop >/dev/null 2>&1 || true
  /etc/init.d/xray disable >/dev/null 2>&1 || true
  /etc/init.d/xray-watchdog stop >/dev/null 2>&1 || true
  /etc/init.d/xray-watchdog disable >/dev/null 2>&1 || true
  killall xray >/dev/null 2>&1 || true
  clear_transparent_rules

  opkg remove xray-geodata xray-example xray-core >/dev/null 2>&1 || true
  rm -f /etc/config/xray /etc/xray/config.json
  rm -rf "\$STATE_DIR"
  rm -f "\$WATCHDOG_SCRIPT" "\$WATCHDOG_INIT"
  rm -f /tmp/xray-watchdog.state /tmp/xray-watchdog.log

  cat >/etc/firewall.user <<'FW'
#!/bin/sh
# local custom firewall rules
FW
  chmod 755 /etc/firewall.user
  /etc/init.d/firewall restart >/dev/null 2>&1 || true
  echo "[OK] Cleanup client completato."
}

control_panel() {
  while true; do
    echo
    echo "===== XRAY CLIENT PANEL ====="
    echo "1) Stato tunnel"
    echo "2) Start tunnel"
    echo "3) Stop tunnel"
    echo "4) Restart tunnel"
    echo "5) Toggle tunnel on/off"
    echo "6) Cleanup totale (rimuovi tutto)"
    echo "7) Reinstall/configura da zero"
    echo "8) Esci"
    printf "Seleziona [1-8]: "
    read -r opt
    case "\$opt" in
      1) show_status ;;
      2) start_tunnel ;;
      3) stop_tunnel ;;
      4) restart_tunnel ;;
      5) toggle_tunnel ;;
      6) cleanup_mode ;;
      7) install_mode ;;
      8) exit 0 ;;
      *) echo "Opzione non valida." ;;
    esac
  done
}

if load_state; then
  control_panel
else
  install_mode
fi
EOF

  chmod 700 "$GL_XRAY_SCRIPT"
}

show_online_peers() {
  echo "xray: $(systemctl is-active xray 2>/dev/null || true)"
  echo "wg:   $(systemctl is-active wg-quick@${WG_NAME} 2>/dev/null || true)"
  echo
  echo "Peer attivi su $XRAY_PORT (IP remoti):"
  if command -v ss >/dev/null 2>&1; then
    ss -Htn state established "( sport = :$XRAY_PORT )" \
      | awk '{print $5}' \
      | sed -E 's/^\[::ffff:([0-9.]+)\]:.*/\1/; s/^([0-9.]+):.*/\1/' \
      | sort | uniq -c | sort -nr || true
  else
    netstat -tn 2>/dev/null | awk '$4 ~ /:443$/ && $6 == "ESTABLISHED" {print $5}' | sed 's/:.*//' | sort | uniq -c | sort -nr || true
  fi

  echo
  echo "wireguard:"
  wg show "$WG_NAME" 2>/dev/null || true
}

restart_stack() {
  systemctl restart xray || true
  systemctl restart wg-quick@${WG_NAME} || true
  echo "[OK] Servizi riavviati."
}

show_current_config() {
  if ! load_state; then
    echo "[INFO] Stato non trovato."
    return
  fi

  echo "SERVER_ENDPOINT=$SERVER_ENDPOINT"
  echo "UUID=$UUID"
  echo "PUBLIC_IF=$PUBLIC_IF"
  echo "XRAY_PORT=$XRAY_PORT"
  echo "SSH_PORT=$SSH_PORT"
  echo "WG_PORT=$WG_PORT"
  echo "WG_NAME=$WG_NAME"
  echo "GL_XRAY_SCRIPT=$GL_XRAY_SCRIPT"
  echo "GL_WG_CONF=$GL_WG_CONF"
}

uninstall_everything() {
  if ! ask_yes_no "Confermi uninstall completo"; then
    return
  fi

  local token
  read -r -p "Scrivi CLEANALL per confermare: " token
  [[ "$token" == "CLEANALL" ]] || { echo "[ABORT] Conferma errata."; return; }

  systemctl disable --now wg-quick@${WG_NAME} 2>/dev/null || true
  systemctl disable --now xray 2>/dev/null || true

  rm -f /etc/wireguard/${WG_NAME}.conf
  rm -f /etc/wireguard/${WG_NAME}_server.key /etc/wireguard/${WG_NAME}_server.pub
  rm -f /etc/wireguard/${WG_NAME}_client.key /etc/wireguard/${WG_NAME}_client.pub
  rm -rf /usr/local/etc/xray
  rm -f "$GL_XRAY_SCRIPT" "$GL_WG_CONF"

  if [[ -x /usr/local/bin/xray ]]; then
    bash <(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh) remove || true
  fi

  apt-get purge -y iptables-persistent wireguard-tools >/dev/null 2>&1 || true
  apt-get autoremove -y >/dev/null 2>&1 || true

  iptables -D INPUT -p tcp --dport "$XRAY_PORT" -j ACCEPT 2>/dev/null || true
  iptables -D INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT 2>/dev/null || true
  netfilter-persistent save >/dev/null 2>&1 || true

  rm -rf "$STATE_DIR"
  systemctl daemon-reload
  echo "[OK] Cleanup completato."
}

control_panel() {
  while true; do
    echo
    echo "===== XRAY+WG CONTROL PANEL ====="
    echo "1) Peer online + IP"
    echo "2) Riavvia servizi"
    echo "3) Uninstall completo (clean all)"
    echo "4) Mostra configurazione"
    echo "5) Esci"
    read -r -p "Seleziona opzione [1-5]: " opt
    case "$opt" in
      1) show_online_peers ;;
      2) restart_stack ;;
      3) uninstall_everything ;;
      4) show_current_config ;;
      5) exit 0 ;;
      *) echo "Opzione non valida." ;;
    esac
  done
}

run_setup() {
  local uuid ssh_port

  check_environment
  install_base_packages
  ssh_port="$(configure_ssh_port_optional | tail -n 1)"
  install_custom_kernel_optional
  detect_public_if
  detect_public_ip

  uuid="$(cat /proc/sys/kernel/random/uuid)"

  install_xray_core
  configure_xray_server "$uuid"
  generate_wg_keys
  configure_wg_server "$PUBLIC_IF"

  iptables -C INPUT -p tcp --dport "$XRAY_PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$XRAY_PORT" -j ACCEPT
  netfilter-persistent save >/dev/null 2>&1 || true

  generate_gl_xray_script "$SERVER_ENDPOINT" "$uuid"
  generate_gl_wg_client_conf "$SERVER_ENDPOINT"
  save_state "$SERVER_ENDPOINT" "$uuid" "$ssh_port" "$PUBLIC_IF" "$WG_CLIENT_PUBKEY"

  echo
  echo "========== COMPLETATO =========="
  echo "Endpoint VPS  : $SERVER_ENDPOINT"
  echo "UUID VLESS    : $uuid"
  echo "Xray port     : $XRAY_PORT/tcp"
  echo "SSH port      : $ssh_port/tcp"
  echo "WG port       : $WG_PORT/udp"
  echo "Public IF     : $PUBLIC_IF"
  echo "WG peer IP    : 10.200.0.2"
  echo "PF ranges TCP/UDP: 1-442, 444-65521, 65524-65535"
  echo "Xray client   : $GL_XRAY_SCRIPT"
  echo "WG client conf: $GL_WG_CONF"
}

main() {
  if load_state && [[ "${INSTALLED:-0}" == "1" ]]; then
    control_panel
  else
    run_setup
  fi
}

main "$@"
