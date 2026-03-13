#!/usr/bin/env bash
# Marat Davletshin
#
# vpn_lab_helper.sh
#
# Назначение:
#   Интерактивный помощник для лабораторной по VPN (WireGuard + OpenVPN + Wireshark).
#
# Что умеет:
#   - показывает IP-адреса, интерфейсы и маршруты
#   - сохраняет важные значения в lab_state.env
#   - устанавливает пакеты
#   - помогает настроить gateway DNAT для Wireshark sshdump
#   - готовит PC1 для remote capture
#   - генерирует ключи WireGuard
#   - создает WireGuard/OpenVPN-конфиги
#   - при желании копирует их в системные каталоги с backup'ом
#   - поднимает/опускает WireGuard
#   - запускает OpenVPN
#   - выполняет MTU и throughput тесты
#   - создает шпаргалку для протокола
#   - умеет откатывать назад изменения, которые внес сам
#
# Ключевые принципы безопасности:
#   1) Скрипт НЕ угадывает IP и интерфейсы. Он только помогает и спрашивает данные.
#   2) Перед заменой системных файлов делает backup.
#   3) Перед изменением iptables делает backup.
#   4) Умеет откатывать назад свои изменения.
#   5) Не требует Python: только стандартные утилиты bash/Linux.
#
# Ограничения:
#   - Я не могу здесь проверить реальные сетевые сценарии на ваших стендах.
#   - Поэтому сетевые шаги нужно выполнять внимательно и смотреть, на каком хосте ты сейчас находишься.
#   - Запуск openvpn/iperf3 server в foreground естественно блокирует меню, пока процесс работает.
#
# Локальные файлы скрипта:
#   logs/              - логи команд и измерений
#   generated_configs/ - локально сгенерированные конфиги и ключи
#   backups/           - backup'ы системных файлов и iptables
#   lab_state.env      - сохраненные значения (IP, пути к backup'ам и т.д.)

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
CONF_DIR="$SCRIPT_DIR/generated_configs"
BACKUP_DIR="$SCRIPT_DIR/backups"
STATE_FILE="$SCRIPT_DIR/lab_state.env"

mkdir -p "$LOG_DIR" "$CONF_DIR" "$BACKUP_DIR"

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

file_stamp() {
  date '+%Y%m%d_%H%M%S_%N'
}

log() {
  printf '[%s] %s
' "$(timestamp)" "$*"
}

prompt() {
  # Prompt всегда в STDERR, чтобы его текст не попадал в переменные при var="$(func)".
  printf '%s' "$*" >&2
}

pause() {
  prompt '
Нажми Enter, чтобы продолжить... '
  read -r _
}

safe_clear() {
  if [ -t 1 ] && [ -n "${TERM:-}" ]; then
    clear 2>/dev/null || true
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_sudo() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo
    echo "Этот шаг требует root/sudo."
    echo "Перезапусти скрипт так: sudo bash vpn_lab_helper.sh"
    echo
    return 1
  fi
  return 0
}

ask_default() {
  # Возвращает ТОЛЬКО ответ в stdout.
  local prompt_text="$1"
  local default_value="${2:-}"
  local answer

  if [ -n "$default_value" ]; then
    prompt "${prompt_text} [${default_value}]: "
  else
    prompt "${prompt_text}: "
  fi

  read -r answer
  if [ -z "$answer" ]; then
    answer="$default_value"
  fi
  printf '%s' "$answer"
}

ask_yes_no() {
  local prompt_text="$1"
  local default_value="${2:-no}"
  local answer

  while true; do
    answer="$(ask_default "${prompt_text} (yes/no)" "$default_value")"
    case "$answer" in
      yes|no)
        printf '%s' "$answer"
        return 0
        ;;
      *)
        echo "Введи yes или no." >&2
        ;;
    esac
  done
}

save_var() {
  # Без sed/python: безопасная перезапись STATE_FILE через временный файл.
  local key="$1"
  local value="$2"
  local tmp_file
  local found=0
  local quoted

  touch "$STATE_FILE"
  tmp_file="$(mktemp)"
  printf -v quoted '%q' "$value"

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == "${key}="* ]]; then
      printf '%s=%s
' "$key" "$quoted" >> "$tmp_file"
      found=1
    else
      printf '%s
' "$line" >> "$tmp_file"
    fi
  done < "$STATE_FILE"

  if [ "$found" -eq 0 ]; then
    printf '%s=%s
' "$key" "$quoted" >> "$tmp_file"
  fi

  mv "$tmp_file" "$STATE_FILE"
}

clear_var() {
  local key="$1"
  local tmp_file

  touch "$STATE_FILE"
  tmp_file="$(mktemp)"

  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" != "${key}="* ]]; then
      printf '%s
' "$line" >> "$tmp_file"
    fi
  done < "$STATE_FILE"

  mv "$tmp_file" "$STATE_FILE"
}

load_state() {
  # shellcheck disable=SC1090
  if [ -f "$STATE_FILE" ]; then
    . "$STATE_FILE"
  fi
}

show_saved_state() {
  echo
  echo "Сохраненные значения:"
  if [ -f "$STATE_FILE" ]; then
    cat "$STATE_FILE"
  else
    echo "Пока ничего не сохранено."
  fi
  echo
}

run_and_log() {
  local name="$1"
  shift
  local logfile="$LOG_DIR/${name}_$(file_stamp).log"

  log "Запуск: $*"
  log "Лог-файл: $logfile"
  {
    echo "===== $(timestamp) ====="
    echo "COMMAND: $*"
    echo
    "$@"
  } 2>&1 | tee "$logfile"
}

