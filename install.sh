#!/usr/bin/env bash
# =============================================================================
# ubuntu-server-setup — installer interaktif untuk VPS Ubuntu Server 24.04+
#
# Semua langkah idempotent: aman dijalankan berulang kali. Konfigurasi ditulis
# dalam blok bertanda sehingga isi manual di luar blok tidak tersentuh, dan
# setiap file yang diubah dibackup dulu.
#
# Cakupan: system (swap/zram/timezone), paket dasar, alias bash+fish,
# GitHub (gh + SSH key + commit signing), Docker, tool dev, tool ops,
# keamanan (ufw/fail2ban/unattended-upgrades/hardening SSH).
#
# Pemakaian:
#   sudo ./install.sh                 menu interaktif
#   sudo ./install.sh --all           semua komponen, default aman
#   sudo ./install.sh --only=base,shell --dry-run
#   ./install.sh --help
# =============================================================================

set -Eeuo pipefail

readonly SCRIPT_VERSION="2.3.0"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
TS=$(date +%Y%m%d-%H%M%S)
readonly TS
readonly LOG_DIR="${SCRIPT_DIR}/logs"
readonly LOG="${LOG_DIR}/install-${TS}.log"
readonly BACKUP_DIR="${SCRIPT_DIR}/backups/${TS}"

# Penanda blok terkelola. Isi di antara penanda akan ditimpa saat rerun.
readonly MARK_BEGIN="# >>> ubuntu-server-setup >>>"
readonly MARK_END="# <<< ubuntu-server-setup <<<"

readonly VALID_STEPS=(system base shell github docker dev ops security)

# ---------------------------------------------------------------------------
# Opsi
# ---------------------------------------------------------------------------
DRY_RUN=0
ASSUME_YES=0
INTERACTIVE=0
SELECTED=()

OPT_ALIAS_OVERRIDE=""
OPT_DELTA_PAGER=""
OPT_STARSHIP=0
OPT_FISH_DEFAULT=1
OPT_SSH_PASSPHRASE=""

OPT_SWAP=1
OPT_ZRAM=1
OPT_TZ=0
SWAP_SIZE="2G"
TZ_VALUE="Asia/Jakarta"

SEC_UFW=1
SEC_UFW_WEB=1
SEC_FAIL2BAN=1
SEC_UNATTENDED=1
SEC_SSH_HARDEN=0
SSH_PORT=""

# Target user: root, user lain, atau user baru (dipilih lewat TUI bila root).
TARGET_MODE=""
TARGET_USER=""
TARGET_HOME=""
TARGET_GROUP=""
TARGET_USER_ARG=""
NEW_USER_PASSWORD=""

case "$(uname -m)" in
  x86_64)        ARCH_DEB=amd64; ARCH_GO=x86_64;  ARCH_RUST=x86_64;  ARCH_FF=amd64;  ARCH_BIN=x86_64 ;;
  aarch64|arm64) ARCH_DEB=arm64; ARCH_GO=arm64;   ARCH_RUST=aarch64; ARCH_FF=aarch64; ARCH_BIN=arm64  ;;
  *) echo "Arsitektur $(uname -m) belum didukung." >&2; exit 1 ;;
esac

mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'; C_CYAN=$'\e[36m'
else
  C_RESET=; C_BOLD=; C_DIM=; C_RED=; C_GREEN=; C_YELLOW=; C_BLUE=; C_CYAN=
fi

_log_raw() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >>"$LOG"; }
info() { _log_raw "[INFO] $*"; printf '%s\n' "${C_CYAN}•${C_RESET} $*"; }
ok()   { _log_raw "[ OK ] $*"; printf '%s\n' "${C_GREEN}✔${C_RESET} $*"; }
warn() { _log_raw "[WARN] $*"; printf '%s\n' "${C_YELLOW}!${C_RESET} $*" >&2; }
err()  { _log_raw "[FAIL] $*"; printf '%s\n' "${C_RED}✘${C_RESET} $*" >&2; }
die()  { err "$*"; exit 1; }
step() {
  printf '\n%s\n' "${C_BOLD}${C_BLUE}▶ $*${C_RESET}"
  printf '%s\n' "${C_DIM}────────────────────────────────────────────────────────────${C_RESET}"
  _log_raw "=== $* ==="
}

on_err() {
  local ec=$?
  err "perintah gagal (exit ${ec}) di baris ${1:-?}: ${BASH_COMMAND}"
  printf '%s\n' "${C_DIM}log lengkap: ${LOG}${C_RESET}" >&2
}
trap 'on_err $LINENO' ERR

SUDO_KEEPALIVE_PID=""
cleanup() {
  if [[ -n ${SUDO_KEEPALIVE_PID} ]] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
  # gum sementara yang diunduh saat --dry-run
  if [[ -n ${GUM_TMPDIR:-} ]]; then
    rm -rf "$GUM_TMPDIR"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helper eksekusi
# ---------------------------------------------------------------------------

# Jalankan perintah: tampilkan output, salin ke log, hormati --dry-run.
run() {
  _log_raw "+ $*"
  if (( DRY_RUN )); then
    printf '%s\n' "${C_DIM}  [dry-run] $*${C_RESET}"
    return 0
  fi
  local rc=0
  set +e
  "$@" 2>&1 | tee -a "$LOG"
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

# Perintah yang hanya menulis konfigurasi (aman dilewati saat dry-run).
run_write() {
  _log_raw "+ $*"
  if (( DRY_RUN )); then
    printf '%s\n' "${C_DIM}  [dry-run] $*${C_RESET}"
    return 0
  fi
  "$@"
}

# Jalankan sebagai root, baik script dipanggil sebagai root maupun via sudo.
as_root() {
  if (( EUID == 0 )); then
    "$@"
  else
    sudo "$@"
  fi
}

# Jalankan perintah dengan HOME/USER milik target user (dipakai untuk
# git config --global, gh, ssh) walaupun script berjalan sebagai root.
as_target() {
  env HOME="$TARGET_HOME" USER="$TARGET_USER" LOGNAME="$TARGET_USER" \
      XDG_CONFIG_HOME="${TARGET_HOME}/.config" "$@"
}

git_cfg() { run_write as_target git config --global "$@"; }

backup_file() {
  local f=$1
  [[ -e $f ]] || return 0
  if (( DRY_RUN )); then
    info "[dry-run] backup ${f}"
    return 0
  fi
  local dest="${BACKUP_DIR}/${f#/}"
  mkdir -p "$(dirname "$dest")"
  cp -a "$f" "$dest"
  _log_raw "backup: $f -> $dest"
}

# Ganti (atau tambahkan) blok terkelola di sebuah file. Isi di luar blok
# tidak disentuh, jadi config manual pengguna tetap aman.
write_block() {
  local file=$1 content=$2
  info "tulis blok terkelola: ${file}"
  if (( DRY_RUN )); then
    printf '%s\n' "${C_DIM}  [dry-run] ${#content} byte konten${C_RESET}"
    return 0
  fi
  backup_file "$file"
  mkdir -p "$(dirname "$file")"

  local tmp; tmp=$(mktemp)
  if [[ -f $file ]]; then
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" \
      '$0==b{s=1;next} $0==e{s=0;next} !s{print}' "$file" >"$tmp"
  fi

  # buang baris kosong di akhir agar tidak menumpuk tiap kali dijalankan
  local trimmed; trimmed=$(mktemp)
  awk 'NF{last=NR} {line[NR]=$0} END{for(i=1;i<=last;i++) print line[i]}' "$tmp" >"$trimmed"
  rm -f "$tmp"
  if [[ -s $trimmed ]]; then
    printf '\n' >>"$trimmed"
  fi

  {
    printf '%s\n' "$MARK_BEGIN"
    printf '%s\n' "$content"
    printf '%s\n' "$MARK_END"
  } >>"$trimmed"

  if [[ -f $file ]]; then
    cat "$trimmed" >"$file"          # pertahankan permission file lama
  else
    install -m 0644 "$trimmed" "$file"
  fi
  rm -f "$trimmed"
}

# Tulis file sistem (di /etc) memakai hak root, dengan backup otomatis.
write_root_file() {
  local path=$1 content=$2 mode=${3:-0644}
  info "tulis ${path}"
  if (( DRY_RUN )); then
    printf '%s\n' "${C_DIM}  [dry-run] ${path}${C_RESET}"
    _log_raw "---- ${path} ----"
    _log_raw "$content"
    return 0
  fi
  local tmp; tmp=$(mktemp)
  printf '%s\n' "$content" >"$tmp"
  if as_root test -f "$path"; then
    mkdir -p "${BACKUP_DIR}/etc"
    local dest
    dest="${BACKUP_DIR}/etc/$(printf '%s' "$path" | tr '/' '_')"
    as_root cp -a "$path" "$dest"
    as_root chown "$(id -u):$(id -g)" "$dest" 2>/dev/null || true
  fi
  as_root install -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
}

# Ambil baris pertama dari stdin tanpa memicu SIGPIPE di produsen
# (penting karena script memakai `set -o pipefail`).
first_line() { awk 'NR==1{v=$0} END{if (NR) print v}'; }

apt_update() {
  run as_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get update
}

apt_install() {
  local pkgs=("$@") missing=() p
  for p in "${pkgs[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || missing+=("$p")
  done
  if ((${#missing[@]} == 0)); then
    ok "sudah terpasang: ${pkgs[*]}"
    return 0
  fi
  info "memasang: ${missing[*]}"
  run as_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    apt-get install -y "${missing[@]}"
}

# Paket "nice to have": yang tidak ada di repo dilewati, bukan menggagalkan
# seluruh langkah (mis. btop/duf/just di Ubuntu 22.04).
apt_install_optional() {
  local want=("$@") have=() p cand
  for p in "${want[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" && continue
    cand=$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/{v=$2} END{if (v!="") print v}')
    if [[ -z $cand || $cand == "(none)" ]]; then
      warn "tidak tersedia di repo: ${p} — dilewati"
      continue
    fi
    have+=("$p")
  done
  ((${#have[@]})) || return 0
  info "memasang (opsional): ${have[*]}"
  run as_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
    apt-get install -y "${have[@]}" || warn "sebagian paket opsional gagal dipasang"
}

gh_release_json() {
  local repo=$1
  if command -v gh >/dev/null 2>&1 && as_target gh auth status >/dev/null 2>&1; then
    as_target gh api "repos/${repo}/releases/latest" 2>/dev/null
  else
    curl -fsSL --max-time 20 "https://api.github.com/repos/${repo}/releases/latest"
  fi
}

# Unduh rilis GitHub terbaru lalu pasang binary ke ~/.local/bin target user.
install_gh_release() {
  local repo=$1 asset_re=$2 bin=$3 dest="${TARGET_HOME}/.local/bin"

  if [[ -x ${dest}/${bin} ]]; then
    ok "${bin} sudah ada di ${dest}/${bin}"
    return 0
  fi
  if [[ $bin == fastfetch ]] && command -v fastfetch >/dev/null 2>&1; then
    ok "fastfetch sudah ada: $(command -v fastfetch)"
    return 0
  fi
  if (( DRY_RUN )); then
    info "[dry-run] unduh rilis ${repo} (${asset_re}) → ${dest}/${bin}"
    return 0
  fi
  ensure_download_tools
  command -v jq >/dev/null 2>&1 || { warn "jq dibutuhkan untuk memasang ${bin}"; return 1; }

  local json url name
  json=$(gh_release_json "$repo") || { warn "gagal query rilis ${repo}"; return 1; }
  url=$(printf '%s' "$json" | jq -r --arg re "$asset_re" \
        '.assets[]? | select(.name|test($re)) | .browser_download_url' | first_line)
  if [[ -z $url || $url == null ]]; then
    warn "aset '${asset_re}' tidak ditemukan di rilis ${repo}"
    return 1
  fi
  name=$(basename "$url")

  local tmp; tmp=$(mktemp -d)
  if ! run curl -fsSL --retry 3 --max-time 180 "$url" -o "${tmp}/${name}"; then
    warn "unduh gagal: ${url}"; rm -rf "$tmp"; return 1
  fi

  mkdir -p "$dest"
  case $name in
    *.deb)
      run as_root env DEBIAN_FRONTEND=noninteractive dpkg -i "${tmp}/${name}" \
        || { warn "dpkg gagal: ${name}"; rm -rf "$tmp"; return 1; }
      ;;
    *.tar.gz|*.tgz)
      run tar -xzf "${tmp}/${name}" -C "$tmp" \
        || { warn "ekstrak gagal: ${name}"; rm -rf "$tmp"; return 1; }
      local found
      found=$(find "$tmp" -type f -name "$bin" -print -quit)
      if [[ -z $found ]]; then
        warn "binary '${bin}' tidak ada di arsip"
        rm -rf "$tmp"
        return 1
      fi
      run install -m 0755 "$found" "${dest}/${bin}"
      ;;
    *)
      run install -m 0755 "${tmp}/${name}" "${dest}/${bin}"
      ;;
  esac
  rm -rf "$tmp"
  ok "${bin} → ${dest}/${bin}"
}

link_bin() {
  local src=$1 dest=$2 dir="${TARGET_HOME}/.local/bin"
  command -v "$src" >/dev/null 2>&1 || return 0
  if (( DRY_RUN )); then
    info "[dry-run] symlink ${dest} → $(command -v "$src")"
    return 0
  fi
  mkdir -p "$dir"
  if [[ -x ${dir}/${dest} ]]; then
    ok "symlink ${dest} sudah ada"
    return 0
  fi
  run ln -sf "$(command -v "$src")" "${dir}/${dest}"
}

want() {
  local s
  for s in "${SELECTED[@]}"; do [[ $s == "$1" ]] && return 0; done
  return 1
}

sudo_keepalive() {
  sudo -v || die "sudo diperlukan tapi ditolak"
  ( while sleep 45; do sudo -n true 2>/dev/null || exit; done ) &
  SUDO_KEEPALIVE_PID=$!
}

# Saat root mengonfigurasi user lain, file yang dibuat root harus
# dikembalikan kepemilikannya ke user tersebut.
finalize_ownership() {
  (( EUID == 0 )) || return 0
  [[ $TARGET_USER == root ]] && return 0
  (( DRY_RUN )) && return 0
  local paths=(
    "$TARGET_HOME/.bashrc" "$TARGET_HOME/.bash_aliases" "$TARGET_HOME/.profile"
    "$TARGET_HOME/.gitconfig" "$TARGET_HOME/.ssh" "$TARGET_HOME/.config/fish"
    "$TARGET_HOME/.local/bin" "$TARGET_HOME/.local/state" "$TARGET_HOME/.config/gh"
  )
  local p
  for p in "${paths[@]}"; do
    if [[ -e $p ]]; then
      chown -R "$TARGET_USER:$TARGET_GROUP" "$p" 2>/dev/null || true
    fi
  done
  if [[ $TARGET_MODE == create ]]; then
    chown "$TARGET_USER:$TARGET_GROUP" "$TARGET_HOME" 2>/dev/null || true
  fi
}

step_label() {
  case $1 in
    system)   printf 'System: swap, zram, timezone, sysctl' ;;
    base)     printf 'Paket dasar CLI & utilitas' ;;
    shell)    printf 'Alias & hook bash + fish' ;;
    github)   printf 'GitHub: gh, SSH key, commit signing' ;;
    docker)   printf 'Docker: instal/verifikasi, dive, lazydocker' ;;
    dev)      printf 'Tool dev: lazygit, delta, just, httpie, atuin, starship' ;;
    ops)      printf 'Tool ops: sysstat, iotop, strace, lsof, glances, mtr, nmap, restic' ;;
    security) printf 'Keamanan: ufw, fail2ban, unattended-upgrades, SSH' ;;
    *)        printf '%s' "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Lapisan UI: gum (Charmbracelet/Bubble Tea) + fallback whiptail
