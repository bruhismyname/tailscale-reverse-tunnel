#!/bin/bash
# ============================================================================
#  muse_tunnel.sh — TUNNEL VPS MUSE.AI KE PC (tanpa 9Router)
# ============================================================================
#
#  Script ini HANYA mengurus tunnel. Tidak ada 9Router, bridge, Hermes, atau
#  sync provider. Hasil akhirnya tiga jalur masuk ke VPS Muse ini:
#
#  JALUR 0 — Langsung via Tailscale (bila inbound tidak diblokir sandbox)
#    Dari PC:  ssh <user-vps>@<IP-Tailscale-VPS>
#    Butuh sshd VPS aktif (dipulihkan otomatis oleh script ini) dan public
#    key PC terdaftar (add-key). Bila sandbox memblokir koneksi masuk,
#    gunakan JALUR 1 / JALUR 2.
#
#  JALUR 1 — Tunnel terbalik lewat Tailscale (stabil, alamat tetap)
#    VPS menyambung keluar ke PC kamu (via Tailscale) lalu membuka "pintu
#    balik" di PC. Dari PC:   ssh -p 2222 <user-vps>@localhost
#    Syarat: PC menyala, Tailscale aktif, OpenSSH Server aktif.
#
#  JALUR 2 — Tunnel publik Pinggy (dari mana saja, tanpa Tailscale)
#    VPS membuka alamat publik tcp://xxxx:PORT yang menembus ke SSH VPS.
#    Dari perangkat apa pun:  ssh -p PORT <user-vps>@xxxx
#    Free tier: alamat berganti dan diputus tiap 60 menit (penjaga memperbarui
#    di menit ke-50). Mau alamat tetap -> isi PINGGY_TOKEN (akun Pinggy).
#    DEMI KEAMANAN jalur ini baru dinyalakan bila login password SSH VPS
#    sudah dimatikan dan minimal ada satu public key terdaftar.
#
# ----------------------------------------------------------------------------
#  CARA PAKAI
# ----------------------------------------------------------------------------
#    bash muse_tunnel.sh              pasang + nyalakan semuanya (idempoten)
#    bash muse_tunnel.sh status       lihat kondisi tunnel
#    bash muse_tunnel.sh url          tampilkan perintah SSH untuk masuk ke VPS
#    bash muse_tunnel.sh add-key      daftarkan public key PC agar bisa SSH ke VPS
#    bash muse_tunnel.sh start|stop|restart
#    bash muse_tunnel.sh set-password (hanya bila PC_AUTH="password")
#    bash muse_tunnel.sh pc-setup     tampilkan langkah yang harus dilakukan di PC
#    bash muse_tunnel.sh diag         diagnostik jaringan (proxy/Tailscale/Pinggy/sshd)
#    bash muse_tunnel.sh cron-install pasang cron penjaga (juga otomatis saat install)
#    bash muse_tunnel.sh cron-remove  hapus cron penjaga
#
#  DI PC (opsional, Git Bash / terminal apa pun):
#    bash muse_tunnel.sh pc-info      deteksi otomatis user & IP Tailscale PC + cek sshd PC
#
# ----------------------------------------------------------------------------
#  UNTUK MUSE (AGENT) — cron dipasang OTOMATIS oleh script ini
# ----------------------------------------------------------------------------
#  Saat install (dan oleh penjaga tiap siklus), cron berikut dipasang bila
#  belum ada — sekaligus membersihkan cron LAMA muse_setup.sh yang bentrok
#  (ssh-tunnel-keeper, pinggy-keeper, nine-router-healer, muse-bridge-poller):
#       * * * * * bash ~/workspace/tunnel/muse_tunnel.sh start >/dev/null 2>&1
#  Perintah itu idempoten: bila penjaga (daemon) masih hidup tidak melakukan
#  apa-apa; bila mati (mis. VM restart) ia dinyalakan lagi, dan penjaga akan
#  memasang ulang paket/SSH server yang hilang lalu menyambung ulang tunnel.
#  Jangan membuat cron lain.
#
#  Aturan: JANGAN pernah menampilkan password/token di chat. Public key
#  (ssh-ed25519 ...) bukan rahasia dan boleh ditampilkan.
#
#  Semua aset ada di ~/workspace/tunnel (wilayah persisten). /etc dan /usr
#  hilang saat VM restart — karena itu paket & konfigurasi SSH dipulihkan
#  otomatis oleh penjaga.
# ============================================================================

set -u

# ----------------------------------------------------------------------------
# KONFIGURASI — nilai bawaan. Untuk mengubah tanpa menyentuh script ini, isi
# ~/workspace/tunnel/tunnel.env (dibuat otomatis, semua baris dikomentari).
# ----------------------------------------------------------------------------
PC_USER="your-pc-username"        # username Windows/Linux di PC
PC_TAILSCALE_IP="100.x.y.z"       # IP Tailscale PC (jalankan: bash muse_tunnel.sh pc-info)
PC_SSH_PORT=22                     # port SSH di PC
PC_OS="windows"                    # windows | unix  (untuk cek kesehatan tunnel)
MUSE_TAILSCALE_IP=""               # IP Tailscale VPS ini (opsional; kosong = deteksi
                                   # otomatis via CLI tailscale)
PC_AUTH="key"                      # key (disarankan) | password
TAILSCALE_PROXY_PORT=3130          # port proxy sandbox yang boleh menembus Tailscale
TS_PROXY_OVERRIDE=""               # isi bila alamat proxy Tailscale beda dari aturan di atas
PC_TUNNEL_ENABLE=1                 # 1 = nyalakan JALUR 1
PC_FORWARDS="2222:127.0.0.1:22"    # daftar "PORT_DI_PC:HOST:PORT_DI_VPS" dipisah spasi.
                                   # contoh tambah web: "2222:127.0.0.1:22 8080:127.0.0.1:8080"
                                   # (port pertama dipakai untuk cek kesehatan)

PINGGY_ENABLE=1                    # 1 = nyalakan JALUR 2
PINGGY_HOST="free.pinggy.io"       # server Pinggy (free tier)
PINGGY_TOKEN=""                    # opsional: token akun Pinggy (alamat tetap, jangan dibagikan)
PINGGY_TARGET_PORT=22              # port VPS yang dibuka ke publik (22 = SSH)
PINGGY_MAX_AGE=3000                # detik; restart proaktif sebelum batas 60 menit (free tier).
                                   # Isi 0 bila akun Pinggy-mu tidak punya batas waktu.

HARDEN_SSHD=1                      # 1 = matikan login password SSH (kunci saja)
CHECK_INTERVAL=30                  # detik antar pemeriksaan penjaga
CRON_ENABLE=1                      # 1 = pasang otomatis cron penjaga tiap 1 menit

# ----------------------------------------------------------------------------
# LOKASI (semua persisten)
# ----------------------------------------------------------------------------
WS="$HOME/workspace"
DIR_TUNNEL="$WS/tunnel"
CONF="$DIR_TUNNEL/tunnel.env"

# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

STATE="$DIR_TUNNEL/state"
LOG="$DIR_TUNNEL/tunnel.log"
SSH_LOG="$DIR_TUNNEL/pc-ssh.log"
PINGGY_LOG="$STATE/pinggy.out"
PROXY_HELPER="$DIR_TUNNEL/ssh-proxy.py"
PC_KEY="$DIR_TUNNEL/id_ed25519_pc"
ASKPASS="$DIR_TUNNEL/askpass.sh"
KNOWN_HOSTS="$DIR_TUNNEL/known_hosts"
CTRL="$DIR_TUNNEL/pc.sock"
RUN_COPY="$DIR_TUNNEL/muse_tunnel.sh"
DAEMON_PID="$STATE/daemon.pid"
AUTH_KEYS="$HOME/.ssh/authorized_keys"
SSHD_DROPIN="/etc/ssh/sshd_config.d/00-muse-tunnel.conf"
PKGS="openssh-server openssh-client python3 curl procps util-linux"
PC_TARGET="$PC_USER@$PC_TAILSCALE_IP"
SELF="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "$0")"

# ----------------------------------------------------------------------------
# HELPER TAMPILAN
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
  C_OK="\033[1;32m"; C_WARN="\033[1;33m"; C_ERR="\033[1;31m"; C_HEAD="\033[1;36m"; C_OFF="\033[0m"
else
  C_OK=""; C_WARN=""; C_ERR=""; C_HEAD=""; C_OFF=""
fi
info()  { echo -e "  $1"; }
ok()    { echo -e "${C_OK}  ✓ $1${C_OFF}"; }
warn()  { echo -e "${C_WARN}  ! $1${C_OFF}"; }
gagal() { echo -e "${C_ERR}  ✗ $1${C_OFF}"; }
modul() { echo; echo -e "${C_HEAD}=== $1 ===${C_OFF}"; }

have() { command -v "$1" >/dev/null 2>&1; }
if [ "$(id -u)" = "0" ]; then SUDO=""; else SUDO="sudo"; fi

# log ke file (+ ke layar bila dijalankan manual di terminal)
log() {
  mkdir -p "$DIR_TUNNEL" 2>/dev/null
  echo "[$(date '+%F %T')] $*" >> "$LOG"
  if [ -t 1 ]; then echo -e "  · $*"; fi
  return 0
}
# log hanya bila pesannya berbeda dari yang terakhir (cegah spam tiap 30 detik)
log_change() {
  local f="$STATE/$1.last"
  [ "$(cat "$f" 2>/dev/null)" = "$2" ] && return 0
  echo "$2" > "$f"
  log "$2"
}
rotate_log() {
  local sz
  sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
  if [ "$sz" -gt 524288 ]; then tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; fi
  sz=$(stat -c %s "$SSH_LOG" 2>/dev/null || echo 0)
  if [ "$sz" -gt 262144 ]; then : > "$SSH_LOG"; fi
  return 0
}

mkdir_all() {
  mkdir -p "$DIR_TUNNEL" "$STATE" "$HOME/.ssh"
  chmod 700 "$HOME/.ssh" "$DIR_TUNNEL" 2>/dev/null
  return 0
}

# Alamat proxy bawaan sandbox (untuk keluar ke internet)
default_proxy() {
  local p="${HTTPS_PROXY:-${https_proxy:-}}"
  echo "${p%/}"
}
# Alamat proxy yang boleh menembus Tailscale (host sama, port berbeda).
# Bila tidak ada env proxy tapi node tailscaled aktif, arahkan ke localhost —
# tailscaled lokal meng-COMNECT tanpa otentikasi dan menembus tailnet.
ts_proxy() {
  if [ -n "$TS_PROXY_OVERRIDE" ]; then echo "$TS_PROXY_OVERRIDE"; return 0; fi
  local p; p="$(default_proxy)"
  if [ -z "$p" ]; then
    if pgrep -x tailscaled >/dev/null 2>&1 || have tailscale; then echo "http://127.0.0.1:3128"; else return 0; fi
  fi
  echo "${p%:*}:${TAILSCALE_PROXY_PORT}"
}

# IP Tailscale VPS ini (dari env, atau deteksi otomatis via CLI tailscale)
muse_ts_ip() {
  if [ -n "$MUSE_TAILSCALE_IP" ]; then echo "$MUSE_TAILSCALE_IP"; return 0; fi
  local ip
  ip=$(tailscale ip -4 2>/dev/null | head -1)
  [ -n "$ip" ] && echo "$ip"
}