print_section() {
  echo
  echo "------------------------------------------------------------"
  echo "$*"
  echo "------------------------------------------------------------"
}

backup_path_for() {
  local target="$1"
  local label="$2"
  local base
  base="$(basename "$target")"
  printf '%s/%s_%s_%s.bak' "$BACKUP_DIR" "$label" "$base" "$(file_stamp)"
}

backup_file_if_exists() {
  local target="$1"
  local label="$2"

  if [ -e "$target" ]; then
    local backup
    backup="$(backup_path_for "$target" "$label")"
    cp -a "$target" "$backup"
    printf '%s' "$backup"
  fi
}

copy_with_backup() {
  # copy_with_backup SOURCE TARGET BACKUP_VAR MANAGED_VAR MODE
  local source_file="$1"
  local target_file="$2"
  local backup_var="$3"
  local managed_var="$4"
  local mode="${5:-}"

  local backup
  backup="$(backup_file_if_exists "$target_file" "$managed_var")"

  if [ -n "${backup:-}" ]; then
    save_var "$backup_var" "$backup"
  else
    clear_var "$backup_var"
  fi

  mkdir -p "$(dirname "$target_file")"
  cp "$source_file" "$target_file"

  if [ -n "$mode" ]; then
    chmod "$mode" "$target_file"
  fi

  save_var "$managed_var" "yes"

  echo "Скопировано: $target_file"
  if [ -n "${backup:-}" ]; then
    echo "Backup сохранен: $backup"
  else
    echo "Предыдущего файла не было. При rollback файл будет удален."
  fi
}

restore_or_remove_managed_file() {
  # restore_or_remove_managed_file TARGET BACKUP_VAR MANAGED_VAR MODE_IF_RESTORED
  local target_file="$1"
  local backup_var="$2"
  local managed_var="$3"
  local mode_if_restored="${4:-}"

  load_state

  local backup_path=""
  local managed=""

  eval "backup_path=\${$backup_var:-}"
  eval "managed=\${$managed_var:-}"

  if [ "${managed:-no}" != "yes" ]; then
    echo "Файл $target_file не отмечен как измененный этим скриптом. Пропускаю."
    return 0
  fi

  if [ -n "${backup_path:-}" ] && [ -e "$backup_path" ]; then
    mkdir -p "$(dirname "$target_file")"
    cp -a "$backup_path" "$target_file"
    if [ -n "$mode_if_restored" ]; then
      chmod "$mode_if_restored" "$target_file"
    fi
    echo "Восстановлен backup для $target_file из $backup_path"
  else
    rm -f "$target_file"
    echo "Backup для $target_file не найден. Файл удален."
  fi

  save_var "$managed_var" "no"
}

# -----------------------------------------------------------------------------
# Общие шаги
# -----------------------------------------------------------------------------

step_show_network_info() {
  run_and_log "network_info" bash -c '
    echo "HOSTNAME:"
    hostname
    echo
    echo "IP ADDRESS:"
    ip a
    echo
    echo "ROUTES:"
    ip route
    echo
    echo "LISTENING PORTS:"
    ss -tulpn || true
  '

  echo
  echo "Теперь можно сохранить важные адреса в состояние лабы."

  local host_role
  host_role="$(ask_default "Роль этого хоста (gateway/pc1/pc2/other)" "${HOST_ROLE:-other}")"
  save_var HOST_ROLE "$host_role"

  local physical_if
  physical_if="$(ask_default "Физический интерфейс этого хоста (например ens18)" "${PHYSICAL_IF:-}")"
  save_var PHYSICAL_IF "$physical_if"

  local lan_ip
  lan_ip="$(ask_default "LAN IP этого хоста" "${LAN_IP:-}")"
  save_var LAN_IP "$lan_ip"

  local gw_ext_ip
  gw_ext_ip="$(ask_default "Внешний IP gateway (если уже известен)" "${GW_EXT_IP:-}")"
  [ -n "$gw_ext_ip" ] && save_var GW_EXT_IP "$gw_ext_ip"

  local pc1_lan_ip
  pc1_lan_ip="$(ask_default "IP PC1 (если уже известен)" "${PC1_LAN_IP:-}")"
  [ -n "$pc1_lan_ip" ] && save_var PC1_LAN_IP "$pc1_lan_ip"

  local pc2_lan_ip
  pc2_lan_ip="$(ask_default "IP PC2 (если уже известен)" "${PC2_LAN_IP:-}")"
  [ -n "$pc2_lan_ip" ] && save_var PC2_LAN_IP "$pc2_lan_ip"

  echo
  echo "Данные сохранены в: $STATE_FILE"
  pause
}

step_install_packages() {
  require_sudo || return

  echo
  echo "Что установить?"
  echo "1) Базовый набор для PC1/PC2 (wireguard, openvpn, tcpdump, iperf3)"
  echo "2) Только SSH server + tcpdump (для PC1)"
  echo "3) Все сразу"
  prompt 'Выбор: '
  read -r choice

  case "$choice" in
    1)
      run_and_log "install_base_packages_update" apt update
      run_and_log "install_base_packages_install" apt install -y wireguard openvpn tcpdump iperf3
      ;;
    2)
      run_and_log "install_ssh_tcpdump_update" apt update
      run_and_log "install_ssh_tcpdump_install" apt install -y openssh-server tcpdump
      run_and_log "enable_ssh" systemctl enable --now ssh
      ;;
    3)
      run_and_log "install_all_packages_update" apt update
      run_and_log "install_all_packages_install" apt install -y wireguard openvpn tcpdump iperf3 openssh-server
      run_and_log "enable_ssh" systemctl enable --now ssh
      ;;
    *)
      echo "Неверный выбор."
      ;;
  esac

  pause
}