# ---------------------------------------------------------------------------
UI_BACKEND=""
GUM_BIN=""
GUM_TMPDIR=""
UI_RESULT=()
UI_VALUE=""

ensure_gum() {
  if command -v gum >/dev/null 2>&1; then
    GUM_BIN=$(command -v gum)
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    (( DRY_RUN )) && return 1
    apt_install ca-certificates curl \
      || { apt_update || true; apt_install ca-certificates curl || true; }
  fi
  command -v curl >/dev/null 2>&1 || { warn "curl tidak ada — gum tidak bisa diunduh"; return 1; }

  local tag ver asset url tmp found bindir
  tag=$(curl -fsSL --max-time 20 \
        https://api.github.com/repos/charmbracelet/gum/releases/latest 2>/dev/null \
        | grep -o '"tag_name": *"[^"]*"' | first_line | sed 's/.*"\(v[^"]*\)".*/\1/') || true
  [[ -n $tag ]] || tag="v2.0.2"
  ver=${tag#v}
  asset="gum_${ver}_Linux_${ARCH_BIN}.tar.gz"
  url="https://github.com/charmbracelet/gum/releases/download/${tag}/${asset}"

  info "mengunduh TUI gum ${tag} (${ARCH_BIN})"
  tmp=$(mktemp -d)
  if ! curl -fsSL --retry 3 --max-time 120 "$url" -o "${tmp}/${asset}" \
     || ! tar -xzf "${tmp}/${asset}" -C "$tmp"; then
    warn "gagal mengunduh/mengekstrak gum: ${url}"
    rm -rf "$tmp"
    return 1
  fi
  found=$(find "$tmp" -type f -name gum -print -quit)
  if [[ -z $found ]]; then
    warn "binary gum tidak ditemukan di arsip"
    rm -rf "$tmp"
    return 1
  fi

  if (( DRY_RUN )); then
    # jangan ubah sistem saat --dry-run: pakai gum dari direktori sementara
    bindir=$(mktemp -d "${TMPDIR:-/tmp}/gum-bin.XXXXXX")
    GUM_TMPDIR=$bindir
  elif (( EUID == 0 )) && [[ -w /usr/local/bin ]]; then
    bindir=/usr/local/bin
  else
    bindir="${HOME}/.local/bin"
    mkdir -p "$bindir"
  fi

  if ! install -m 0755 "$found" "${bindir}/gum"; then
    rm -rf "$tmp"
    warn "gagal memasang gum ke ${bindir}"
    return 1
  fi
  rm -rf "$tmp"
  hash -r 2>/dev/null || true
  GUM_BIN="${bindir}/gum"
  [[ -x $GUM_BIN ]] || return 1
  if (( DRY_RUN )); then
    ok "gum ${tag} dipakai dari ${bindir} (sementara, dry-run tidak mengubah sistem)"
    GUM_BIN=$(command -v gum 2>/dev/null || printf '%s' "$GUM_BIN")
  else
    ok "gum ${tag} terpasang → ${bindir}/gum"
  fi
  return 0
}

# Pilih backend TUI. gum diutamakan (Bubble Tea), whiptail hanya cadangan.
ui_init() {
  local prefer=${UBUNTU_SETUP_UI:-auto}

  if [[ $prefer == whiptail ]]; then
    if ! command -v whiptail >/dev/null 2>&1 && (( ! DRY_RUN )); then
      apt_install whiptail || { apt_update || true; apt_install whiptail || true; }
    fi
    if command -v whiptail >/dev/null 2>&1; then
      UI_BACKEND=whiptail
      _log_raw "ui: whiptail (dipaksa lewat UBUNTU_SETUP_UI)"
      return 0
    fi
    warn "UBUNTU_SETUP_UI=whiptail tetapi whiptail tidak tersedia — memakai gum"
  fi

  if command -v gum >/dev/null 2>&1; then
    GUM_BIN=$(command -v gum)
    UI_BACKEND=gum
  elif ensure_gum; then
    UI_BACKEND=gum
  elif command -v whiptail >/dev/null 2>&1; then
    UI_BACKEND=whiptail
  else
    if (( ! DRY_RUN )); then
      apt_install whiptail || { apt_update || true; apt_install whiptail || true; }
    fi
    if command -v whiptail >/dev/null 2>&1; then
      UI_BACKEND=whiptail
    else
      return 1
    fi
  fi
  _log_raw "ui: ${UI_BACKEND}${GUM_BIN:+ (${GUM_BIN})}"
  return 0
}

# Ambil key dari satu baris hasil gum ("key — deskripsi") atau whiptail ("key").
ui_key_of() {
  local line=${1//\"/}
  line=${line%$'\r'}
  line=${line#"${line%%[![:space:]]*}"}
  printf '%s' "${line%% *}"
}

# ui_checklist JUDUL HEADER "key|deskripsi|ON" ...
# Hasil: array UI_RESULT berisi key yang dicentang.
ui_checklist() {
  local title=$1 header=$2
  shift 2
  local -a items=("$@") opts=() pre=() wargs=()
  local it key desc state

  for it in "${items[@]}"; do
    IFS='|' read -r key desc state <<<"$it"
    opts+=("${key} — ${desc}")
    if [[ ${state:-OFF} == ON ]]; then pre+=("${key} — ${desc}"); fi
    wargs+=("$key" "$desc" "${state:-OFF}")
  done

  local out="" gum_args=()
  if [[ $UI_BACKEND == gum ]]; then
    gum_args=(choose --no-limit --height 12 --header "${title} · ${header}")
    ((${#pre[@]})) && gum_args+=(--selected "$(IFS=,; printf '%s' "${pre[*]}")")
    out=$("$GUM_BIN" "${gum_args[@]}" "${opts[@]}") || die "dibatalkan"
  else
    out=$(whiptail --title "$title" --checklist "$header" 22 110 12 \
      "${wargs[@]}" 3>&1 1>&2 2>&3) || die "dibatalkan"
  fi

  UI_RESULT=()
  if [[ $UI_BACKEND == gum ]]; then
    local line
    while IFS= read -r line; do
      [[ -n ${line//[[:space:]]/} ]] || continue
      UI_RESULT+=("$(ui_key_of "$line")")
    done <<<"$out"
  else
    # whiptail mengembalikan semua tag dalam satu baris: "system" "base"
    out=${out//\"/}
    read -r -a UI_RESULT <<<"$out"
  fi
}

# ui_menu JUDUL HEADER DEFAULT "key|deskripsi" ...
# Hasil: UI_VALUE = key terpilih.
ui_menu() {
  local title=$1 header=$2 def=${3:-}
  shift 3
  local -a items=("$@") opts=() wargs=()
  local it key desc
  for it in "${items[@]}"; do
    IFS='|' read -r key desc <<<"$it"
    opts+=("${key} — ${desc}")
    wargs+=("$key" "$desc")
  done

  local out=""
  if [[ $UI_BACKEND == gum ]]; then
    local -a gum_args=(choose --height 12 --header "${title} · ${header}")
    if [[ -n $def ]]; then
      local d
      for d in "${opts[@]}"; do
        [[ ${d%% *} == "$def" ]] && { gum_args+=(--selected "$d"); break; }
      done
    fi
    out=$("$GUM_BIN" "${gum_args[@]}" "${opts[@]}") || die "dibatalkan"
  else
    local -a dargs=(--title "$title")
    [[ -n $def ]] && dargs+=(--default-item "$def")
    out=$(whiptail "${dargs[@]}" --menu "$header" 18 90 12 \
      "${wargs[@]}" 3>&1 1>&2 2>&3) || die "dibatalkan"
  fi
  UI_VALUE=$(ui_key_of "$out")
  [[ -n $UI_VALUE ]] || die "dibatalkan"
}

# ui_input JUDUL HEADER DEFAULT → UI_VALUE (kosong diizinkan)
ui_input() {
  local title=$1 header=$2 def=${3:-}
  local out=""
  if [[ $UI_BACKEND == gum ]]; then
    out=$("$GUM_BIN" input --header "${title} · ${header}" --value "$def" \
          --char-limit 128 --placeholder "ketik lalu ENTER") || out=$def
  else
    out=$(whiptail --title "$title" --inputbox "$header" 10 74 "$def" \
          3>&1 1>&2 2>&3) || die "dibatalkan"
  fi
  UI_VALUE=${out%$'\r'}
}

# ui_password JUDUL HEADER → UI_VALUE (masked, kosong diizinkan)
ui_password() {
  local title=$1 header=$2
  local out=""
  if [[ $UI_BACKEND == gum ]]; then
    out=$("$GUM_BIN" input --password --header "${title} · ${header}" \
          --placeholder "kosongkan bila tidak perlu") || out=""
  else
    out=$(whiptail --title "$title" --passwordbox "$header" 10 74 "" \
          3>&1 1>&2 2>&3) || out=""
  fi
  UI_VALUE=${out%$'\r'}
}

# ui_confirm PROMPT → exit 0 = ya, 1 = tidak
ui_confirm() {
  local prompt=$1
  if [[ $UI_BACKEND == gum ]]; then
    "$GUM_BIN" confirm "$prompt" --affirmative "Ya" --negative "Tidak" --default
  else
    whiptail --title "Konfirmasi" --yesno "$prompt" 10 70 3>&1 1>&2 2>&3
  fi
}

# ---------------------------------------------------------------------------
# Menu TUI
# ---------------------------------------------------------------------------
menu_categories() {
  ui_checklist "Ubuntu Server Setup ${SCRIPT_VERSION}" \
    "SPASI = pilih/lepas · ENTER = lanjut · ESC = batal" \
    "system|swap/zram/timezone/sysctl|ON" \
    "base|htop btop tree duf fd bat eza fzf zoxide direnv yq shellcheck pipx rsync|ON" \
    "shell|Alias & hook bash + fish (eza/bat/docker/git/mkcd/extract)|ON" \
    "github|gh + SSH key ed25519 + commit signing + ~/.ssh/config|ON" \
    "docker|Instal/verifikasi docker + dive + lazydocker|ON" \
    "dev|lazygit git-delta just httpie atuin starship|ON" \
    "ops|sysstat iotop strace lsof glances mtr nmap restic rclone|ON" \
    "security|ufw + fail2ban + unattended-upgrades + hardening SSH|ON"

  SELECTED=("${UI_RESULT[@]}")
  ((${#SELECTED[@]})) || die "tidak ada komponen yang dipilih"
}

menu_options() {
  local starship_state=ON
  if [[ -f ${TARGET_HOME:-${HOME:-/root}}/.config/fish/conf.d/_tide_init.fish ]]; then
    starship_state=OFF
  fi

  ui_checklist "Opsi tambahan" "SPASI = ubah · ENTER = lanjut · ESC = batal" \
    "alias_override|Timpa alias ls/ll/la/l/cat dengan eza/bat|ON" \
    "delta_pager|Pakai delta sebagai git pager|ON" \
    "starship|Aktifkan starship (prompt tide akan tertimpa)|${starship_state}" \
    "fish_default|Jadikan fish shell default user|ON" \
    "dry_run|Dry-run: tampilkan aksi tanpa mengubah sistem|OFF"

  OPT_ALIAS_OVERRIDE=0
  OPT_DELTA_PAGER=0
  OPT_STARSHIP=0
  OPT_FISH_DEFAULT=0

  local o
  for o in "${UI_RESULT[@]}"; do
    case $o in
      alias_override) OPT_ALIAS_OVERRIDE=1 ;;
      delta_pager)    OPT_DELTA_PAGER=1 ;;
      starship)       OPT_STARSHIP=1 ;;
      fish_default)   OPT_FISH_DEFAULT=1 ;;
      dry_run)        DRY_RUN=1 ;;
    esac
  done
  _log_raw "opsi: alias=${OPT_ALIAS_OVERRIDE} delta=${OPT_DELTA_PAGER} starship=${OPT_STARSHIP} fish_default=${OPT_FISH_DEFAULT} dry_run=${DRY_RUN}"
}

menu_system() {
  ui_checklist "System" "SPASI = pilih/lepas · ENTER = lanjut · ESC = batal" \
    "swap|Buat swapfile ${SWAP_SIZE} + swappiness|ON" \
    "zram|zram (swap terkompresi di RAM)|ON" \
    "timezone|Set timezone ${TZ_VALUE}|OFF"

  OPT_SWAP=0; OPT_ZRAM=0; OPT_TZ=0
  local o
  for o in "${UI_RESULT[@]}"; do
    case $o in
      swap) OPT_SWAP=1 ;;
      zram) OPT_ZRAM=1 ;;
      timezone) OPT_TZ=1 ;;
    esac
  done
}

menu_security() {
  ui_checklist "Keamanan" \
    "Hardening SSH hanya aman bila login key sudah terbukti bekerja" \
    "ufw|ufw: deny incoming + allow SSH|ON" \
    "ufw_web|ufw: izinkan 80/443|ON" \
    "fail2ban|fail2ban untuk sshd|ON" \
    "unattended|unattended-upgrades (patch otomatis)|ON" \
    "ssh_harden|SSH: matikan login password|OFF"

  SEC_UFW=0; SEC_UFW_WEB=0; SEC_FAIL2BAN=0; SEC_UNATTENDED=0; SEC_SSH_HARDEN=0
  local o
  for o in "${UI_RESULT[@]}"; do
    case $o in
      ufw) SEC_UFW=1 ;;
      ufw_web) SEC_UFW_WEB=1 ;;
      fail2ban) SEC_FAIL2BAN=1 ;;
      unattended) SEC_UNATTENDED=1 ;;
      ssh_harden) SEC_SSH_HARDEN=1 ;;
    esac
  done
}