# ============================================================================
# 1. PENEMBUS PROXY (ProxyCommand SSH lewat proxy HTTP CONNECT sandbox)
# ============================================================================
write_proxy_helper() {
  cat > "$PROXY_HELPER" <<'PXEOF'
#!/usr/bin/env python3
"""ProxyCommand SSH: HTTP CONNECT lewat proxy (opsional berotentikasi), lalu relay stdio.

Pemakaian : ssh-proxy.py HOST PORT
Proxy dari: env TUNNEL_PROXY (mis. http://user:pass@host:port), cadangan TS_PROXY / HTTPS_PROXY.
Relay memakai fd blocking + satu thread (stdin -> socket), jadi tidak ada
masalah BlockingIOError / partial write seperti relay non-blocking.
"""
import base64
import os
import socket
import sys
import threading
from urllib.parse import urlsplit, unquote


def die(msg):
    sys.stderr.write("ssh-proxy: %s\n" % msg)
    sys.exit(1)


def main():
    if len(sys.argv) < 3:
        die("pemakaian: ssh-proxy.py HOST PORT")
    host, port = sys.argv[1], int(sys.argv[2])
    url = (os.environ.get("TUNNEL_PROXY") or os.environ.get("TS_PROXY")
           or os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy") or "")
    if not url:
        die("tidak ada proxy (isi TUNNEL_PROXY)")
    u = urlsplit(url if "://" in url else "http://" + url)
    if not u.hostname:
        die("alamat proxy tidak valid")

    try:
        s = socket.create_connection((u.hostname, u.port or 3128), timeout=20)
    except OSError as e:
        die("gagal konek ke proxy: %s" % e)

    req = "CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n" % (host, port, host, port)
    if u.username:
        cred = "%s:%s" % (unquote(u.username), unquote(u.password or ""))
        req += "Proxy-Authorization: Basic %s\r\n" % base64.b64encode(cred.encode()).decode()
    req += "\r\n"
    s.sendall(req.encode())

    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            die("proxy menutup koneksi")
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    status = head.split(b"\r\n")[0].split()
    if len(status) < 2 or status[1] != b"200":
        die("proxy menolak: %s" % head.split(b"\r\n")[0].decode(errors="replace"))
    s.settimeout(None)

    if rest:
        os.write(1, rest)

    def pump_in():
        try:
            while True:
                data = os.read(0, 65536)
                if not data:
                    break
                s.sendall(data)
        except Exception:
            pass
        try:
            s.shutdown(socket.SHUT_WR)
        except Exception:
            pass

    threading.Thread(target=pump_in, daemon=True).start()

    try:
        while True:
            data = s.recv(65536)
            if not data:
                break
            view = memoryview(data)
            while view:
                n = os.write(1, view)
                view = view[n:]
    except Exception:
        pass
    os._exit(0)


if __name__ == "__main__":
    main()
PXEOF
  chmod +x "$PROXY_HELPER"
}

# ============================================================================
# 2. PAKET + SSH SERVER VPS
# ============================================================================
ensure_packages() {
  local missing="" p
  for p in $PKGS; do
    dpkg-query -W -f '${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || missing="$missing $p"
  done
  [ -z "$missing" ] && return 0
  have apt-get || { log "apt-get tidak ada — pasang manual:$missing"; return 1; }
  log "memasang paket yang hilang:$missing"
  $SUDO apt-get update -qq >> "$LOG" 2>&1
  # shellcheck disable=SC2086
  if DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq -o DPkg::Lock::Timeout=60 $missing >> "$LOG" 2>&1; then
    log "paket terpasang"
  else
    log "GAGAL memasang paket:$missing (lihat tunnel.log)"
    return 1
  fi
}

has_authorized_key() { [ -s "$AUTH_KEYS" ] && grep -qE '^(ssh-|ecdsa-|sk-)' "$AUTH_KEYS"; }
sshd_listening()     { timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/22' 2>/dev/null; }
sshd_password_off()  { $SUDO sshd -T 2>/dev/null | grep -qi '^passwordauthentication no'; }

# Reload konfigurasi sshd TANPA menyentuh sesi SSH yang sedang aktif
# (sinyal hanya ke proses listener, bukan ke semua proses bernama sshd).
sshd_reload() {
  $SUDO systemctl reload ssh >/dev/null 2>&1 && return 0
  $SUDO systemctl reload sshd >/dev/null 2>&1 && return 0
  local pid
  pid=$(cat /run/sshd.pid 2>/dev/null)
  [ -z "$pid" ] && pid=$(pgrep -f 'sshd:.*\[listener\]' | head -1)
  [ -n "$pid" ] && $SUDO kill -HUP "$pid"
  return 0
}

# Sinkronisasi authorized_keys ke HOME ASLI user 0 (root).
# Di beberapa sandbox (mis. muse.ai), HOME env bisa mengarah ke /home/<agent>
# padahal sshd (jalan sebagai root) membaca /root/.ssh/authorized_keys. Tanpa
# sinkronisasi ini, add-key menulis ke tempat yang salah dan SSH dari PC gagal.
root_home() { getent passwd 0 2>/dev/null | cut -d: -f6; }
sync_root_keys() {
  local rh line changed=0
  rh="$(root_home)"
  { [ -n "$rh" ] && [ "$rh" != "$HOME" ]; } || return 0
  [ -s "$AUTH_KEYS" ] || return 0
  $SUDO mkdir -p "$rh/.ssh" 2>/dev/null || return 0
  $SUDO chmod 700 "$rh/.ssh" 2>/dev/null
  $SUDO touch "$rh/.ssh/authorized_keys" 2>/dev/null || return 0
  $SUDO chmod 600 "$rh/.ssh/authorized_keys" 2>/dev/null
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    if ! $SUDO grep -qF -- "$line" "$rh/.ssh/authorized_keys" 2>/dev/null; then
      echo "$line" | $SUDO tee -a "$rh/.ssh/authorized_keys" >/dev/null 2>&1
      changed=1
    fi
  done < "$AUTH_KEYS"
  [ "$changed" = "1" ] && log "key disinkronkan ke $rh/.ssh/authorized_keys (home asli root — sshd membaca situ)"
  return 0
}

ensure_sshd() {
  ensure_packages || true
  if ! have sshd && [ ! -x /usr/sbin/sshd ]; then
    log_change sshd "SSH server (sshd) belum terpasang"
    return 1
  fi
  $SUDO mkdir -p /run/sshd
  $SUDO ssh-keygen -A >/dev/null 2>&1

  local changed=0
  if [ "$HARDEN_SSHD" = "1" ] && has_authorized_key && [ ! -f "$SSHD_DROPIN" ]; then
    $SUDO mkdir -p /etc/ssh/sshd_config.d
    grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null \
      || $SUDO sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
    printf '%s\n' \
      '# dibuat oleh muse_tunnel.sh — login hanya dengan kunci SSH' \
      'PasswordAuthentication no' \
      'KbdInteractiveAuthentication no' \
      'PermitRootLogin prohibit-password' | $SUDO tee "$SSHD_DROPIN" >/dev/null
    if $SUDO sshd -t >> "$LOG" 2>&1; then
      changed=1
      log "login password SSH dimatikan (hanya kunci SSH yang diterima)"
    else
      $SUDO rm -f "$SSHD_DROPIN"
      log "konfigurasi SSH hardening ditolak sshd -t — dibatalkan"
    fi
  fi

  if ! sshd_listening; then
    $SUDO systemctl enable --now ssh >/dev/null 2>&1 \
      || $SUDO systemctl enable --now sshd >/dev/null 2>&1 \
      || $SUDO /usr/sbin/sshd >> "$LOG" 2>&1
  elif [ "$changed" = "1" ]; then
    sshd_reload
  fi

  # sshd butuh sesaat untuk siap (terutama sesudah start/reload)
  local i
  for i in 1 2 3 4 5 6; do
    sshd_listening && return 0
    sleep 1
  done
  log_change sshd "SSH server VPS belum mendengarkan di port 22"
  return 1
}

# ============================================================================
# 3. KUNCI & AKSES
# ============================================================================
valid_pubkey() {
  case "$1" in
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ssh-ed25519@openssh.com\ *|sk-ecdsa-sha2-nistp256@openssh.com\ *) return 0 ;;
    *) return 1 ;;
  esac
}

# Daftarkan public key PC ke VPS (agar PC bisa SSH ke VPS lewat tunnel)
cmd_add_key() {
  local key="${1:-}"
  if [ -z "$key" ]; then
    if [ -t 0 ]; then
      read -r -p "  Tempel PUBLIC key PC (satu baris, diawali ssh-ed25519 ...): " key < /dev/tty || true
    else
      gagal "Beri public key sebagai argumen: bash muse_tunnel.sh add-key \"ssh-ed25519 AAAA...\""
      return 1
    fi
  fi
  key="$(echo "$key" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if ! valid_pubkey "$key"; then
    gagal "Format public key tidak dikenali (harus diawali ssh-ed25519 / ssh-rsa / ecdsa-...)."
    info "Jangan tempel PRIVATE key. Yang dipakai adalah file berakhiran .pub"
    return 1
  fi
  mkdir_all
  touch "$AUTH_KEYS"; chmod 600 "$AUTH_KEYS"
  if grep -qF "$key" "$AUTH_KEYS"; then
    ok "Public key itu sudah terdaftar"
  else
    echo "$key" >> "$AUTH_KEYS"
    ok "Public key didaftarkan — PC kamu kini bisa SSH ke VPS"
  fi
  ensure_sshd >/dev/null 2>&1 || true
  sync_root_keys
  if [ "$HARDEN_SSHD" = "1" ] && sshd_password_off; then ok "Login password SSH sudah dimatikan (aman untuk tunnel publik)"; fi
}