step_basic_ping() {
  echo
  local target
  target="$(ask_default "IP назначения для ping" "")"

  if [ -z "$target" ]; then
    echo "IP обязателен."
    pause
    return
  fi

  run_and_log "basic_ping" ping -c 4 "$target"
  pause
}

step_capture_help() {
  load_state

  echo
  echo "Команды для ручного захвата трафика:"
  echo
  echo "Снаружи туннеля (обычно physical NIC):"
  echo "  sudo tcpdump -i ${PHYSICAL_IF:-ens18} -n"
  echo
  echo "Внутри WireGuard:"
  echo "  sudo tcpdump -i wg0 -n"
  echo
  echo "Внутри OpenVPN:"
  echo "  sudo tcpdump -i tun0 -n"
  echo
  echo "Для WireGuard только внешний UDP-трафик:"
  echo "  sudo tcpdump -i ${PHYSICAL_IF:-ens18} -n udp port 51820"
  echo
  echo "Для OpenVPN только внешний UDP-трафик:"
  echo "  sudo tcpdump -i ${PHYSICAL_IF:-ens18} -n udp port 1194"
  echo
  echo "Wireshark remote capture:"
  echo "  - SSH remote capture: sshdump"
  echo "  - Server: ${GW_EXT_IP:-<Gateway IP>}"
  echo "  - Port: 22"
  echo "  - Username: csdc"
  echo "  - Remote interface: ${PHYSICAL_IF:-ens18}, wg0 или tun0"
  echo "  - Capture filter: not port 22"
  echo

  pause
}

step_mtu_tests() {
  echo
  echo "Этот шаг запускает ping с фиксированными payload size и сохраняет вывод в лог."
  echo "Полезно для раздела MTU & Fragmentation."
  echo

  local target
  target="$(ask_default "IP назначения (LAN / WG / OpenVPN)" "")"

  if [ -z "$target" ]; then
    echo "IP назначения обязателен."
    pause
    return
  fi

  local sizes="500 1400 1450 1500 1550"
  local logfile="$LOG_DIR/mtu_test_$(file_stamp).log"

  {
    echo "===== $(timestamp) ====="
    echo "TARGET: $target"
    echo
    for s in $sizes; do
      echo "----- SIZE=$s -----"
      ping -M do -s "$s" -c 2 "$target" || true
      echo
    done
  } 2>&1 | tee "$logfile"

  echo
  echo "Лог сохранен: $logfile"
  pause
}

step_find_mtu_limit() {
  echo

  local target start end step
  target="$(ask_default "IP назначения" "")"
  start="$(ask_default "Начальный payload size" "1300")"
  end="$(ask_default "Конечный payload size" "1470")"
  step="$(ask_default "Шаг" "10")"

  if [ -z "$target" ]; then
    echo "IP назначения обязателен."
    pause
    return
  fi

  if ! [[ "$start" =~ ^[0-9]+$ && "$end" =~ ^[0-9]+$ && "$step" =~ ^[0-9]+$ ]]; then
    echo "start/end/step должны быть числами."
    pause
    return
  fi

  if [ "$step" -le 0 ]; then
    echo "Шаг должен быть > 0."
    pause
    return
  fi

  local logfile="$LOG_DIR/mtu_limit_$(file_stamp).log"
  {
    echo "===== $(timestamp) ====="
    echo "TARGET: $target"
    echo "RANGE: $start..$end step $step"
    echo
    local s
    s="$start"
    while [ "$s" -le "$end" ]; do
      echo "----- SIZE=$s -----"
      ping -M do -s "$s" -c 1 "$target" || true
      echo
      s=$((s + step))
    done
  } 2>&1 | tee "$logfile"

  echo
  echo "Лог сохранен: $logfile"
  pause
}

step_iperf_tests() {
  echo
  echo "1) Запустить iperf3 server"
  echo "2) Запустить iperf3 client (обычный TCP тест)"
  echo "3) Запустить iperf3 client с разными -l"
  echo "4) Запустить UDP тест"
  prompt 'Выбор: '
  read -r choice

  case "$choice" in
    1)
      run_and_log "iperf_server" iperf3 -s
      ;;
    2)
      local target
      target="$(ask_default "IP сервера iperf3" "")"
      [ -z "$target" ] && echo "Нужен IP." && pause && return
      run_and_log "iperf_client_tcp" iperf3 -c "$target"
      ;;
    3)
      local target2
      target2="$(ask_default "IP сервера iperf3" "")"
      [ -z "$target2" ] && echo "Нужен IP." && pause && return
      local logfile="$LOG_DIR/iperf_sizes_$(file_stamp).log"
      {
        echo "===== $(timestamp) ====="
        echo "TARGET: $target2"
        echo
        for len in 512 1400 8000; do
          echo "----- LENGTH=$len -----"
          iperf3 -c "$target2" -l "$len" || true
          echo
        done
      } 2>&1 | tee "$logfile"
      echo "Лог сохранен: $logfile"
      ;;
    4)
      local target3 bandwidth
      target3="$(ask_default "IP сервера iperf3" "")"
      bandwidth="$(ask_default "UDP bandwidth (например 100M)" "100M")"
      [ -z "$target3" ] && echo "Нужен IP." && pause && return
      run_and_log "iperf_udp" iperf3 -u -c "$target3" -b "$bandwidth"
      ;;
    *)
      echo "Неверный выбор."
      ;;
  esac

  pause
}