ask_passphrase() {
  if (( ASSUME_YES )) || (( ! INTERACTIVE )); then
    return 0
  fi
  OPT_SSH_PASSPHRASE=""
  ui_password "SSH key" "Passphrase untuk SSH key baru (kosong = tanpa passphrase)" || true
  OPT_SSH_PASSPHRASE=$UI_VALUE
}

# ---------------------------------------------------------------------------
# Target user
# ---------------------------------------------------------------------------
detect_ssh_port() {
  local p=""
  if command -v sshd >/dev/null 2>&1; then
    if (( EUID == 0 )) || (( ! DRY_RUN )); then
      p=$(as_root sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)
    fi
  fi
  if [[ -z $p ]] && [[ -r /etc/ssh/sshd_config ]]; then
    p=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config || true)
  fi
  printf '%s' "${p:-22}"
}

generate_password() {
  LC_ALL=C tr -dc 'A-Za-z0-9!#%_+=' </dev/urandom | head -c 18 || true
}

resolve_target() {
  if (( EUID != 0 )); then
    if [[ -n $TARGET_USER_ARG && $TARGET_USER_ARG != "${USER:-$(id -un)}" ]]; then
      die "--target-user hanya bisa dipakai saat script berjalan sebagai root (sudo)"
    fi
    TARGET_MODE=current
    TARGET_USER=${USER:-$(id -un)}
    TARGET_HOME=${HOME:-$PWD}
    TARGET_GROUP=$(id -gn)
    return 0
  fi

  if [[ -n $TARGET_USER_ARG ]]; then
    TARGET_USER=$TARGET_USER_ARG
    TARGET_MODE=existing
  elif (( INTERACTIVE )); then
    local default_choice=root
    if [[ -n ${SUDO_USER:-} ]] && id "$SUDO_USER" >/dev/null 2>&1; then
      default_choice=existing
    fi
    ui_menu "Jalankan sebagai" "Script berjalan sebagai root — user mana yang disiapkan?" \
      "$default_choice" \
      "root|root (simpel tapi tidak disarankan untuk login harian)" \
      "existing|User yang sudah ada di sistem" \
      "create|Buat user admin baru (sudo + authorized_keys)"
    local choice=$UI_VALUE

    case $choice in
      existing)
        local -a users=() u
        while IFS=: read -r u _ _ _ _ _ _; do
          [[ $u == nobody ]] && continue
          users+=("${u}|$(getent passwd "$u" | cut -d: -f6)")
        done < <(awk -F: '$3>=1000 && $3<65000 {print $0}' /etc/passwd)
        if ((${#users[@]} == 0)); then
          warn "tidak ada user non-root; memakai root"
          TARGET_MODE=root
          TARGET_USER=root
        else
          ui_menu "Pilih user" "Konfigurasi disiapkan untuk user ini" \
            "${users[0]%%|*}" "${users[@]}"
          TARGET_USER=$UI_VALUE
          TARGET_MODE=existing
        fi
        ;;
      create)
        ui_input "User baru" "Nama user yang akan dibuat" "admin"
        TARGET_USER=$UI_VALUE
        [[ -n $TARGET_USER ]] || die "nama user tidak boleh kosong"
        ui_password "Password ${TARGET_USER}" "Password user baru (kosong = dibuat acak)" || true
        NEW_USER_PASSWORD=$UI_VALUE
        TARGET_MODE=create
        ;;
      *)
        TARGET_MODE=root
        TARGET_USER=root
        ;;
    esac
  else
    if [[ -n ${SUDO_USER:-} ]] && id "$SUDO_USER" >/dev/null 2>&1; then
      TARGET_MODE=existing
      TARGET_USER=$SUDO_USER
    else
      TARGET_MODE=root
      TARGET_USER=root
      warn "berjalan sebagai root tanpa --target-user → konfigurasi ditulis ke /root"
    fi
  fi

  [[ -n $TARGET_USER ]] || die "target user tidak valid"

  if id "$TARGET_USER" >/dev/null 2>&1; then
    TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    TARGET_GROUP=$(id -gn "$TARGET_USER")
    [[ $TARGET_MODE == create ]] && TARGET_MODE=existing
  else
    TARGET_MODE=create
    TARGET_HOME="/home/${TARGET_USER}"
    TARGET_GROUP="$TARGET_USER"
    [[ -n $NEW_USER_PASSWORD ]] || NEW_USER_PASSWORD=$(generate_password)
  fi
  _log_raw "target: mode=${TARGET_MODE} user=${TARGET_USER} home=${TARGET_HOME}"
}