ensure_keypair() {
  [ "$PC_AUTH" = "key" ] || return 0
  [ -f "$PC_KEY" ] && return 0
  mkdir_all
  if ssh-keygen -q -t ed25519 -N "" -C "muse-vps-tunnel@$(hostname)" -f "$PC_KEY"; then
    chmod 600 "$PC_KEY"
    ok "Kunci SSH VPS -> PC dibuat (private key tinggal di VPS, tidak pernah ditampilkan)"
  else
    gagal "Gagal membuat kunci SSH"
    return 1
  fi
}

ensure_askpass() {
  [ "$PC_AUTH" = "password" ] || return 0
  [ -f "$ASKPASS" ] && return 0
  printf '#!/bin/bash\necho "GANTI_DENGAN_PASSWORD_PC"\n' > "$ASKPASS"
  chmod 700 "$ASKPASS"
  warn "Mode password: isi dulu lewat  bash muse_tunnel.sh set-password"
}

cmd_set_password() {
  mkdir_all
  [ -t 0 ] || { gagal "Harus dijalankan di terminal interaktif"; return 1; }
  local pw=""
  read -r -s -p "  Password akun $PC_USER di PC (tidak tampil di layar): " pw < /dev/tty; echo
  [ -n "$pw" ] || { warn "Kosong — dibatalkan"; return 1; }
  { echo '#!/bin/bash'; printf 'printf "%%s\\n" %q\n' "$pw"; } > "$ASKPASS"
  chmod 700 "$ASKPASS"
  ok "Password tersimpan di askpass.sh (mode 700, tidak ditampilkan)"
}

# Deteksi otomatis konfigurasi PC (jalankan DI PC): tampilkan PC_USER &
# PC_TAILSCALE_IP yang benar untuk ditempel ke tunnel.env. Di VPS tidak berguna.
cmd_pc_info() {
  echo
  info "DETEKSI OTOMATIS KONFIGURASI PC (jalankan ini di PC)"
  local user ip
  user="$(id -un 2>/dev/null || echo "${USERNAME:-$USER}")"
  ip=""
  local ts
  for ts in tailscale tailscale.exe "/c/Program Files/Tailscale/tailscale.exe" "/c/Program Files (x86)/Tailscale/tailscale.exe" /usr/bin/tailscale /usr/local/bin/tailscale; do
    if command -v "$ts" >/dev/null 2>&1 || [ -x "$ts" ]; then
      ip="$($ts ip -4 2>/dev/null | head -1)"; [ -n "$ip" ] && break
    fi
  done
  if [ -n "$ip" ]; then
    ok "PC_USER=\"$user\""
    ok "PC_TAILSCALE_IP=\"$ip\""
    info "Tempel dua baris itu di ~/workspace/tunnel/tunnel.env di VPS (hapus tanda #)."
  else
    warn "Tailscale CLI tidak ditemukan — pastikan Tailscale terpasang & aktif di PC."
  fi
  # cek cepat sshd PC
  if timeout 3 bash -c 'exec 3<>/dev/tcp/127.0.0.1/22' 2>/dev/null; then
    ok "OpenSSH Server PC: mendengarkan di port 22"
  else
    warn "OpenSSH Server PC: belum aktif — jalankan pc-setup untuk langkahnya"
  fi
  echo
}

# Langkah yang harus dilakukan di PC (sekali saja)
pc_instructions() {
  echo
  info "YANG PERLU DISIAPKAN DI PC (sekali saja):"
  info "  1. Tailscale menyala di PC (login akun yang sama dengan jaringan ini)."
  info "  2. OpenSSH Server menyala di PC."
  info "     Windows: Settings > Apps > Optional features > OpenSSH Server,"
  info "     lalu (PowerShell admin)  Start-Service sshd ; Set-Service sshd -StartupType Automatic"
  if [ "$PC_AUTH" = "key" ] && [ -f "$PC_KEY.pub" ]; then
    local pub; pub="$(cat "$PC_KEY.pub")"
    info "  3. Izinkan VPS masuk ke PC — tempel di PowerShell PC (public key, bukan rahasia):"
    cat <<EOF

     \$k = '$pub'
     # Bila akun Windows kamu Administrator:
     Add-Content -Encoding ascii "\$env:ProgramData\\ssh\\administrators_authorized_keys" \$k
     icacls.exe "\$env:ProgramData\\ssh\\administrators_authorized_keys" /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
     # Bila akun biasa (bukan Administrator):
     New-Item -Force -ItemType Directory "\$env:USERPROFILE\\.ssh" | Out-Null
     Add-Content -Encoding ascii "\$env:USERPROFILE\\.ssh\\authorized_keys" \$k

EOF
  fi
  info "  4. Agar PC bisa SSH KE VPS: ambil public key PC"
  info "     (PowerShell: type \$env:USERPROFILE\\.ssh\\id_ed25519.pub ;"
  info "      belum ada? jalankan ssh-keygen -t ed25519), lalu di VPS:"
  info "        bash $RUN_COPY add-key \"ssh-ed25519 AAAA... kamu@pc\""
  info "  5. (Paling mudah) Di PC, Git Bash: bash muse_tunnel.sh pc-info"
  info "     -> deteksi otomatis PC_USER & PC_TAILSCALE_IP yang benar."
}