step_protocol_notes() {
  local notes_file="$LOG_DIR/protocol_notes.txt"

  cat > "$notes_file" <<'EOF'
Шпаргалка для заполнения протокола:

1. WireGuard Traffic Observation
- Physical Interface:
  Encrypted UDP packets between the peers are visible.
- wg0 Interface:
  The original ICMP/IP packets are visible in decrypted form.

2. Difference between interfaces
- On the physical interface only encrypted tunnel traffic can be seen.
- On wg0 the inner packets are visible after decryption.

3. OpenVPN typical choices
- Mode: tun
- Protocol: udp
- Authentication: PSK (if static key is used)

4. OpenVPN reason
- Tun mode is sufficient for routed IP traffic.
- UDP was chosen for lower overhead and better performance in the lab.
- PSK is easier to configure quickly in a lab setting.

5. Comparison
- WireGuard: easier setup, better performance, lower overhead.
- OpenVPN: more complex setup, lower performance, higher overhead.

6. Conclusion example
- WireGuard was easier to configure and provided better throughput.
- OpenVPN worked reliably but introduced more overhead.
- Traffic captures showed encrypted packets on the physical interface and decrypted traffic on the tunnel interface.
- Fragmentation appeared earlier when VPN encapsulation was used.
EOF

  echo
  echo "Памятка сохранена в: $notes_file"
  cat "$notes_file"
  echo

  pause
}

# -----------------------------------------------------------------------------
# Gateway
# -----------------------------------------------------------------------------

step_gateway_dnat() {
  require_sudo || return
  load_state

  print_section "Этот шаг выполняется на GATEWAY. Добавляется DNAT: SSH на gateway -> PC1:22"

  local gw_ext_ip pc1_lan_ip
  gw_ext_ip="$(ask_default "Внешний IP gateway" "${GW_EXT_IP:-}")"
  pc1_lan_ip="$(ask_default "LAN IP PC1" "${PC1_LAN_IP:-}")"

  if [ -z "$gw_ext_ip" ] || [ -z "$pc1_lan_ip" ]; then
    echo "Нужно указать оба адреса."
    pause
    return
  fi

  save_var GW_EXT_IP "$gw_ext_ip"
  save_var PC1_LAN_IP "$pc1_lan_ip"

  if ! command_exists iptables || ! command_exists iptables-save || ! command_exists iptables-restore; then
    echo "Нужны команды iptables / iptables-save / iptables-restore."
    pause
    return
  fi

  local ip_forward_before
  ip_forward_before="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "unknown")"
  save_var IP_FORWARD_BEFORE_DNAT "$ip_forward_before"

  local backup_rules
  backup_rules="$BACKUP_DIR/iptables_before_dnat_$(file_stamp).rules"
  iptables-save > "$backup_rules"
  save_var LAST_IPTABLES_BACKUP "$backup_rules"
  echo "Backup iptables сохранен: $backup_rules"

  run_and_log "enable_ip_forward" sysctl -w net.ipv4.ip_forward=1

  if iptables -t nat -C PREROUTING -p tcp -d "$gw_ext_ip" --dport 22 -j DNAT --to-destination "${pc1_lan_ip}:22" 2>/dev/null; then
    echo "Такое DNAT-правило уже существует. Повторно не добавляю."
  else
    run_and_log "gateway_dnat_add" iptables -t nat -A PREROUTING -p tcp -d "$gw_ext_ip" --dport 22 -j DNAT --to-destination "${pc1_lan_ip}:22"
  fi

  run_and_log "gateway_nat_rules" iptables -t nat -L -n -v

  echo
  echo "Замечание:"
  echo "- Этот шаг делает только то, что было в вашем гайде: DNAT + ip_forward."
  echo "- Если в стенде есть отдельные жесткие правила FORWARD, их придется проверять отдельно."
  pause
}

# -----------------------------------------------------------------------------
# PC1 capture
# -----------------------------------------------------------------------------

step_prepare_pc1_capture() {
  require_sudo || return

  print_section "Этот шаг выполняется на PC1. Он проверяет SSH и дает tcpdump права для захвата без root."

  run_and_log "check_ssh_status" systemctl status ssh --no-pager || true

  if ! command_exists tcpdump; then
    run_and_log "install_tcpdump_update" apt update
    run_and_log "install_tcpdump_install" apt install -y tcpdump
  fi

  local tcpdump_path
  tcpdump_path="$(command -v tcpdump)"

  local current_caps raw_caps
  current_caps="$(getcap "$tcpdump_path" 2>/dev/null || true)"
  raw_caps="${current_caps#* }"
  if [ "$raw_caps" = "$current_caps" ]; then
    raw_caps=""
  fi
  save_var TCPDUMP_CAPS_BEFORE "$raw_caps"

  # В твоем гайде указан cap_net_raw.
  # Практически на некоторых системах tcpdump может потребовать и cap_net_admin
  # для корректной работы с интерфейсом/promiscuous mode.
  run_and_log "setcap_tcpdump" setcap cap_net_admin,cap_net_raw=eip "$tcpdump_path"
  run_and_log "getcap_tcpdump" getcap "$tcpdump_path"

  save_var TCPDUMP_CAPS_MANAGED "yes"

  echo
  echo "Wireshark remote capture settings:"
  echo "- Interface: SSH remote capture: sshdump"
  echo "- Server: <Gateway IP>"
  echo "- Port: 22"
  echo "- Username: csdc"
  echo "- Remote interface: ens18 или другой нужный интерфейс"
  echo "- Capture filter: not port 22"
  pause
}

# -----------------------------------------------------------------------------
# WireGuard
# -----------------------------------------------------------------------------