create_target_user() {
  [[ $TARGET_MODE == create ]] || return 0
  if (( DRY_RUN )); then
    info "[dry-run] buat user ${TARGET_USER} (sudo, authorized_keys, password)"
    return 0
  fi
  if id "$TARGET_USER" >/dev/null 2>&1; then
    TARGET_MODE=existing
    return 0
  fi

  info "membuat user ${TARGET_USER}"
  local useradd_args=(-m -s /bin/bash)
  if getent group sudo >/dev/null 2>&1; then
    useradd_args+=(-G sudo)
  else
    warn "grup sudo tidak ada — ${TARGET_USER} dibuat tanpa hak sudo"
  fi
  run as_root useradd "${useradd_args[@]}" "$TARGET_USER"
  printf '%s:%s\n' "$TARGET_USER" "$NEW_USER_PASSWORD" | as_root chpasswd
  TARGET_GROUP=$(id -gn "$TARGET_USER")

  # pindahkan authorized_keys dari root / SUDO_USER agar login key tetap jalan
  local src=""
  if [[ -f /root/.ssh/authorized_keys ]]; then
    src=/root/.ssh/authorized_keys
  elif [[ -n ${SUDO_USER:-} ]] && [[ -f /home/${SUDO_USER}/.ssh/authorized_keys ]]; then
    src="/home/${SUDO_USER}/.ssh/authorized_keys"
  fi
  if [[ -n $src ]]; then
    as_root install -d -m 700 -o "$TARGET_USER" -g "$TARGET_GROUP" "$TARGET_HOME/.ssh"
    as_root install -m 600 -o "$TARGET_USER" -g "$TARGET_GROUP" "$src" "$TARGET_HOME/.ssh/authorized_keys"
    ok "authorized_keys disalin dari ${src}"
  else
    warn "authorized_keys tidak ditemukan — login key untuk ${TARGET_USER} belum siap"
  fi
  ok "user ${TARGET_USER} dibuat dan masuk grup sudo"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight() {
  step "Preflight"

  # shellcheck source=/dev/null
  [[ -r /etc/os-release ]] && . /etc/os-release 2>/dev/null || true
  if [[ ${ID:-} != ubuntu ]]; then
    warn "bukan Ubuntu (${ID:-unknown}) — script diuji di Ubuntu 24.04"
  fi
  if [[ -n ${VERSION_ID:-} ]] && (( ${VERSION_ID%%.*} < 24 )); then
    warn "Ubuntu ${VERSION_ID} terdeteksi — beberapa paket punya nama berbeda; fallback dipakai bila memungkinkan"
  fi
  info "OS      : ${PRETTY_NAME:-unknown}"
  info "Kernel  : $(uname -r) / $(uname -m)"
  info "User    : ${USER:-$(id -un)} (EUID ${EUID})"
  info "Target  : ${TARGET_USER} (${TARGET_HOME})"

  if [[ ! -d /run/systemd/system ]]; then
    warn "systemd tidak terdeteksi — beberapa langkah (docker/fail2ban/zram) mungkin gagal"
  fi

  local free_gb
  free_gb=$(df -Pk / | awk 'NR==2{printf "%d", $4/1024/1024}')
  if (( free_gb < 5 )); then
    warn "ruang disk tersisa ${free_gb}GB (disarankan >= 5GB)"
  else
    info "Disk    : ${free_gb}GB bebas di /"
  fi

  if (( EUID != 0 )) && (( ! DRY_RUN )); then
    sudo_keepalive
  fi

  create_target_user
  SSH_PORT=${SSH_PORT:-$(detect_ssh_port)}
  info "SSH port: ${SSH_PORT}"

  if (( DRY_RUN )); then
    warn "MODE DRY-RUN aktif: tidak ada perubahan pada sistem"
  else
    apt_update
  fi
}

# ---------------------------------------------------------------------------
# Konten shell (bash + fish)
# ---------------------------------------------------------------------------
fish_aliases_content() {
  if (( OPT_ALIAS_OVERRIDE )); then
    cat <<'EOF'
# eza (pengganti ls)
alias ls="eza --icons --group-directories-first"
alias ll="eza -lah --git --group-directories-first"
alias la="eza -a --group-directories-first"
alias l="eza -1 --group-directories-first"
alias lt="eza --tree --level=2"
# bat (pengganti cat)
alias cat="bat --style=plain --paging=never"
alias catp="bat"
EOF
  else
    cat <<'EOF'
# Override ls/cat dimatikan. Alias eza/bat tetap tersedia dengan nama lain.
alias lse="eza --icons --group-directories-first"
alias lle="eza -lah --git --group-directories-first"
alias lte="eza --tree --level=2"
alias batp="bat"
EOF
  fi

  cat <<'EOF'

# docker
alias dcdown="docker compose down"
alias dcup="docker compose up -d"
alias dl="docker ps"
alias dla="docker ps -a"
alias dr="docker rm"
alias dps="docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'"
alias di="docker images"
alias dlog="docker logs -f --tail=100"
alias dex="docker exec -it"
alias dprune="docker system prune -af --volumes"
alias dcl="docker compose logs -f --tail=100"
alias dcr="docker compose restart"

# git
alias ga="git add ."
alias gc="git commit -m"
alias gcs="git commit -S -m"
alias gs="git status"
alias gl='git log --graph --pretty="%C(yellow) Hash: %h %C(blue)Date: %ad %C(white) Message: %s " --date=human'
alias gst="git status -sb"
alias gco="git checkout"
alias gsw="git switch"
alias gb="git branch -vv"
alias gd="git diff"
alias gds="git diff --staged"
alias glg="git log --oneline --graph --decorate -20"
alias gp="git push"
alias gpl="git pull --ff-only"
alias gf="git fetch --all --prune"
alias gclean="git clean -fd"
alias gundo="git reset --soft HEAD~1"

# linux
alias grep="grep --color=auto"
alias egrep="egrep --color=auto"
alias fgrep="fgrep --color=auto"

# php
alias phpswitch="sudo update-alternatives --config php"

# sistem
alias update="sudo apt update && sudo apt upgrade -y && sudo apt dist-upgrade -y"
alias aptclean="sudo apt-get autoremove -y && sudo apt-get autoclean"
alias ports="ss -tulpn"
alias myip="curl -s https://ifconfig.me; echo"
alias reload="source ~/.config/fish/config.fish"
EOF
}

bash_aliases_content() {
  if (( OPT_ALIAS_OVERRIDE )); then
    cat <<'EOF'
# eza (pengganti ls)
alias ls='eza --icons --group-directories-first'
alias ll='eza -lah --git --group-directories-first'
alias la='eza -a --group-directories-first'
alias l='eza -1 --group-directories-first'
alias lt='eza --tree --level=2'
# bat (pengganti cat)
alias cat='bat --style=plain --paging=never'
alias catp='bat'
EOF
  else
    cat <<'EOF'
# Override ls/cat dimatikan.
alias lse='eza --icons --group-directories-first'
alias lle='eza -lah --git --group-directories-first'
alias lte='eza --tree --level=2'
alias batp='bat'
EOF
  fi

  cat <<'EOF'

# docker
alias dcdown='docker compose down'
alias dcup='docker compose up -d'
alias dl='docker ps'
alias dla='docker ps -a'
alias dr='docker rm'
alias dps="docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'"
alias di='docker images'
alias dlog='docker logs -f --tail=100'
alias dex='docker exec -it'
alias dprune='docker system prune -af --volumes'
alias dcl='docker compose logs -f --tail=100'
alias dcr='docker compose restart'

# git
alias ga='git add .'
alias gc='git commit -m'
alias gcs='git commit -S -m'
alias gs='git status'
alias gl='git log --graph --pretty="%C(yellow) Hash: %h %C(blue)Date: %ad %C(white) Message: %s " --date=human'
alias gst='git status -sb'
alias gco='git checkout'
alias gsw='git switch'
alias gb='git branch -vv'
alias gd='git diff'
alias gds='git diff --staged'
alias glg='git log --oneline --graph --decorate -20'
alias gp='git push'
alias gpl='git pull --ff-only'
alias gf='git fetch --all --prune'
alias gclean='git clean -fd'
alias gundo='git reset --soft HEAD~1'

# linux
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'

# php
alias phpswitch='sudo update-alternatives --config php'

# sistem
alias update='sudo apt update && sudo apt upgrade -y && sudo apt dist-upgrade -y'
alias aptclean='sudo apt-get autoremove -y && sudo apt-get autoclean'
alias ports='ss -tulpn'
alias myip='curl -s https://ifconfig.me; echo'
alias reload='source ~/.bashrc'
EOF
}

bash_profile_content() {
  cat <<'EOF'
# PATH ~/.local/bin (binary hasil installer, dipakai shell login non-interaktif)
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
EOF
}

bash_hooks_content() {
  cat <<'EOF'
# PATH ~/.local/bin (tempat binary hasil installer)
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
export EDITOR="${EDITOR:-vim}"

if command -v zoxide >/dev/null 2>&1; then eval "$(zoxide init bash)"; fi
if command -v direnv >/dev/null 2>&1; then eval "$(direnv hook bash)"; fi
if command -v atuin >/dev/null 2>&1; then eval "$(atuin init bash)"; fi
EOF

  if (( OPT_STARSHIP )); then
    # shellcheck disable=SC2016  # baris ini ditulis apa adanya ke .bashrc
    printf '%s\n' 'if command -v starship >/dev/null 2>&1; then eval "$(starship init bash)"; fi'
  else
    printf '%s\n' '# starship tidak diaktifkan'
  fi

  cat <<'EOF'

if [ -f /usr/share/doc/fzf/examples/key-bindings.bash ]; then
  . /usr/share/doc/fzf/examples/key-bindings.bash
fi
if [ -f /usr/share/doc/fzf/examples/completion.bash ]; then
  . /usr/share/doc/fzf/examples/completion.bash
fi

mkcd() {
  if [ $# -ne 1 ]; then echo "pakai: mkcd <direktori>" >&2; return 1; fi
  mkdir -p -- "$1" && cd -- "$1"
}

extract() {
  if [ $# -lt 1 ]; then echo "pakai: extract <arsip> [tujuan]" >&2; return 1; fi
  local archive=$1 dest
  dest=$(dirname -- "$archive")
  [ $# -ge 2 ] && dest=$2
  if [ ! -f "$archive" ]; then echo "tidak ada file: $archive" >&2; return 1; fi
  case $archive in
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$dest" ;;
    *.tar.bz2|*.tbz2) tar -xjf "$archive" -C "$dest" ;;
    *.tar.xz) tar -xJf "$archive" -C "$dest" ;;
    *.tar) tar -xf "$archive" -C "$dest" ;;
    *.zip) unzip -q "$archive" -d "$dest" ;;
    *) echo "format tidak dikenal: $archive" >&2; return 1 ;;
  esac
}
EOF
}