# ============================================================================
# 4. JALUR 1 — TUNNEL TERBALIK KE PC (via Tailscale)
# ============================================================================
build_pc_opts() {
  PC_OPTS=(-p "$PC_SSH_PORT" -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=2
           -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS" -E "$SSH_LOG")
  PC_ENV=("MUSE_TUNNEL=1")
  local proxy; proxy="$(ts_proxy)"
  if [ -n "$proxy" ]; then
    PC_OPTS+=(-o "ProxyCommand=python3 $PROXY_HELPER %h %p")
    PC_ENV+=("TUNNEL_PROXY=$proxy")
  fi
  if [ "$PC_AUTH" = "password" ]; then
    PC_OPTS+=(-o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no)
    PC_ENV+=("SSH_ASKPASS=$ASKPASS" "SSH_ASKPASS_REQUIRE=force" "DISPLAY=${DISPLAY:-:0}")
  else
    PC_OPTS+=(-i "$PC_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o PasswordAuthentication=no)
  fi
}

pc_master_alive() { ssh -O check -o ControlPath="$CTRL" "$PC_TARGET" >/dev/null 2>&1; }
pc_stop() {
  ssh -O exit -o ControlPath="$CTRL" "$PC_TARGET" >/dev/null 2>&1
  pkill -f -- "ControlPath=$CTRL" 2>/dev/null
  rm -f "$CTRL"
  return 0
}

# PC terjangkau? (sshd PC menjawab dengan banner "SSH-" lewat jalur Tailscale)
pc_reachable() {
  local proxy out; proxy="$(ts_proxy)"
  if [ -n "$proxy" ]; then
    out=$( { sleep 2; } | TUNNEL_PROXY="$proxy" timeout 12 python3 "$PROXY_HELPER" "$PC_TAILSCALE_IP" "$PC_SSH_PORT" 2>/dev/null | head -c 4 )
  else
    out=$(timeout 8 bash -c "exec 3<>/dev/tcp/$PC_TAILSCALE_IP/$PC_SSH_PORT; head -c 4 <&3" 2>/dev/null)
  fi
  [ "$out" = "SSH-" ]
}

# "Pintu balik" benar-benar terbuka di PC? (dicek dari dalam PC lewat sesi tunnel)
pc_forward_alive() {
  local first="${PC_FORWARDS%% *}" port cmd out
  port="${first%%:*}"
  if [ "$PC_OS" = "windows" ]; then
    cmd="netstat -an | findstr LISTENING | findstr :$port"
  else
    cmd="(ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep :$port"
  fi
  out=$(env "${PC_ENV[@]}" timeout 25 ssh "${PC_OPTS[@]}" -o ControlMaster=no -o ControlPath="$CTRL" "$PC_TARGET" "$cmd" 2>/dev/null)
  echo "$out" | grep -q ":$port"
}

keep_pc_tunnel() {
  [ "$PC_TUNNEL_ENABLE" = "1" ] || return 0
  [ -n "$PC_FORWARDS" ] || return 0
  build_pc_opts
  if [ "$PC_AUTH" = "key" ] && [ ! -f "$PC_KEY" ]; then ensure_keypair || return 0; fi

  if ! pc_reachable; then
    if pc_master_alive; then log "PC tidak terjangkau — menutup tunnel yang macet"; pc_stop; fi
    log_change pc "PC belum terjangkau lewat Tailscale (PC mati / Tailscale mati / OpenSSH Server mati) — menunggu"
    return 0
  fi

  # PC terjangkau lagi -> reset penundaan reconnect supaya cepat (maks 30 detik)
  rm -f "$STATE/pc.lasttry"

  if pc_master_alive && pc_forward_alive; then
    log_change pc "Tunnel ke PC SEHAT"
    rm -f "$STATE/pc.fails"
    return 0
  fi

  # Backoff: 30s, 60s, 120s, 240s, 480s ... supaya tidak membanjiri PC / flapping
  local fails last now delay
  fails=$(cat "$STATE/pc.fails" 2>/dev/null || echo 0)
  last=$(cat "$STATE/pc.lasttry" 2>/dev/null || echo 0)
  now=$(date +%s)
  delay=$((30 * (1 << (fails > 4 ? 4 : fails))))
  [ $((now - last)) -lt "$delay" ] && return 0
  echo "$now" > "$STATE/pc.lasttry"
  echo $((fails + 1)) > "$STATE/pc.fails"

  log "Tunnel ke PC mati/macet — memulai ulang (percobaan ke-$((fails + 1)))"
  pc_stop
  local fw=() spec
  for spec in $PC_FORWARDS; do fw+=(-R "$spec"); done
  if env "${PC_ENV[@]}" timeout 45 ssh -f -N "${PC_OPTS[@]}" \
        -o ExitOnForwardFailure=yes -o ControlMaster=yes -o ControlPath="$CTRL" \
        "${fw[@]}" "$PC_TARGET" </dev/null >/dev/null 2>&1 8>&- 9>&-; then
    sleep 2
    if pc_master_alive; then
      log "Tunnel ke PC menyala"
      return 0
    fi
  fi
  log_change pc "Tunnel ke PC GAGAL — $(tail -n 2 "$SSH_LOG" 2>/dev/null | tr '\n' ' ')"
}

# ============================================================================
# 5. JALUR 2 — TUNNEL PUBLIK PINGGY (TCP)
# ============================================================================
# Hidup? Cari proses tunnel pinggy MILIK KITA. Penanda unik di command line:
# opsi forwarding "-R0:localhost:<port>" — hanya dipakai tunnel pinggy ini
# (mengenali free.pinggy.io, pro.pinggy.io, token, dan host custom apa pun).
pinggy_alive() { pgrep -f -- "-R0:localhost:${PINGGY_TARGET_PORT}" >/dev/null 2>&1; }
pinggy_stop() {
  pkill -f -- "-R0:localhost:${PINGGY_TARGET_PORT}" 2>/dev/null
  pkill -f 'tcp@free\.pinggy\.io' 2>/dev/null
  pkill -f 'tcp@pro\.pinggy\.io' 2>/dev/null
  [ -n "$PINGGY_HOST" ] && pkill -f -- "tcp@$PINGGY_HOST" 2>/dev/null
  [ -n "$PINGGY_TOKEN" ] && pkill -f -- "${PINGGY_TOKEN}+tcp" 2>/dev/null
  sleep 1
  pkill -9 -f -- "-R0:localhost:${PINGGY_TARGET_PORT}" 2>/dev/null
  pkill -9 -f 'tcp@free\.pinggy\.io' 2>/dev/null
  pkill -9 -f 'tcp@pro\.pinggy\.io' 2>/dev/null
  return 0
}

pinggy_start() {
  local now last
  now=$(date +%s)
  last=$(cat "$STATE/pinggy.lasttry" 2>/dev/null || echo 0)
  [ $((now - last)) -lt 45 ] && return 0
  echo "$now" > "$STATE/pinggy.lasttry"

  pinggy_stop
  : > "$PINGGY_LOG"
  rm -f "$STATE/pinggy-url.txt" "$STATE/pinggy-ssh.txt"

  local proxy target pcmd cmd
  proxy="$(default_proxy)"
  target="tcp@${PINGGY_HOST}"
  [ -n "$PINGGY_TOKEN" ] && target="${PINGGY_TOKEN}+tcp@pro.pinggy.io"
  pcmd=""
  [ -n "$proxy" ] && pcmd="-o 'ProxyCommand=python3 $PROXY_HELPER %h %p'"
  # Perhatian: $target mengandung token — jangan pernah di-log!
  cmd="ssh -p 443 -R0:localhost:${PINGGY_TARGET_PORT} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes $pcmd -t $target"

  # 'script' memberi PTY (Pinggy hanya menampilkan alamat di terminal) + flush ke file.
  TUNNEL_PROXY="$proxy" setsid nohup script -fqec "$cmd" "$PINGGY_LOG" </dev/null >/dev/null 2>&1 8>&- 9>&- &
  date +%s > "$STATE/pinggy.started"

  local i url=""
  for i in $(seq 1 15); do
    sleep 4
    url=$(tr -d '\r' < "$PINGGY_LOG" 2>/dev/null | grep -aoE 'tcp://[A-Za-z0-9.-]+:[0-9]+' | tail -1)
    [ -n "$url" ] && break
    pinggy_alive || break
  done

  if [ -z "$url" ]; then
    log "Pinggy: GAGAL mendapat alamat publik (akan dicoba lagi otomatis)"
    return 1
  fi
  local hp host port
  hp="${url#tcp://}"; host="${hp%:*}"; port="${hp##*:}"
  echo "$url" > "$STATE/pinggy-url.txt"
  if [ "$PINGGY_TARGET_PORT" = "22" ]; then
    echo "ssh -p $port $(id -un)@$host" > "$STATE/pinggy-ssh.txt"
  fi
  log "Pinggy: alamat publik baru $url"
}

keep_pinggy() {
  [ "$PINGGY_ENABLE" = "1" ] || return 0

  # Pengaman: jangan membuka SSH ke publik bila masih menerima password
  if [ "$PINGGY_TARGET_PORT" = "22" ]; then
    if ! has_authorized_key; then
      log_change pinggy "Pinggy DITAHAN: belum ada public key di VPS. Jalankan: bash $RUN_COPY add-key"
      pinggy_alive && pinggy_stop
      return 0
    fi
    if ! sshd_password_off; then
      log_change pinggy "Pinggy DITAHAN: SSH VPS masih menerima login password (HARDEN_SSHD=0 atau gagal diterapkan)"
      pinggy_alive && pinggy_stop
      return 0
    fi
  fi

  local now age=999999 started
  now=$(date +%s)
  started=$(cat "$STATE/pinggy.started" 2>/dev/null)
  [ -n "$started" ] && age=$((now - started))

  if pinggy_alive; then
    if [ -s "$STATE/pinggy-url.txt" ] && { [ "$PINGGY_MAX_AGE" -le 0 ] || [ "$age" -lt "$PINGGY_MAX_AGE" ]; }; then
      return 0
    fi
    log "Pinggy: restart proaktif (umur tunnel ${age}s)"
  else
    log "Pinggy: tunnel mati, menyalakan"
  fi
  pinggy_start
}

# ============================================================================
# 6. CRON PENJAGA (dipasang otomatis)
# ============================================================================
CRON_TAG="# muse-tunnel-guard"

cron_ensure() {
  [ "${CRON_ENABLE:-1}" = "1" ] || return 0
  have crontab || return 0
  local cur cleaned
  cur="$(crontab -l 2>/dev/null || true)"
  # hapus cron LAMA muse_setup.sh yang bentrok (sekali saja)
  cleaned="$(echo "$cur" | grep -v 'muse_setup.sh' | grep -v 'keep-tunnel.sh' | grep -v 'pinggy-keeper' | grep -v 'nine-router-healer' | grep -v 'muse-bridge-poller' | grep -v 'ssh-tunnel-keeper' || true)"
  [ -z "$(echo "$cleaned" | tr -d '[:space:]')" ] && cleaned=""
  # sudah ada cron penjaga baru? cukup pastikan hasil bersih tersimpan
  if echo "$cur" | grep -qF "$CRON_TAG"; then
    [ "$cleaned" != "$cur" ] && echo "$cleaned" | crontab -
    return 0
  fi
  # pasang cron baru di akhir
  { [ -n "$cleaned" ] && echo "$cleaned"; echo "* * * * * bash $RUN_COPY start >/dev/null 2>&1 $CRON_TAG"; } | crontab - 2>/dev/null \
    && log "cron penjaga dipasang (tiap 1 menit)" || log "gagal memasang cron"
}

cron_remove() {
  have crontab || return 0
  local cur cleaned
  cur="$(crontab -l 2>/dev/null || true)"
  cleaned="$(echo "$cur" | grep -v "$CRON_TAG")"
  if [ "$cleaned" != "$cur" ]; then echo "$cleaned" | crontab -; fi
  return 0
}

# ============================================================================
# 7. DIAGNOSTIK JARINGAN
# ============================================================================
cmd_diag() {
  mkdir_all
  modul "DIAGNOSTIK JARINGAN VPS"
  local tsip; tsip="$(muse_ts_ip)"

  info "1. Proxy keluar internet:"
  local p; p="$(default_proxy)"
  [ -n "$p" ] && ok "HTTPS_PROXY=$p" || warn "tidak ada env proxy (mungkin tak diperlukan)"

  info "2. Tailscale di VPS:"
  if have tailscale; then
    ok "CLI tailscale ada"
    if [ -n "$tsip" ]; then ok "IP Tailscale VPS: $tsip"; else warn "IP Tailscale tidak terdeteksi (belum login?)"; fi
    if tailscale status >/dev/null 2>&1; then ok "tailscaled merespons"; else warn "tailscaled tidak merespons"; fi
  else
    warn "CLI tailscale tidak ada — jalur langsung (JALUR 0) tidak tersedia"
  fi

  info "3. Koneksi keluar ke PC ($PC_TAILSCALE_IP):"
  if pc_reachable; then ok "sshd PC terjangkau lewat Tailscale"; else warn "PC belum terjangkau — cek IP/user, Tailscale PC, sshd PC"; fi

  info "4. Konektivitas internet (ping 1.1.1.1):"
  if ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then ok "internet OK"
  elif curl -sm5 https://ifconfig.me >/dev/null 2>&1; then ok "internet OK (HTTP)"
  else warn "tidak ada internet langsung — Pinggy butuh proxy HTTPS_PROXY"; fi

  info "5. Pinggy server (${PINGGY_HOST} port 443):"
  if timeout 8 bash -c "exec 3<>/dev/tcp/${PINGGY_HOST}/443" 2>/dev/null; then ok "port 443 pinggy terjangkau"
  else
    local px; px="$(default_proxy)"
    if [ -n "$px" ]; then
      if TUNNEL_PROXY="$px" timeout 12 python3 "$PROXY_HELPER" "$PINGGY_HOST" 443 </dev/null 2>/dev/null | head -c 4 | grep -q SSH; then
        ok "pinggy terjangkau lewat proxy"
      else warn "pinggy TIDAK terjangkau lewat proxy — cek env proxy"
      fi
    else
      warn "pinggy tidak terjangkau langsung"
    fi
  fi

  info "6. SSH server VPS:"
  if sshd_listening; then
    ok "sshd aktif di port 22"
    if has_authorized_key; then ok "authorized_keys terisi"; else warn "authorized_keys KOSONG — add-key dulu"; fi
    if sshd_password_off; then ok "password login mati"; else warn "password login MASIH AKTIF"; fi
  else
    gagal "sshd tidak aktif — jalankan: bash $RUN_COPY start"
  fi

  info "7. Jalur langsung dari PC (JALUR 0):"
  if [ -n "$tsip" ]; then
    info "   coba dari PC:  ssh $(id -un)@$tsip   (bila connection refused ->"
    info "   sandbox memblokir inbound; pakai JALUR 1/2: bash $RUN_COPY url"
  fi
  echo
}

# ============================================================================
# 8. PENJAGA (daemon) + KENDALI
# ============================================================================
ensure_once() {
  mkdir_all
  [ -f "$PROXY_HELPER" ] || write_proxy_helper
  (
    flock -n 9 || exit 0
    ensure_sshd >/dev/null 2>&1 || true
    sync_root_keys
    keep_pc_tunnel
    keep_pinggy
    cron_ensure
  ) 9>"$STATE/ensure.lock"
}

daemon_alive() {
  local p; p="$(cat "$DAEMON_PID" 2>/dev/null)"
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null \
    && tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'muse_tunnel.sh daemon'
}

cmd_daemon() {
  mkdir_all
  exec 8>"$STATE/daemon.lock"
  flock -n 8 || exit 0
  echo $$ > "$DAEMON_PID"
  trap 'rm -f "$DAEMON_PID"; kill $(jobs -p) 2>/dev/null; exit 0' TERM INT
  log "penjaga tunnel dimulai (pid $$, cek tiap ${CHECK_INTERVAL}s)"
  while :; do
    ensure_once
    rotate_log
    sleep "$CHECK_INTERVAL" &
    wait $!
  done
}

cmd_start() {
  mkdir_all
  if daemon_alive; then
    [ -t 1 ] && ok "Penjaga tunnel sudah berjalan (pid $(cat "$DAEMON_PID"))"
    return 0
  fi
  local runner="$SELF"
  [ -f "$RUN_COPY" ] && runner="$RUN_COPY"
  setsid nohup bash "$runner" daemon >> "$LOG" 2>&1 </dev/null 8>&- 9>&- &
  sleep 2
  if daemon_alive; then
    [ -t 1 ] && ok "Penjaga tunnel dinyalakan"
  else
    [ -t 1 ] && warn "Penjaga belum terlihat menyala — cek $LOG"
  fi
  return 0
}

cmd_stop() {
  local p; p="$(cat "$DAEMON_PID" 2>/dev/null)"
  if [ -n "$p" ]; then
    # matikan pemeriksaan yang sedang berjalan dulu, supaya tidak menyalakan
    # tunnel lagi sesaat setelah dihentikan
    pkill -P "$p" 2>/dev/null
    kill "$p" 2>/dev/null
  fi
  rm -f "$DAEMON_PID"
  cron_remove
  build_pc_opts
  pc_stop
  pinggy_stop
  ok "Tunnel dihentikan (cron penjaga juga dilepas — pasang lagi: cron-install)"
}

cmd_cron_install() {
  mkdir_all
  have crontab || { gagal "crontab tidak tersedia di sistem ini"; return 1; }
  cron_ensure
  if crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then ok "Cron penjaga dipasang (tiap 1 menit)"
  else gagal "Gagal memasang cron — cek: crontab -l"; return 1; fi
}

# ============================================================================
# 7. STATUS & ALAMAT
# ============================================================================
cmd_url() {
  local v first port tsip
  v="$(id -un)"
  first="${PC_FORWARDS%% *}"; port="${first%%:*}"
  tsip="$(muse_ts_ip)"
  echo
  if [ -n "$tsip" ]; then
    echo "  Jalur 0 (langsung, dari PC via Tailscale) : ssh $v@$tsip"
    echo "             (bila refused -> inbound diblokir, pakai Jalur 1/2)"
  fi
  echo "  Jalur 1 (dari PC, lewat pintu balik)       : ssh -p $port $v@localhost"
  if [ -s "$STATE/pinggy-ssh.txt" ]; then
    echo "  Jalur 2 (dari mana saja, Pinggy)           : $(cat "$STATE/pinggy-ssh.txt")"
  elif [ -s "$STATE/pinggy-url.txt" ]; then
    echo "  Jalur 2 (Pinggy)                           : $(cat "$STATE/pinggy-url.txt")"
  else
    echo "  Jalur 2 (Pinggy)                           : belum ada alamat"
  fi
  echo
}

cmd_status() {
  mkdir_all
  build_pc_opts
  modul "STATUS TUNNEL VPS"
  if daemon_alive; then ok "Penjaga tunnel: berjalan (pid $(cat "$DAEMON_PID"))"
  else warn "Penjaga tunnel: MATI — nyalakan: bash $RUN_COPY start"; fi

  if sshd_listening; then ok "SSH server VPS: aktif di port 22"; else gagal "SSH server VPS: belum aktif"; fi
  if has_authorized_key; then ok "Public key terdaftar di VPS"; else warn "Belum ada public key di VPS — jalankan: add-key"; fi
  if sshd_password_off; then ok "Login password SSH: dimatikan (aman)"; else warn "Login password SSH: MASIH AKTIF"; fi

  echo
  if [ "$PC_TUNNEL_ENABLE" = "1" ]; then
    if pc_reachable; then ok "PC ($PC_TAILSCALE_IP) terjangkau lewat Tailscale"
    else warn "PC ($PC_TAILSCALE_IP) belum terjangkau (PC mati / Tailscale / OpenSSH Server?)"; fi
    if pc_master_alive; then
      if pc_forward_alive; then ok "Jalur 1: tunnel ke PC SEHAT (port ${PC_FORWARDS%%:*} terbuka di PC)"
      else warn "Jalur 1: tunnel hidup tapi pintu di PC belum terbuka — penjaga akan memperbaiki"; fi
    else
      warn "Jalur 1: tunnel ke PC belum menyala"
    fi
  else
    info "Jalur 1: dimatikan (PC_TUNNEL_ENABLE=0)"
  fi

  echo
  if [ "${CRON_ENABLE:-1}" = "1" ] && have crontab && crontab -l 2>/dev/null | grep -qF "$CRON_TAG"; then
    ok "Cron penjaga: terpasang (tiap 1 menit)"
  else
    warn "Cron penjaga: belum terpasang — jalankan: bash $RUN_COPY cron-install"
  fi

  echo
  if [ "$PINGGY_ENABLE" = "1" ]; then
    if pinggy_alive && [ -s "$STATE/pinggy-url.txt" ]; then
      local st age=0
      st=$(cat "$STATE/pinggy.started" 2>/dev/null); [ -n "$st" ] && age=$(( $(date +%s) - st ))
      ok "Jalur 2: Pinggy menyala (umur ${age}s) — $(cat "$STATE/pinggy-url.txt")"
    else
      warn "Jalur 2: Pinggy belum menyala (lihat catatan terakhir di bawah)"
    fi
  else
    info "Jalur 2: dimatikan (PINGGY_ENABLE=0)"
  fi

  cmd_url
  if [ -f "$LOG" ]; then
    info "Catatan terakhir ($LOG):"
    tail -n 6 "$LOG" | sed 's/^/    /'
  fi
}

# ============================================================================
# 8. PASANG (default)
# ============================================================================
write_conf_template() {
  [ -f "$CONF" ] && return 0
  cat > "$CONF" <<EOF
# tunnel.env — override konfigurasi muse_tunnel.sh.
# Hapus tanda # di depan baris yang mau diubah. File ini tidak pernah ditimpa.
#PC_USER="$PC_USER"
#PC_TAILSCALE_IP="$PC_TAILSCALE_IP"
#PC_SSH_PORT=$PC_SSH_PORT
#PC_OS="$PC_OS"
#PC_AUTH="$PC_AUTH"
#TAILSCALE_PROXY_PORT=$TAILSCALE_PROXY_PORT
#TS_PROXY_OVERRIDE=""
#PC_TUNNEL_ENABLE=$PC_TUNNEL_ENABLE
#PC_FORWARDS="$PC_FORWARDS"
#PINGGY_ENABLE=$PINGGY_ENABLE
#PINGGY_TOKEN=""
#PINGGY_TARGET_PORT=$PINGGY_TARGET_PORT
#PINGGY_MAX_AGE=$PINGGY_MAX_AGE
#HARDEN_SSHD=$HARDEN_SSHD
#CHECK_INTERVAL=$CHECK_INTERVAL
#CRON_ENABLE=$CRON_ENABLE
#MUSE_TAILSCALE_IP="$MUSE_TAILSCALE_IP"
EOF
  chmod 600 "$CONF"
}

detect_old_setup() {
  local f found=0
  for f in "$WS/pinggy-keeper.sh" "$WS/9router/ssh-tunnel/keep-tunnel.sh"; do
    [ -f "$f" ] && found=1
  done
  if [ "$found" = "1" ]; then
    warn "Terdeteksi sisa setup lama (muse_setup.sh). Hapus cron lamanya"
    warn "(ssh-tunnel-keeper, pinggy-keeper, nine-router-healer, muse-bridge-poller)"
    warn "dan matikan tunnel lama — kalau tidak, bentrok di port 2222 dan proses 'pinggy'."
  fi
}

cmd_install() {
  echo -e "${C_HEAD}============================================================${C_OFF}"
  echo -e "${C_HEAD}  MUSE TUNNEL — akses VPS Muse dari PC / dari mana saja${C_OFF}"
  echo -e "${C_HEAD}============================================================${C_OFF}"
  info "Aman dijalankan berulang: yang sudah ada tidak ditimpa, hanya diperiksa."

  modul "1. Folder persisten"
  mkdir_all
  ok "Semua file tunnel ada di $DIR_TUNNEL (tidak hilang saat restart)"
  detect_old_setup

  modul "2. Paket & SSH server VPS"
  ensure_packages && ok "Paket yang dibutuhkan lengkap" || warn "Sebagian paket belum terpasang — lihat $LOG"
  ensure_sshd >/dev/null 2>&1
  if sshd_listening; then ok "SSH server VPS aktif di port 22"; else warn "SSH server VPS belum aktif — cek: $LOG"; fi

  modul "3. Alat & kunci"
  write_proxy_helper && ok "Penembus proxy SSH siap"
  write_conf_template && ok "Konfigurasi override: $CONF"
  ensure_keypair
  ensure_askpass
  if [ -f "$SELF" ] && [ "$SELF" != "$RUN_COPY" ]; then
    cp "$SELF" "$RUN_COPY" && chmod +x "$RUN_COPY" && ok "Salinan script persisten: $RUN_COPY"
  elif [ ! -f "$RUN_COPY" ]; then
    warn "Script dijalankan dari sumber non-file; simpan sebagai $RUN_COPY agar penjaga bisa hidup lagi setelah restart"
  fi

  modul "4. Akses PC -> VPS"
  if has_authorized_key; then
    ok "Sudah ada public key terdaftar di VPS"
  elif [ -t 0 ]; then
    info "Agar PC bisa SSH ke VPS, VPS perlu public key PC kamu."
    info "(PowerShell PC: type \$env:USERPROFILE\\.ssh\\id_ed25519.pub — belum ada? ssh-keygen -t ed25519)"
    local k=""
    read -r -p "  Tempel public key PC (Enter = lewati): " k < /dev/tty || true
    if [ -n "$k" ]; then cmd_add_key "$k"; else warn "Dilewati — Pinggy baru menyala setelah ada key (add-key)"; fi
  else
    warn "Belum ada public key. Jalankan nanti: bash $RUN_COPY add-key \"ssh-ed25519 AAAA...\""
  fi

  modul "5. Nyalakan tunnel"
  ensure_once
  cmd_start

  cmd_status
  pc_instructions
  echo
  info "Selesai. Cron penjaga dipasang otomatis tiap 1 menit:"
  info "  * * * * * bash $RUN_COPY start >/dev/null 2>&1"
}

usage() {
  cat <<EOF
Pemakaian: bash muse_tunnel.sh [perintah]

  (kosong)       pasang + nyalakan semua tunnel + cron penjaga
  status         lihat kondisi tunnel
  url            tampilkan perintah SSH untuk masuk ke VPS
  add-key [KEY]  daftarkan public key PC ke VPS
  start|stop|restart
  ensure         satu kali pemeriksaan/perbaikan (tanpa daemon)
  diag           diagnostik jaringan (proxy/Tailscale/Pinggy/sshd)
  cron-install   pasang cron penjaga (tiap 1 menit)
  cron-remove    hapus cron penjaga
  set-password   simpan password PC (hanya bila PC_AUTH="password")
  pc-setup       langkah yang perlu dilakukan di PC
  pc-info        (di PC) deteksi otomatis PC_USER & PC_TAILSCALE_IP
EOF
}

main() {
  local cmd="${1:-install}"
  shift || true
  case "$cmd" in
    install)       cmd_install ;;
    start)         cmd_start ;;
    stop)          cmd_stop ;;
    restart)       cmd_stop; sleep 2; cmd_start ;;
    status)        cmd_status ;;
    url)           mkdir_all; cmd_url ;;
    ensure)        ensure_once ;;
    diag)          cmd_diag ;;
    daemon)        cmd_daemon ;;
    add-key)       cmd_add_key "${1:-}" ;;
    set-password)  cmd_set_password ;;
    cron-install)  cmd_cron_install ;;
    cron-remove)   cron_remove; ok "Cron penjaga dihapus" ;;
    pc-setup)      mkdir_all; ensure_keypair; pc_instructions ;;
    pc-info)       cmd_pc_info ;;
    -h|--help|help) usage ;;
    *)             gagal "Perintah tidak dikenal: $cmd"; usage; return 1 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