step_generate_wg_keys() {
  print_section "Генерация ключей WireGuard"

  if ! command_exists wg; then
    echo "Команда wg не найдена. Установи пакет wireguard."
    pause
    return
  fi

  local prefix
  prefix="$(ask_default "Префикс имени ключей (например pc1 или pc2)" "wg")"

  umask 077
  local priv="$CONF_DIR/${prefix}_wg_private.key"
  local pub="$CONF_DIR/${prefix}_wg_public.key"

  wg genkey | tee "$priv" | wg pubkey > "$pub"

  echo
  echo "Private key: $priv"
  echo "Public key : $pub"
  echo
  echo "Содержимое public key:"
  cat "$pub"
  echo
  echo "Private key никому не отправляй. Public key вставляется в peer-конфиг другой машины."
  pause
}

step_create_wg_config() {
  load_state

  print_section "Создание WireGuard-конфига"

  local role
  role="$(ask_default "Роль этого конфига (pc1/pc2)" "${HOST_ROLE:-pc1}")"

  local wg_local_ip
  local wg_local_cidr
  local listen_port
  local private_key
  local peer_public_key
  local peer_ip
  local endpoint_host

  wg_local_ip="$(ask_default "Локальный WG IP (например 10.10.10.1)" "")"
  wg_local_cidr="$(ask_default "Префикс сети (например 24)" "24")"
  listen_port="$(ask_default "ListenPort" "51820")"
  private_key="$(ask_default "PrivateKey (вставь содержимое private key)" "")"
  peer_public_key="$(ask_default "PublicKey peer" "")"
  peer_ip="$(ask_default "WG IP peer без CIDR (например 10.10.10.2)" "")"
  endpoint_host="$(ask_default "Endpoint peer (обычно LAN IP peer)" "")"

  if [ -z "$wg_local_ip" ] || [ -z "$private_key" ] || [ -z "$peer_public_key" ] || [ -z "$peer_ip" ] || [ -z "$endpoint_host" ]; then
    echo "Не все поля заполнены."
    pause
    return
  fi

  local outfile="$CONF_DIR/${role}_wg0.conf"
  cat > "$outfile" <<EOF
[Interface]
Address = ${wg_local_ip}/${wg_local_cidr}
PrivateKey = ${private_key}
ListenPort = ${listen_port}

[Peer]
PublicKey = ${peer_public_key}
AllowedIPs = ${peer_ip}/32
Endpoint = ${endpoint_host}:${listen_port}
PersistentKeepalive = 25
EOF

  chmod 600 "$outfile"

  echo
  echo "Локальный конфиг создан: $outfile"
  echo "----------------------------------------"
  cat "$outfile"
  echo "----------------------------------------"

  local copy_now
  copy_now="$(ask_yes_no "Скопировать в /etc/wireguard/wg0.conf сейчас?" "no")"
  if [ "$copy_now" = "yes" ]; then
    require_sudo || return
    copy_with_backup "$outfile" "/etc/wireguard/wg0.conf" "WG_CONF_BACKUP" "WG_CONF_MANAGED" "600"
  fi

  pause
}

step_manage_wg() {
  require_sudo || return

  echo
  echo "1) Поднять wg0"
  echo "2) Остановить wg0"
  echo "3) Показать состояние wg0"
  prompt 'Выбор: '
  read -r choice

  case "$choice" in
    1)
      run_and_log "wg_up" wg-quick up wg0
      run_and_log "wg_status_after_up" bash -c 'ip a show wg0; echo; wg'
      ;;
    2)
      run_and_log "wg_down" wg-quick down wg0
      ;;
    3)
      run_and_log "wg_status" bash -c 'ip a show wg0; echo; wg'
      ;;
    *)
      echo "Неверный выбор."
      ;;
  esac

  pause
}

# -----------------------------------------------------------------------------
# OpenVPN
# -----------------------------------------------------------------------------

step_openvpn_key() {
  print_section "Генерация или импорт static key для OpenVPN"

  echo "1) Сгенерировать новый static key"
  echo "2) Сохранить уже существующий key из буфера"
  prompt 'Выбор: '
  read -r choice

  local outfile="$CONF_DIR/openvpn_static.key"

  case "$choice" in
    1)
      if ! command_exists openvpn; then
        echo "Команда openvpn не найдена. Установи пакет openvpn."
        pause
        return
      fi
      openvpn --genkey secret "$outfile"
      chmod 600 "$outfile"
      echo "Ключ создан: $outfile"
      ;;
    2)
      echo "Вставь содержимое static key. Заверши ввод строкой: ENDKEY"
      : > "$outfile"
      while IFS= read -r line; do
        [ "$line" = "ENDKEY" ] && break
        printf '%s
' "$line" >> "$outfile"
      done
      chmod 600 "$outfile"
      echo "Ключ сохранен: $outfile"
      ;;
    *)
      echo "Неверный выбор."
      pause
      return
      ;;
  esac

  local copy_now
  copy_now="$(ask_yes_no "Скопировать ключ в /etc/openvpn/static.key сейчас?" "no")"
  if [ "$copy_now" = "yes" ]; then
    require_sudo || return
    copy_with_backup "$outfile" "/etc/openvpn/static.key" "OVPN_KEY_BACKUP" "OVPN_KEY_MANAGED" "600"
  fi

  pause
}

step_create_openvpn_config() {
  print_section "Создание OpenVPN-конфигов (static key mode)"

  echo "1) Создать server.conf"
  echo "2) Создать client.conf"
  prompt 'Выбор: '
  read -r choice

  case "$choice" in
    1)
      local server_tun_ip client_tun_ip port proto
      server_tun_ip="$(ask_default "VPN IP сервера (например 10.20.20.1)" "")"
      client_tun_ip="$(ask_default "VPN IP клиента (например 10.20.20.2)" "")"
      port="$(ask_default "Порт" "1194")"
      proto="$(ask_default "Протокол (udp/tcp)" "udp")"

      local outfile="$CONF_DIR/server.conf"
      cat > "$outfile" <<EOF