fish_tools_content() {
  cat <<'EOF'
# Integrasi tool ke fish. Dikelola installer ubuntu-server-setup.
if not set -q EDITOR
    set -gx EDITOR vim
end
if not set -q VISUAL
    set -gx VISUAL $EDITOR
end

if type -q zoxide
    zoxide init fish | source
end
if type -q direnv
    direnv hook fish | source
end
if type -q atuin
    atuin init fish 2>/dev/null | source
end
EOF

  if (( OPT_STARSHIP )); then
    printf '%s\n' 'if type -q starship' '    starship init fish | source' 'end'
  else
    printf '%s\n' '# starship tidak diaktifkan.'
  fi

  cat <<'EOF'

# Ctrl-R: riwayat via fzf (pengganti plugin fzf.fish)
if status is-interactive; and type -q fzf
    function __fzf_history
        set -l line (history search --reverse | fzf --height 40% --reverse)
        if test -n "$line"
            commandline -r -- $line
        end
    end
    bind \cr __fzf_history
end
EOF

  if [[ -n ${OPT_SSH_PASSPHRASE} ]]; then
    cat <<'EOF'

# ssh-agent untuk key yang memakai passphrase
if status is-interactive; and not set -q SSH_AUTH_SOCK
    eval (ssh-agent -c) >/dev/null 2>&1
    ssh-add ~/.ssh/id_ed25519 >/dev/null 2>&1
end
EOF
  fi
}

fish_function_content() {
  case $1 in
    mkcd) cat <<'EOF'
function mkcd --description 'Buat direktori lalu masuk ke dalamnya'
    if test (count $argv) -ne 1
        echo "pakai: mkcd <direktori>" >&2
        return 1
    end
    mkdir -p -- $argv[1]; and cd -- $argv[1]
end
EOF
    ;;
    extract) cat <<'EOF'
function extract --description 'Ekstrak arsip ke folder tujuan'
    if test (count $argv) -lt 1
        echo "pakai: extract <arsip> [tujuan]" >&2
        return 1
    end
    set -l archive $argv[1]
    set -l dest (dirname -- $archive)
    test (count $argv) -ge 2; and set dest $argv[2]
    if not test -f $archive
        echo "tidak ada file: $archive" >&2
        return 1
    end
    switch $archive
        case '*.tar.gz' '*.tgz'
            tar -xzf $archive -C $dest
        case '*.tar.bz2' '*.tbz2'
            tar -xjf $archive -C $dest
        case '*.tar.xz'
            tar -xJf $archive -C $dest
        case '*.tar'
            tar -xf $archive -C $dest
        case '*.zip'
            unzip -q $archive -d $dest
        case '*'
            echo "format tidak dikenal: $archive" >&2
            return 1
    end
end
EOF
    ;;
  esac
}

# ---------------------------------------------------------------------------
# Langkah: system
# ---------------------------------------------------------------------------
swap_mb() {
  local s=$1
  case $s in
    *G|*g) printf '%s' "$(( ${s%[Gg]} * 1024 ))" ;;
    *M|*m) printf '%s' "${s%[Mm]}" ;;
    *)     printf '2048' ;;
  esac
}

step_system() {
  step "System: swap, zram, timezone"

  local swap_active=0
  if (( OPT_SWAP )); then
    if swapon --show=NAME --noheadings 2>/dev/null | grep -qx '/swapfile'; then
      ok "swapfile sudah aktif"
      swap_active=1
    else
      info "membuat swapfile ${SWAP_SIZE} di /swapfile"
      if ! run as_root fallocate -l "$SWAP_SIZE" /swapfile; then
        warn "fallocate gagal, memakai dd"
        run as_root dd if=/dev/zero of=/swapfile bs=1M count="$(swap_mb "$SWAP_SIZE")" status=none
      fi
      run as_root chmod 600 /swapfile
      run as_root mkswap /swapfile
      if run as_root swapon /swapfile; then
        swap_active=1
        if ! grep -q '^/swapfile' /etc/fstab 2>/dev/null; then
          if (( DRY_RUN )); then
            info "[dry-run] tambah /swapfile ke /etc/fstab"
          else
            printf '/swapfile none swap sw 0 0\n' | as_root tee -a /etc/fstab >/dev/null
          fi
        fi
        ok "swapfile ${SWAP_SIZE} aktif dan tercatat di /etc/fstab"
      else
        warn "swapon ditolak kernel (umum di container/OpenVZ/LXC tanpa dukungan swap)"
        warn "swapfile ${SWAP_SIZE} dihapus lagi; lanjut tanpa swap"
        run as_root rm -f /swapfile
      fi
    fi

    if (( swap_active )); then
      local swappiness=10
      if (( OPT_ZRAM )); then
        swappiness=100
      fi
      write_root_file /etc/sysctl.d/99-swap.conf "vm.swappiness=${swappiness}
vm.vfs_cache_pressure=50"
      run as_root sysctl --system || warn "sysctl --system gagal — nilai swappiness mungkin belum aktif"
    fi
  fi

  if (( OPT_ZRAM )); then
    if apt_install zram-tools; then
      write_root_file /etc/default/zramswap "ALGO=zstd
PERCENT=25"
      run as_root systemctl enable zramswap || warn "gagal enable zramswap"
      if run as_root systemctl restart zramswap; then
        if [[ -b /dev/zram0 ]]; then
          ok "zram aktif (zstd, 25% RAM)"
        else
          warn "layanan zramswap jalan tapi /dev/zram0 tidak ada (modul zram tidak tersedia)"
        fi
      else
        warn "zram tidak dapat dijalankan di sistem ini — dilewati (swapfile tetap dipakai bila aktif)"
      fi
    else
      warn "zram-tools gagal dipasang — zram dilewati"
    fi
  fi

  if (( OPT_TZ )); then
    run as_root timedatectl set-timezone "$TZ_VALUE"
    ok "timezone: ${TZ_VALUE}"
  fi
}

# ---------------------------------------------------------------------------
# Langkah: base
# ---------------------------------------------------------------------------
step_base() {
  step "Paket dasar CLI"

  apt_install ca-certificates curl wget gnupg lsb-release apt-transport-https \
    software-properties-common build-essential git jq unzip zip rsync tmux vim nano \
    htop tree

  # utilitas pelengkap: kalau satu tidak ada di repo, sisanya tetap jalan
  apt_install_optional btop duf fd-find bat fzf zoxide direnv shellcheck pipx ncdu

  # 7zip (24.04) vs p7zip-full (22.04)
  if ! apt_install 7zip 2>/dev/null; then
    warn "paket 7zip tidak tersedia, memakai p7zip-full"
    apt_install p7zip-full || warn "arsip 7z tidak tersedia"
  fi

  # eza tidak ada di repo 22.04 → fallback ke rilis GitHub
  if ! apt_install eza 2>/dev/null; then
    warn "eza tidak ada di repo apt, memasang dari rilis GitHub"
    install_gh_release eza-community/eza "${ARCH_RUST}-unknown-linux-gnu\\.tar\\.gz\$" eza \
      || warn "eza gagal dipasang (alias ls/ll butuh eza)"
  fi

  # nama binary di Ubuntu berbeda dari upstream
  link_bin fdfind fd
  link_bin batcat bat

  install_gh_release mikefarah/yq "^yq_linux_${ARCH_DEB}\$" yq \
    || warn "yq v4 gagal dipasang (apt punya yq v3 dengan sintaks berbeda)"

  install_gh_release fastfetch-cli/fastfetch "^fastfetch-linux-${ARCH_FF}\\.deb\$" fastfetch \
    || warn "fastfetch dilewati"
}