# OpenVPN server config (static key)
dev tun
ifconfig ${server_tun_ip} ${client_tun_ip}
secret /etc/openvpn/static.key
port ${port}
proto ${proto}
verb 3
EOF
      chmod 600 "$outfile"
      echo "Создано: $outfile"
      cat "$outfile"

      local copy_server
      copy_server="$(ask_yes_no "Скопировать в /etc/openvpn/server.conf сейчас?" "no")"
      if [ "$copy_server" = "yes" ]; then
        require_sudo || return
        copy_with_backup "$outfile" "/etc/openvpn/server.conf" "OVPN_SERVER_CONF_BACKUP" "OVPN_SERVER_CONF_MANAGED" "600"
      fi
      ;;
    2)
      local remote_ip server_tun_ip client_tun_ip port proto
      remote_ip="$(ask_default "IP сервера OpenVPN (обычно LAN IP PC1)" "")"
      client_tun_ip="$(ask_default "VPN IP клиента (например 10.20.20.2)" "")"
      server_tun_ip="$(ask_default "VPN IP сервера (например 10.20.20.1)" "")"
      port="$(ask_default "Порт" "1194")"
      proto="$(ask_default "Протокол (udp/tcp)" "udp")"

      local outfile="$CONF_DIR/client.conf"
      cat > "$outfile" <<EOF
# OpenVPN client config (static key)
remote ${remote_ip} ${port}
dev tun
ifconfig ${client_tun_ip} ${server_tun_ip}
secret /etc/openvpn/static.key
proto ${proto}
nobind
verb 3
EOF
      chmod 600 "$outfile"
      echo "Создано: $outfile"
      cat "$outfile"

      local copy_client
      copy_client="$(ask_yes_no "Скопировать в /etc/openvpn/client.conf сейчас?" "no")"
      if [ "$copy_client" = "yes" ]; then
        require_sudo || return
        copy_with_backup "$outfile" "/etc/openvpn/client.conf" "OVPN_CLIENT_CONF_BACKUP" "OVPN_CLIENT_CONF_MANAGED" "600"
      fi
      ;;
    *)
      echo "Неверный выбор."
      ;;
  esac

  pause
}

step_run_openvpn() {
  require_sudo || return

  print_section "Запуск OpenVPN. Это foreground-процесс: пока он работает, меню заблокировано. Для выхода нажми Ctrl+C."

  echo "1) Запустить server.conf"
  echo "2) Запустить client.conf"
  prompt 'Выбор: '
  read -r choice

  case "$choice" in
    1)
      run_and_log "openvpn_server" openvpn --config /etc/openvpn/server.conf
      ;;
    2)
      run_and_log "openvpn_client" openvpn --config /etc/openvpn/client.conf
      ;;
    *)
      echo "Неверный выбор."
      ;;
  esac

  pause
}

# -----------------------------------------------------------------------------
# Rollback
# -----------------------------------------------------------------------------

show_rollback_status() {
  load_state

  echo
  echo "Статус rollback:"
  echo "- LAST_IPTABLES_BACKUP: ${LAST_IPTABLES_BACKUP:-<нет>}"
  echo "- IP_FORWARD_BEFORE_DNAT: ${IP_FORWARD_BEFORE_DNAT:-<нет>}"
  echo "- TCPDUMP_CAPS_MANAGED: ${TCPDUMP_CAPS_MANAGED:-no}"
  echo "- TCPDUMP_CAPS_BEFORE: ${TCPDUMP_CAPS_BEFORE:-<нет>}"
  echo "- WG_CONF_MANAGED: ${WG_CONF_MANAGED:-no}"
  echo "- WG_CONF_BACKUP: ${WG_CONF_BACKUP:-<нет>}"
  echo "- OVPN_KEY_MANAGED: ${OVPN_KEY_MANAGED:-no}"
  echo "- OVPN_KEY_BACKUP: ${OVPN_KEY_BACKUP:-<нет>}"
  echo "- OVPN_SERVER_CONF_MANAGED: ${OVPN_SERVER_CONF_MANAGED:-no}"
  echo "- OVPN_SERVER_CONF_BACKUP: ${OVPN_SERVER_CONF_BACKUP:-<нет>}"
  echo "- OVPN_CLIENT_CONF_MANAGED: ${OVPN_CLIENT_CONF_MANAGED:-no}"
  echo "- OVPN_CLIENT_CONF_BACKUP: ${OVPN_CLIENT_CONF_BACKUP:-<нет>}"
  echo
}

rollback_gateway_changes() {
  require_sudo || return
  load_state

  if [ -n "${LAST_IPTABLES_BACKUP:-}" ] && [ -f "${LAST_IPTABLES_BACKUP:-}" ]; then
    run_and_log "iptables_restore" iptables-restore < "${LAST_IPTABLES_BACKUP}"
  else
    echo "Нет сохраненного backup iptables."
  fi

  if [ -n "${IP_FORWARD_BEFORE_DNAT:-}" ] && [ "${IP_FORWARD_BEFORE_DNAT}" != "unknown" ]; then
    run_and_log "restore_ip_forward" sysctl -w "net.ipv4.ip_forward=${IP_FORWARD_BEFORE_DNAT}"
  else
    echo "Исходное значение ip_forward не сохранено."
  fi
}

rollback_pc1_capture() {
  require_sudo || return
  load_state

  if [ "${TCPDUMP_CAPS_MANAGED:-no}" != "yes" ]; then
    echo "capabilities tcpdump не отмечены как измененные этим скриптом."
    return 0
  fi

  if ! command_exists tcpdump; then
    echo "tcpdump не найден."
    return 0
  fi

  local tcpdump_path
  tcpdump_path="$(command -v tcpdump)"

  if [ -n "${TCPDUMP_CAPS_BEFORE:-}" ]; then
    run_and_log "restore_tcpdump_caps" setcap "${TCPDUMP_CAPS_BEFORE}" "$tcpdump_path"
  else
    run_and_log "clear_tcpdump_caps" setcap -r "$tcpdump_path"
  fi

  save_var TCPDUMP_CAPS_MANAGED "no"
}

rollback_wireguard_files() {
  require_sudo || return

  restore_or_remove_managed_file "/etc/wireguard/wg0.conf" "WG_CONF_BACKUP" "WG_CONF_MANAGED" "600"

  if ip link show wg0 >/dev/null 2>&1; then
    run_and_log "wg_down_rollback" wg-quick down wg0 || true
  fi
}

rollback_openvpn_files() {
  require_sudo || return

  restore_or_remove_managed_file "/etc/openvpn/static.key" "OVPN_KEY_BACKUP" "OVPN_KEY_MANAGED" "600"
  restore_or_remove_managed_file "/etc/openvpn/server.conf" "OVPN_SERVER_CONF_BACKUP" "OVPN_SERVER_CONF_MANAGED" "600"
  restore_or_remove_managed_file "/etc/openvpn/client.conf" "OVPN_CLIENT_CONF_BACKUP" "OVPN_CLIENT_CONF_MANAGED" "600"

  echo "Если OpenVPN запущен в другом foreground-окне, останови его вручную через Ctrl+C."
}

rollback_local_artifacts() {
  local confirm
  confirm="$(ask_yes_no "Удалить локальные generated_configs/, logs/, backups/ и lab_state.env?" "no")"

  if [ "$confirm" = "yes" ]; then
    rm -rf "$CONF_DIR" "$LOG_DIR" "$BACKUP_DIR" "$STATE_FILE"
    mkdir -p "$LOG_DIR" "$CONF_DIR" "$BACKUP_DIR"
    echo "Локальные артефакты очищены."
  else
    echo "Очистка локальных артефактов отменена."
  fi
}

step_rollback_menu() {
  while true; do
    echo
    echo "1) Показать статус rollback"
    echo "2) Откатить gateway изменения (iptables + ip_forward)"
    echo "3) Откатить подготовку PC1 capture (capabilities tcpdump)"
    echo "4) Откатить WireGuard конфиг и попытаться опустить wg0"
    echo "5) Откатить OpenVPN файлы"
    echo "6) Полный rollback всего, что умеет скрипт"
    echo "7) Удалить локальные generated/logs/state/backups"
    echo "0) Назад"
    prompt 'Выбор: '
    read -r choice

    case "$choice" in
      1)
        show_rollback_status
        pause
        ;;
      2)
        rollback_gateway_changes
        pause
        ;;
      3)
        rollback_pc1_capture
        pause
        ;;
      4)
        rollback_wireguard_files
        pause
        ;;
      5)
        rollback_openvpn_files
        pause
        ;;
      6)
        rollback_gateway_changes
        rollback_pc1_capture
        rollback_wireguard_files
        rollback_openvpn_files
        echo
        echo "Полный rollback завершен настолько, насколько это можно сделать автоматически."
        echo "OpenVPN/iperf3, если они запущены в другом окне, останови вручную."
        pause
        ;;
      7)
        rollback_local_artifacts
        pause
        ;;
      0)
        return 0
        ;;
      *)
        echo "Неверный выбор."
        pause
        ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Ролевые меню
# -----------------------------------------------------------------------------

gateway_mode_menu() {
  while true; do
    safe_clear
    echo "============================================================"
    echo " GATEWAY MODE"
    echo "============================================================"
    echo "1. Узнать IP / интерфейсы / маршруты"
    echo "2. Установить пакеты"
    echo "3. Настроить DNAT для SSH remote capture"
    echo "4. Показать сохраненные значения"
    echo "5. Сбросить назад изменения, сделанные скриптом"
    echo "0. Назад"
    echo "============================================================"
    prompt 'Выбор: '
    read -r choice

    case "$choice" in
      1) step_show_network_info ;;
      2) step_install_packages ;;
      3) step_gateway_dnat ;;
      4) show_saved_state; pause ;;
      5) step_rollback_menu ;;
      0) return 0 ;;
      *) echo "Неверный выбор."; pause ;;
    esac
  done
}