# ---------------------------------------------------------------------------
# Langkah: shell
# ---------------------------------------------------------------------------
step_shell() {
  step "Shell: bash + fish"

  apt_install fish

  if (( OPT_ALIAS_OVERRIDE )); then
    if ! command -v eza >/dev/null 2>&1 \
       || { ! command -v bat >/dev/null 2>&1 && [[ ! -x ${TARGET_HOME}/.local/bin/bat ]]; }; then
      warn "eza/bat belum terpasang — alias eza/bat akan error sampai komponen 'base' dijalankan"
    fi
  fi

  write_block "$TARGET_HOME/.bash_aliases" "$(bash_aliases_content)"
  write_block "$TARGET_HOME/.bashrc" "$(bash_hooks_content)"
  write_block "$TARGET_HOME/.profile" "$(bash_profile_content)"

  write_block "$TARGET_HOME/.config/fish/aliases.fish" "$(fish_aliases_content)"
  write_block "$TARGET_HOME/.config/fish/conf.d/zz-setup-tools.fish" "$(fish_tools_content)"

  # fish butuh config.fish yang memuat aliases.fish
  write_block "$TARGET_HOME/.config/fish/config.fish" "if test -f ~/.config/fish/aliases.fish
    source ~/.config/fish/aliases.fish
end"

  local fn file
  for fn in mkcd extract; do
    file="$TARGET_HOME/.config/fish/functions/${fn}.fish"
    if [[ -f $file ]] && ! grep -qF "$MARK_BEGIN" "$file"; then
      warn "${file} sudah ada dan bukan milik installer — dilewati"
      continue
    fi
    write_block "$file" "$(fish_function_content "$fn")"
  done

  # validasi sintaks file yang kita tulis
  for file in "$TARGET_HOME/.bash_aliases" "$TARGET_HOME/.config/fish/aliases.fish" \
              "$TARGET_HOME/.config/fish/conf.d/zz-setup-tools.fish"; do
    [[ -f $file ]] || continue
    case $file in
      *.bash_aliases) bash -n "$file" && ok "sintaks bash OK: ${file}" ;;
      *) fish -n "$file" 2>/dev/null && ok "sintaks fish OK: ${file}" ;;
    esac
  done

  if (( OPT_FISH_DEFAULT )); then
    if ! grep -qx '/usr/bin/fish' /etc/shells 2>/dev/null; then
      if (( DRY_RUN )); then
        info "[dry-run] tambah /usr/bin/fish ke /etc/shells"
      else
        printf '/usr/bin/fish\n' | as_root tee -a /etc/shells >/dev/null
      fi
    fi
    run as_root chsh -s /usr/bin/fish "$TARGET_USER"
    ok "shell default ${TARGET_USER}: fish (logout/login untuk berlaku)"
  fi
}

# ---------------------------------------------------------------------------
# Langkah: github
# ---------------------------------------------------------------------------
install_gh_cli() {
  if command -v gh >/dev/null 2>&1; then
    ok "gh sudah ada: $(gh --version | first_line)"
    return 0
  fi
  ensure_download_tools
  info "memasang GitHub CLI dari repo resmi"
  run as_root install -m 0755 -d /etc/apt/keyrings
  run as_root curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
  run as_root chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  if (( DRY_RUN )); then
    info "[dry-run] tambah repo apt GitHub CLI"
  else
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
      "$ARCH_DEB" | as_root tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  fi
  apt_update
  apt_install gh
}

step_github() {
  step "GitHub: gh, SSH key, commit signing"

  install_gh_cli || { warn "gh gagal dipasang — langkah GitHub dilewati"; return 0; }

  if (( DRY_RUN )) && ! command -v gh >/dev/null 2>&1; then
    info "[dry-run] gh belum ada — login GitHub dilewati"
    return 0
  fi

  if ! as_target gh auth status >/dev/null 2>&1; then
    if (( DRY_RUN )); then
      info "[dry-run] gh belum login — device flow dilewati"
      return 0
    fi
    if (( INTERACTIVE )) && (( ! ASSUME_YES )); then
      if ui_confirm "gh belum login. Login sekarang lewat device flow? (buka github.com/login/device lalu masukkan kode)"; then
        run as_target gh auth login --hostname github.com --git-protocol ssh --web || true
      else
        warn "login dilewati. Jalankan manual: gh auth login"
        return 0
      fi
    else
      warn "gh belum login — jalankan 'gh auth login' lalu ulangi: ./install.sh --only=github"
      return 0
    fi
  fi

  if ! as_target gh auth status >/dev/null 2>&1; then
    warn "login gh belum berhasil — langkah GitHub dilewati"
    return 0
  fi
  ok "gh login sebagai $(as_target gh api user --jq .login 2>/dev/null || echo '?')"

  local name email login key="$TARGET_HOME/.ssh/id_ed25519"
  name=$(as_target git config --global --get user.name || true)
  email=$(as_target git config --global --get user.email || true)
  login=$(as_target gh api user --jq .login 2>/dev/null || echo "$TARGET_USER")

  if [[ -z $email ]]; then
    email=$(as_target gh api user --jq '.email // empty' 2>/dev/null || true)
  fi
  if [[ -z $email ]]; then
    email="${login}@users.noreply.github.com"
    info "email GitHub privat — memakai ${email}"
  fi
  [[ -n $name ]] || name=$login

  if [[ ! -f $key ]]; then
    info "membuat SSH key ed25519 → ${key}"
    if (( ! DRY_RUN )); then
      mkdir -p "$TARGET_HOME/.ssh"
      chmod 700 "$TARGET_HOME/.ssh" 2>/dev/null || true
    fi
    run ssh-keygen -t ed25519 -C "$email" -f "$key" -N "$OPT_SSH_PASSPHRASE" -q
  else
    ok "SSH key sudah ada: ${key}"
  fi

  write_block "$TARGET_HOME/.ssh/config" "Host github.com
  HostName github.com
  User git
  IdentityFile ${key}
  IdentitiesOnly yes
  AddKeysToAgent yes"
  run chmod 600 "$TARGET_HOME/.ssh/config"

  git_cfg user.name "$name"
  git_cfg user.email "$email"
  git_cfg gpg.format ssh
  git_cfg user.signingkey "${key}.pub"
  git_cfg commit.gpgsign true
  git_cfg tag.gpgsign true
  git_cfg init.defaultBranch main

  if (( DRY_RUN )); then
    info "[dry-run] lewati upload key, allowed_signers, dan uji commit"
    return 0
  fi

  local signers="$TARGET_HOME/.ssh/allowed_signers"
  local sigline
  sigline="${email} $(cat "${key}.pub")"
  mkdir -p "$TARGET_HOME/.ssh"
  touch "$signers"
  grep -qxF "$sigline" "$signers" || printf '%s\n' "$sigline" >>"$signers"
  chmod 644 "$signers"
  git_cfg gpg.ssh.allowedSignersFile "$signers"

  local pubfp title
  pubfp=$(cut -d' ' -f2 "${key}.pub")
  title="vps-$(hostname)-${TS}"

  if as_target gh api user/keys --jq '.[].key' 2>/dev/null \
       | awk -v k="$pubfp" '{if ($2==k) f=1} END{exit(f?0:1)}'; then
    ok "key sudah terdaftar sebagai auth key di GitHub"
  else
    run as_target gh ssh-key add "${key}.pub" --title "$title" \
      || warn "gagal menambah auth key (cek scope token gh)"
  fi

  if as_target gh api user/ssh_signing_keys --jq '.[].key' 2>/dev/null \
       | awk -v k="$pubfp" '{if ($2==k) f=1} END{exit(f?0:1)}'; then
    ok "key sudah terdaftar sebagai signing key"
  else
    if run as_target gh ssh-key add "${key}.pub" --type signing --title "$title"; then
      ok "signing key ditambahkan"
    else
      warn "gagal menambah signing key — jalankan: gh auth refresh -s admin:ssh_signing_key"
    fi
  fi

  local t
  t=$(mktemp -d)
  if as_target git -C "$t" init -q 2>/dev/null \
     && as_target git -C "$t" commit -q --allow-empty -m "test commit signing" 2>/dev/null \
     && as_target git -C "$t" verify-commit HEAD >/dev/null 2>&1; then
    ok "commit signing berfungsi dan terverifikasi"
  else
    warn "commit signing belum terverifikasi — cek: git log --show-signature"
  fi
  rm -rf "$t"

  if as_target ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -T git@github.com 2>&1 \
       | grep -q "successfully authenticated"; then
    ok "autentikasi SSH ke GitHub OK"
  else
    warn "tes 'ssh -T git@github.com' belum sukses (normal bila key ber-passphrase tanpa agent)"
  fi
}

# ---------------------------------------------------------------------------
# Langkah: docker
# ---------------------------------------------------------------------------
ensure_download_tools() {
  local need=0
  command -v curl >/dev/null 2>&1 || need=1
  [[ -e /etc/ssl/certs/ca-certificates.crt ]] || need=1
  command -v jq >/dev/null 2>&1 || need=1
  (( need )) || return 0
  info "memasang prasyarat unduhan (ca-certificates, curl, jq)"
  apt_install ca-certificates curl gnupg jq
}

install_docker_engine() {
  info "memasang Docker Engine dari repo resmi"
  ensure_download_tools
  run as_root install -m 0755 -d /etc/apt/keyrings
  run as_root curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  run as_root chmod a+r /etc/apt/keyrings/docker.asc

  local codename
  # shellcheck source=/dev/null
  codename=$(. /etc/os-release && echo "${VERSION_CODENAME:-noble}")
  if (( DRY_RUN )); then
    info "[dry-run] tambah repo apt Docker (${codename})"
  else
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
      "$ARCH_DEB" "$codename" | as_root tee /etc/apt/sources.list.d/docker.list >/dev/null
  fi

  apt_update
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  run as_root systemctl enable --now docker \
    || warn "systemctl gagal mengaktifkan docker — jalankan manual: systemctl enable --now docker"
}

step_docker() {
  step "Docker"

  if command -v docker >/dev/null 2>&1; then
    ok "docker sudah ada: $(docker --version)"
  else
    install_docker_engine || true
    if ! command -v docker >/dev/null 2>&1; then
      warn "docker gagal dipasang — konfigurasi docker (grup, dive, lazydocker) dilewati"
      warn "periksa log: ${LOG}"
      return 0
    fi
  fi

  if docker compose version >/dev/null 2>&1; then
    ok "compose: $(docker compose version --short 2>/dev/null || echo tersedia)"
  else
    warn "plugin docker compose tidak ditemukan"
  fi

  if docker info >/dev/null 2>&1; then
    ok "daemon docker berjalan"
  else
    warn "daemon docker belum dapat dihubungi — cek: systemctl status docker"
  fi

  if ! getent group docker >/dev/null 2>&1; then
    warn "grup docker tidak ada — user ${TARGET_USER} tidak ditambahkan ke grup docker"
  elif id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    ok "user ${TARGET_USER} ada di grup docker"
  else
    run as_root usermod -aG docker "$TARGET_USER" \
      || warn "gagal menambah ${TARGET_USER} ke grup docker"
    ok "user ${TARGET_USER} ditambahkan ke grup docker (perlu login ulang)"
  fi

  install_gh_release wagoodman/dive "linux_${ARCH_DEB}\\.tar\\.gz\$" dive \
    || warn "dive gagal dipasang"
  install_gh_release jesseduffield/lazydocker "Linux_${ARCH_GO}\\.tar\\.gz\$" lazydocker \
    || warn "lazydocker gagal dipasang"
}

# ---------------------------------------------------------------------------
# Langkah: dev
# ---------------------------------------------------------------------------
step_dev() {
  step "Tool dev"

  apt_install_optional git-delta just httpie

  install_gh_release jesseduffield/lazygit "linux_${ARCH_GO}\\.tar\\.gz\$" lazygit \
    || warn "lazygit gagal dipasang"
  install_gh_release atuinsh/atuin "^atuin-${ARCH_RUST}-unknown-linux-gnu\\.tar\\.gz\$" atuin \
    || warn "atuin gagal dipasang"
  install_gh_release starship/starship "^starship-${ARCH_RUST}-unknown-linux-gnu\\.tar\\.gz\$" starship \
    || warn "starship gagal dipasang"

  if command -v delta >/dev/null 2>&1 && (( OPT_DELTA_PAGER )); then
    git_cfg core.pager delta
    git_cfg interactive.diffFilter "delta --color-only"
    git_cfg delta.navigate true
    git_cfg delta.line-numbers true
    git_cfg delta.side-by-side true
    git_cfg merge.conflictstyle zdiff3
    git_cfg diff.colorMoved zebra
    ok "delta dipakai sebagai git pager"
  fi
}

# ---------------------------------------------------------------------------
# Langkah: ops
# ---------------------------------------------------------------------------
step_ops() {
  step "Tool operasional"

  apt_install_optional sysstat iotop strace lsof glances mtr-tiny nmap restic rclone \
    bind9-dnsutils netcat-openbsd

  run as_root systemctl enable --now sysstat 2>/dev/null || true
  info "sar/iostat dari sysstat; metrik dikumpulkan timer sysstat"
}

# ---------------------------------------------------------------------------
# Langkah: security
# ---------------------------------------------------------------------------
step_security() {
  step "Keamanan server"

  if (( SEC_UFW )); then
    if apt_install ufw; then
      # Container tanpa CAP_NET_ADMIN / OpenVZ-LXC sering menolak iptables
      # walaupun berjalan sebagai root. Deteksi dulu, jangan bikin script mati.
      if (( ! DRY_RUN )) && ! as_root iptables -S >/dev/null 2>&1; then
        warn "iptables tidak dapat diakses (container/OpenVZ/LXC tanpa NET_ADMIN)"
        warn "ufw dilewati — atur firewall di level host/provider"
      else
        local ufw_ok=1
        if (( ! DRY_RUN )) && as_root ufw status 2>/dev/null | grep -q "Status: active"; then
          ok "ufw sudah aktif — aturan lama dipertahankan"
        else
          run as_root ufw default deny incoming || ufw_ok=0
          run as_root ufw default allow outgoing || ufw_ok=0
        fi
        run as_root ufw allow "${SSH_PORT}/tcp" || ufw_ok=0
        if (( SEC_UFW_WEB )); then
          run as_root ufw allow 80/tcp || ufw_ok=0
          run as_root ufw allow 443/tcp || ufw_ok=0
        fi
        if (( ufw_ok )) && run as_root ufw --force enable; then
          local opened="SSH ${SSH_PORT}"
          if (( SEC_UFW_WEB )); then
            opened+=", 80, 443"
          fi
          ok "ufw aktif (${opened})"
        else
          warn "ufw tidak dapat diaktifkan di sistem ini — langkah keamanan lain tetap dijalankan"
          warn "aktifkan firewall dari panel provider atau host"
        fi
      fi
    else
      warn "ufw gagal dipasang — dilewati"
    fi
  fi

  if (( SEC_FAIL2BAN )); then
    if apt_install fail2ban; then
      write_root_file /etc/fail2ban/jail.local "[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h"
      if run as_root systemctl enable fail2ban && run as_root systemctl restart fail2ban; then
        ok "fail2ban aktif untuk sshd"
      else
        warn "fail2ban terpasang tapi tidak berjalan (systemd/iptables tidak tersedia?)"
        warn "jail.local tetap ditulis; aktifkan manual setelah systemd & firewall siap"
      fi
    else
      warn "fail2ban gagal dipasang — dilewati"
    fi
  fi

  if (( SEC_UNATTENDED )); then
    if apt_install unattended-upgrades apt-listchanges; then
      write_root_file /etc/apt/apt.conf.d/20auto-upgrades 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";'
      if run as_root systemctl enable unattended-upgrades; then
        ok "unattended-upgrades aktif (tanpa reboot otomatis)"
      else
        warn "unattended-upgrades terpasang tapi service tidak aktif (systemd tidak tersedia?)"
        warn "konfigurasi 20auto-upgrades tetap ditulis"
      fi
    else
      warn "unattended-upgrades gagal dipasang — dilewati"
    fi
  fi

  if (( SEC_SSH_HARDEN )); then
    local ak="$TARGET_HOME/.ssh/authorized_keys"
    if (( ! DRY_RUN )) && [[ ! -s $ak ]]; then
      warn "authorized_keys untuk ${TARGET_USER} tidak ada — hardening SSH dibatalkan agar tidak terkunci"
    elif [[ ! -s /etc/ssh/ssh_host_ed25519_key ]]; then
      warn "host key SSH belum ada — hardening dibatalkan"
    else
      write_root_file /etc/ssh/sshd_config.d/99-hardening.conf "PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
MaxAuthTries 3"
      if run as_root sshd -t; then
        run as_root systemctl reload ssh 2>/dev/null || run as_root systemctl reload sshd
        ok "SSH diperketat: login password dimatikan"
        warn "SEBELUM logout, buka sesi baru dan uji login key: ssh ${TARGET_USER}@<ip>"
      else
        warn "sshd -t gagal — file hardening dihapus, konfigurasi lama dipakai"
        run as_root rm -f /etc/ssh/sshd_config.d/99-hardening.conf
      fi
    fi
  fi
}

# ---------------------------------------------------------------------------
# Verifikasi & ringkasan
# ---------------------------------------------------------------------------
short_version() {
  local c=$1 out
  case $c in
    lsof) out=$(timeout 5 lsof -v 2>&1 | awk 'tolower($0) ~ /revision/ && !f {v=$0; f=1} END{if (f) print v}' || true) ;;
    http) out=$(timeout 5 http --version 2>/dev/null | first_line || true) ;;
    restic) out=$(timeout 5 restic version 2>/dev/null | first_line || true) ;;
    *)    out=$(timeout 5 "$c" --version 2>/dev/null | first_line || true) ;;
  esac
  if [[ $out == *$'\e'* ]]; then
    out=$(printf '%s' "$out" | sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g')
  fi
  printf '%s' "${out:--}"
}

step_verify() {
  step "Verifikasi"

  local tools=(git gh docker htop btop fd bat eza fzf zoxide direnv yq shellcheck pipx
               tree duf fastfetch delta lazygit just http atuin starship
               dive lazydocker glances mtr nmap restic rclone iotop strace lsof
               ufw fail2ban-client)
  printf '%-16s %s\n' "TOOL" "STATUS"
  local t
  for t in "${tools[@]}"; do
    if command -v "$t" >/dev/null 2>&1; then
      printf '%-16s %s\n' "$t" "$(short_version "$t")"
    else
      printf '%-16s %s\n' "$t" "${C_DIM}tidak ada${C_RESET}"
    fi
  done

  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    printf '\n%-18s %s\n' "SERVICE" "STATUS"
    local svc
    for svc in docker fail2ban ssh zramswap unattended-upgrades; do
      printf '%-18s %s\n' "$svc" "$(systemctl is-active "$svc" 2>/dev/null || true)"
    done
  fi

  printf '\n'
  if [[ -f $TARGET_HOME/.ssh/id_ed25519.pub ]]; then
    ok "SSH key: ${TARGET_HOME}/.ssh/id_ed25519.pub"
  fi
  if [[ $(as_target git config --global --get commit.gpgsign 2>/dev/null || echo false) == true ]]; then
    ok "git commit signing: aktif ($(as_target git config --global --get gpg.format))"
  fi
  if [[ -f $TARGET_HOME/.config/fish/aliases.fish ]] \
     && grep -qF "$MARK_BEGIN" "$TARGET_HOME/.config/fish/aliases.fish"; then
    ok "alias fish terpasang"
  fi
  if [[ -f $TARGET_HOME/.bash_aliases ]] \
     && grep -qF "$MARK_BEGIN" "$TARGET_HOME/.bash_aliases"; then
    ok "alias bash terpasang"
  fi
  if swapon --show 2>/dev/null | grep -q '/swapfile'; then
    ok "swapfile aktif"
  fi
}

summary() {
  printf '\n'
  printf '%s\n' "${C_DIM}────────────────────────────────────────────────────────────${C_RESET}"
  ok "Instalasi selesai."
  info "Target : ${TARGET_USER} (${TARGET_HOME})"
  info "Log    : ${LOG}"
  if [[ -d $BACKUP_DIR ]]; then
    info "Backup : ${BACKUP_DIR}"
  fi

  if [[ $TARGET_MODE == create ]] && [[ -n $NEW_USER_PASSWORD ]]; then
    printf '\n%s\n' "${C_YELLOW}${C_BOLD}Akun baru${C_RESET}"
    printf '  user     : %s\n' "$TARGET_USER"
    printf '  password : %s\n' "$NEW_USER_PASSWORD"
    printf '  %s\n' "salin sekarang; password hanya ditampilkan sekali"
  fi

  printf '\nLangkah manual:\n'
  printf '  • logout/login (atau "newgrp docker") agar grup docker & shell fish aktif\n'
  if (( SEC_SSH_HARDEN )); then
    printf '  • %sSEBELUM menutup sesi%s: uji login key di terminal baru:\n' "$C_BOLD" "$C_RESET"
    printf '      ssh %s@<ip-vps>\n' "$TARGET_USER"
  fi
  printf '  • verifikasi GitHub: gh auth status && ssh -T git@github.com\n'
  printf '  • uji signing: cd /tmp && git init -q uji && cd uji && git commit --allow-empty -m tes && git log --show-signature -1\n'
  printf '  • rollback: salin balik file dari folder backup di atas (termasuk subfolder etc/)\n'
}