pc1_mode_menu() {
  while true; do
    safe_clear
    echo "============================================================"
    echo " PC1 MODE"
    echo "============================================================"
    echo "1.  Узнать IP / интерфейсы / маршруты"
    echo "2.  Установить пакеты"
    echo "3.  Подготовить PC1 для Wireshark remote capture"
    echo "4.  Сгенерировать WireGuard ключи"
    echo "5.  Создать конфиг WireGuard"
    echo "6.  Поднять / опустить / проверить WireGuard"
    echo "7.  Сгенерировать или импортировать OpenVPN static key"
    echo "8.  Создать OpenVPN server/client конфиг"
    echo "9.  Запустить OpenVPN"
    echo "10. Показать tcpdump / Wireshark подсказки"
    echo "11. Запустить MTU тесты"
    echo "12. Найти точный предел MTU"
    echo "13. Запустить throughput тесты (iperf3)"
    echo "14. Проверить basic ping"
    echo "15. Создать памятку для протокола"
    echo "16. Показать сохраненные значения"
    echo "17. Сбросить назад изменения, сделанные скриптом"
    echo "0.  Назад"
    echo "============================================================"
    prompt 'Выбор: '
    read -r choice

    case "$choice" in
      1) step_show_network_info ;;
      2) step_install_packages ;;
      3) step_prepare_pc1_capture ;;
      4) step_generate_wg_keys ;;
      5) step_create_wg_config ;;
      6) step_manage_wg ;;
      7) step_openvpn_key ;;
      8) step_create_openvpn_config ;;
      9) step_run_openvpn ;;
      10) step_capture_help ;;
      11) step_mtu_tests ;;
      12) step_find_mtu_limit ;;
      13) step_iperf_tests ;;
      14) step_basic_ping ;;
      15) step_protocol_notes ;;
      16) show_saved_state; pause ;;
      17) step_rollback_menu ;;
      0) return 0 ;;
      *) echo "Неверный выбор."; pause ;;
    esac
  done
}

pc2_mode_menu() {
  while true; do
    safe_clear
    echo "============================================================"
    echo " PC2 MODE"
    echo "============================================================"
    echo "1.  Узнать IP / интерфейсы / маршруты"
    echo "2.  Установить пакеты"
    echo "3.  Сгенерировать WireGuard ключи"
    echo "4.  Создать конфиг WireGuard"
    echo "5.  Поднять / опустить / проверить WireGuard"
    echo "6.  Сгенерировать или импортировать OpenVPN static key"
    echo "7.  Создать OpenVPN server/client конфиг"
    echo "8.  Запустить OpenVPN"
    echo "9.  Показать tcpdump / Wireshark подсказки"
    echo "10. Запустить MTU тесты"
    echo "11. Найти точный предел MTU"
    echo "12. Запустить throughput тесты (iperf3)"
    echo "13. Проверить basic ping"
    echo "14. Создать памятку для протокола"
    echo "15. Показать сохраненные значения"
    echo "16. Сбросить назад изменения, сделанные скриптом"
    echo "0.  Назад"
    echo "============================================================"
    prompt 'Выбор: '
    read -r choice

    case "$choice" in
      1) step_show_network_info ;;
      2) step_install_packages ;;
      3) step_generate_wg_keys ;;
      4) step_create_wg_config ;;
      5) step_manage_wg ;;
      6) step_openvpn_key ;;
      7) step_create_openvpn_config ;;
      8) step_run_openvpn ;;
      9) step_capture_help ;;
      10) step_mtu_tests ;;
      11) step_find_mtu_limit ;;
      12) step_iperf_tests ;;
      13) step_basic_ping ;;
      14) step_protocol_notes ;;
      15) show_saved_state; pause ;;
      16) step_rollback_menu ;;
      0) return 0 ;;
      *) echo "Неверный выбор."; pause ;;
    esac
  done
}

full_menu() {
  while true; do
    safe_clear
    echo "============================================================"
    echo " FULL MENU"
    echo "============================================================"
    echo "1.  Узнать IP / интерфейсы / маршруты и сохранить в файл"
    echo "2.  Установить нужные пакеты"
    echo "3.  Настроить gateway DNAT для SSH remote capture"
    echo "4.  Подготовить PC1 для Wireshark remote capture"
    echo "5.  Сгенерировать WireGuard ключи"
    echo "6.  Создать конфиг WireGuard"
    echo "7.  Поднять / опустить / проверить WireGuard"
    echo "8.  Сгенерировать или импортировать OpenVPN static key"
    echo "9.  Создать OpenVPN server/client конфиг"
    echo "10. Запустить OpenVPN"
    echo "11. Показать tcpdump / Wireshark подсказки"
    echo "12. Запустить MTU тесты"
    echo "13. Найти точный предел MTU"
    echo "14. Запустить throughput тесты (iperf3)"
    echo "15. Проверить basic ping"
    echo "16. Создать памятку для протокола"
    echo "17. Показать сохраненные значения"
    echo "18. Сбросить назад изменения, сделанные скриптом"
    echo "0.  Назад"
    echo "============================================================"
    prompt 'Выбор: '
    read -r choice

    case "$choice" in
      1) step_show_network_info ;;
      2) step_install_packages ;;
      3) step_gateway_dnat ;;
      4) step_prepare_pc1_capture ;;
      5) step_generate_wg_keys ;;
      6) step_create_wg_config ;;
      7) step_manage_wg ;;
      8) step_openvpn_key ;;
      9) step_create_openvpn_config ;;
      10) step_run_openvpn ;;
      11) step_capture_help ;;
      12) step_mtu_tests ;;
      13) step_find_mtu_limit ;;
      14) step_iperf_tests ;;
      15) step_basic_ping ;;
      16) step_protocol_notes ;;
      17) show_saved_state; pause ;;
      18) step_rollback_menu ;;
      0) return 0 ;;
      *) echo "Неверный выбор."; pause ;;
    esac
  done
}

root_menu() {
  while true; do
    safe_clear
    echo "============================================================"
    echo " VPN LAB HELPER"
    echo "============================================================"
    echo "1. Gateway mode"
    echo "2. PC1 mode"
    echo "3. PC2 mode"
    echo "4. Full menu"
    echo "0. Exit"
    echo "============================================================"
    prompt 'Выбор: '
    read -r choice

    case "$choice" in
      1) gateway_mode_menu ;;
      2) pc1_mode_menu ;;
      3) pc2_mode_menu ;;
      4) full_menu ;;
      0) exit 0 ;;
      *) echo "Неверный выбор."; pause ;;
    esac
  done
}

root_menu