# ---------------------------------------------------------------------------
# Argumen
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
ubuntu-server-setup ${SCRIPT_VERSION}

Installer interaktif untuk VPS Ubuntu Server 24.04+ (fallback untuk 22.04).
Semua langkah idempotent — boleh dijalankan berulang.

PEMAKAIAN
  sudo ./install.sh                    Menu interaktif (gum / Bubble Tea)
  ./install.sh --all                   Semua komponen, default aman
  ./install.sh --only=base,shell       Komponen tertentu saja
  ./install.sh --all --dry-run         Tampilkan aksi tanpa mengubah sistem

KOMPONEN
  system    swap ${SWAP_SIZE}, zram, timezone, sysctl
  base      htop btop tree duf fd bat eza fzf zoxide direnv yq shellcheck pipx
  shell     alias & hook bash + fish, fungsi mkcd & extract
  github    gh, SSH key ed25519, commit signing, ~/.ssh/config
  docker    Docker Engine dari repo resmi, compose, dive, lazydocker
  dev       lazygit git-delta just httpie atuin starship
  ops       sysstat iotop strace lsof glances mtr nmap restic rclone
  security  ufw, fail2ban, unattended-upgrades, hardening SSH

OPSI
  -y, --yes                Tanpa konfirmasi (otomasi)
      --dry-run            Tidak mengubah apa pun
      --target-user=NAME   User yang dikonfigurasi (default: user saat ini;
                           jika root & interaktif, ditanya lewat menu)
      --user-password=PW   Password user baru (kosong = acak)
      --swap-size=2G       Ukuran swapfile
      --no-swap            Lewati swapfile
      --no-zram            Lewati zram
      --timezone=Area/Kota Aktifkan set timezone
      --ssh-port=22        Port SSH untuk ufw/fail2ban
      --ssh-hardening      Matikan login password SSH (hati-hati!)
      --no-ufw             Lewati ufw
      --no-fail2ban        Lewati fail2ban
      --no-unattended      Lewati unattended-upgrades
      --aliases-override   Timpa alias ls/ll/la/l/cat (default: ya)
      --delta-pager        Delta sebagai git pager (default: ya)
      --starship           Aktifkan starship
      --no-fish-default    Jangan jadikan fish shell default
      --ssh-passphrase=…   Passphrase SSH key yang dibuat
  -h, --help               Bantuan ini
  -V, --version            Versi script

CATATAN
  • Backup otomatis ke ${BACKUP_DIR}
  • Konfigurasi user ditulis dalam blok bertanda "${MARK_BEGIN}",
    jadi isi manual di luar blok tidak tersentuh.
  • Hardening SSH hanya dijalankan bila authorized_keys target ada dan
    "sshd -t" lolos; jika gagal, file hardening dihapus otomatis.
EOF
}

parse_args() {
  while (($#)); do
    case $1 in
      --all) SELECTED=(system base shell github docker dev ops security) ;;
      --only=*) IFS=, read -r -a SELECTED <<<"${1#*=}" ;;
      --only) shift; [[ -n ${1:-} ]] || die "--only butuh daftar komponen"; IFS=, read -r -a SELECTED <<<"$1" ;;
      --dry-run) DRY_RUN=1 ;;
      -y|--yes) ASSUME_YES=1 ;;
      --target-user=*) TARGET_USER_ARG=${1#*=} ;;
      --user-password=*) NEW_USER_PASSWORD=${1#*=} ;;
      --swap-size=*) SWAP_SIZE=${1#*=} ;;
      --no-swap) OPT_SWAP=0 ;;
      --no-zram) OPT_ZRAM=0 ;;
      --timezone=*) TZ_VALUE=${1#*=}; OPT_TZ=1 ;;
      --ssh-port=*) SSH_PORT=${1#*=} ;;
      --ssh-hardening) SEC_SSH_HARDEN=1 ;;
      --no-ufw) SEC_UFW=0 ;;
      --no-fail2ban) SEC_FAIL2BAN=0 ;;
      --no-unattended) SEC_UNATTENDED=0 ;;
      --aliases-override) OPT_ALIAS_OVERRIDE=1 ;;
      --no-aliases-override) OPT_ALIAS_OVERRIDE=0 ;;
      --delta-pager) OPT_DELTA_PAGER=1 ;;
      --no-delta-pager) OPT_DELTA_PAGER=0 ;;
      --starship) OPT_STARSHIP=1 ;;
      --no-fish-default) OPT_FISH_DEFAULT=0 ;;
      --ssh-passphrase=*) OPT_SSH_PASSPHRASE=${1#*=} ;;
      -h|--help) usage; exit 0 ;;
      -V|--version) printf '%s\n' "$SCRIPT_VERSION"; exit 0 ;;
      *) usage >&2; die "argumen tidak dikenal: $1" ;;
    esac
    shift
  done

  if [[ -n $SSH_PORT ]] && ! [[ $SSH_PORT =~ ^[0-9]+$ ]]; then
    die "--ssh-port harus angka"
  fi
  if ! [[ $SWAP_SIZE =~ ^[0-9]+[GgMm]$ ]]; then
    die "--swap-size harus seperti 2G atau 512M"
  fi
}

validate_selection() {
  local s v valid
  for s in "${SELECTED[@]}"; do
    valid=0
    for v in "${VALID_STEPS[@]}"; do
      if [[ $s == "$v" ]]; then valid=1; fi
    done
    (( valid )) || die "komponen tidak dikenal: '${s}' (pilihan: ${VALID_STEPS[*]})"
  done
}

print_plan() {
  printf '\n%s\n' "${C_BOLD}Rencana instalasi${C_RESET}"
  local s
  for s in "${SELECTED[@]}"; do
    printf '  • %-8s %s\n' "$s" "$(step_label "$s")"
  done
  printf '  • target   : %s (%s)\n' "$TARGET_USER" "$TARGET_HOME"

  if want system; then
    printf '  • system   : swap=%s zram=%s timezone=%s\n' \
      "$([[ $OPT_SWAP == 1 ]] && echo "${SWAP_SIZE}" || echo tidak)" \
      "$([[ $OPT_ZRAM == 1 ]] && echo ya || echo tidak)" \
      "$([[ $OPT_TZ == 1 ]] && echo "${TZ_VALUE}" || echo tidak)"
  fi
  if want security; then
    printf '  • security : ufw=%s fail2ban=%s unattended=%s ssh_hardening=%s\n' \
      "$([[ $SEC_UFW == 1 ]] && echo ya || echo tidak)" \
      "$([[ $SEC_FAIL2BAN == 1 ]] && echo ya || echo tidak)" \
      "$([[ $SEC_UNATTENDED == 1 ]] && echo ya || echo tidak)" \
      "$([[ $SEC_SSH_HARDEN == 1 ]] && echo ya || echo tidak)"
  fi
  printf '  • alias    : override=%s delta_pager=%s starship=%s\n' \
    "$([[ $OPT_ALIAS_OVERRIDE == 1 ]] && echo ya || echo tidak)" \
    "$([[ $OPT_DELTA_PAGER == 1 ]] && echo ya || echo tidak)" \
    "$([[ $OPT_STARSHIP == 1 ]] && echo ya || echo tidak)"

  if (( DRY_RUN )); then
    warn "DRY-RUN: tidak ada perubahan yang akan dilakukan"
  fi
}

# ---------------------------------------------------------------------------
# Alur utama
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  if ((${#SELECTED[@]} == 0)); then
    if (( ASSUME_YES )) || [[ ! -t 0 || ! -t 1 ]]; then
      usage >&2
      die "pilih komponen: --all atau --only=base,shell,... (TUI butuh terminal interaktif)"
    fi
    INTERACTIVE=1
    if [[ -z ${TERM:-} || ${TERM:-} == dumb ]]; then
      usage >&2
      die "TERM tidak mendukung TUI (TERM=${TERM:-kosong}). Jalankan dari terminal SSH biasa, atau pakai --all/--only=..."
    fi
    if ! ui_init; then
      if (( DRY_RUN )); then
        err "TUI belum tersedia dan tidak bisa dipasang saat --dry-run (curl/whiptail belum ada di sistem ini)."
        err "Jalankan sekali tanpa --dry-run agar gum terpasang, atau pakai --all/--only=..."
      else
        err "TUI tidak tersedia: gum/whiptail gagal dipasang."
        err "Pasang gum (charmbracelet/gum) atau whiptail lalu ulangi, atau pakai --all/--only=..."
      fi
      usage >&2
      exit 1
    fi
    menu_categories
  fi
  validate_selection

  if (( INTERACTIVE )); then
    OPT_ALIAS_OVERRIDE=${OPT_ALIAS_OVERRIDE:-0}
    OPT_DELTA_PAGER=${OPT_DELTA_PAGER:-0}
    menu_options
    if want system; then menu_system; fi
    if want security; then menu_security; fi
  else
    # jalur non-interaktif: default konservatif
    OPT_ALIAS_OVERRIDE=${OPT_ALIAS_OVERRIDE:-1}
    OPT_DELTA_PAGER=${OPT_DELTA_PAGER:-1}
  fi

  resolve_target
  # binary hasil installer (yq, atuin, bat/fd symlink, …) ada di ~/.local/bin;
  # pastikan langkah berikutnya & tabel verifikasi menemukannya.
  export PATH="${TARGET_HOME}/.local/bin:${PATH}"
  if want github; then ask_passphrase; fi

  _log_raw "mulai: steps=${SELECTED[*]} target=${TARGET_USER} dry_run=${DRY_RUN}"
  print_plan

  if (( ! DRY_RUN && ! ASSUME_YES && INTERACTIVE )); then
    ui_confirm "Mulai instalasi sekarang?" || die "dibatalkan"
  fi

  preflight

  local s
  for s in "${SELECTED[@]}"; do
    case $s in
      system)   step_system ;;
      base)     step_base ;;
      shell)    step_shell ;;
      github)   step_github ;;
      docker)   step_docker ;;
      dev)      step_dev ;;
      ops)      step_ops ;;
      security) step_security ;;
    esac
  done

  finalize_ownership
  step_verify
  summary
}

main "$@"
