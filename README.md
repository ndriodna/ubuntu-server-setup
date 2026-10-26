# ubuntu-server-setup

Installer interaktif untuk **VPS Ubuntu Server baru**: paket dasar, alias bash + fish,
GitHub (SSH key + commit signing), Docker, tool dev/ops, dan langkah keamanan.
Semua langkah idempotent — boleh dijalankan berulang, dan setiap file yang diubah
dibackup lebih dulu.

Target yang diuji: Ubuntu 24.04 dan 26.04. Versi 22.04 sebagian besar jalan (ada fallback
untuk `eza` dan `7zip`).

## Prasyarat

- VPS Ubuntu 24.04+ dengan akses `sudo` (atau root).
- Rilis ini **tidak** menyentuh mesin WSL/dev — dirancang untuk server.
- Koneksi internet ke repo Ubuntu, GitHub, dan Docker.

## Cara pakai di VPS baru

```bash
# dari komputer lokal
scp install.sh root@IP_VPS:/root/
ssh root@IP_VPS

# di VPS
chmod +x install.sh
sudo ./install.sh
```

Atau clone repo lalu jalankan `./install.sh` sebagai root / via sudo.

Kalau `sudo` dipakai, menu pertama menanyakan konfigurasi untuk user mana:
`root`, user yang sudah ada, atau buat user admin baru (sudo + salin
`authorized_keys`). Tanpa TUI, gunakan `--target-user=NAMA`.

### Alur TUI

1. Checklist komponen (`system base shell github docker dev ops security`).
2. Checklist opsi (override alias, delta pager, starship, fish default, dry-run).
3. Sub-menu `system` (swap / zram / timezone) dan `security` (ufw / fail2ban /
   unattended-upgrades / hardening SSH).
4. Pilihan target user (jika dijalankan sebagai root).
5. Konfirmasi, lalu eksekusi + verifikasi + ringkasan.

### Contoh non-interaktif

```bash
sudo ./install.sh --all --yes                 # semua, default aman
sudo ./install.sh --only=base,shell --dry-run  # lihat aksi tanpa mengubah apa pun
sudo ./install.sh --only=security --ssh-port=2222 --ssh-hardening
sudo ./install.sh --all --target-user=deploy --user-password='...' --swap-size=4G
```

## Komponen

| Langkah | Isi |
|---|---|
| `system` | swapfile (default 2G) + fstab, zram (`zram-tools`, zstd 25%), sysctl swappiness, timezone opsional |
| `base` | htop, btop, tree, duf, ncdu, tmux, vim, fd, bat, eza, fzf, zoxide, direnv, yq v4, shellcheck, pipx, rsync, unzip/7zip, fastfetch, build-essential |
| `shell` | alias bash (`~/.bash_aliases`) + fish (`aliases.fish`), hook zoxide/direnv/atuin/fzf, fungsi `mkcd` & `extract`, fish sebagai shell default |
| `github` | install `gh` dari repo resmi, login device flow, SSH key ed25519, `~/.ssh/config`, commit signing (`gpg.format=ssh`), allowed_signers, uji commit bertanda tangan |
| `docker` | Docker Engine + compose dari repo resmi (jika belum ada), verifikasi daemon, user masuk grup docker, `dive`, `lazydocker` |
| `dev` | lazygit, git-delta (+ pager git), just, httpie, atuin, starship |
| `ops` | sysstat, iotop, strace, lsof, glances, mtr, nmap, restic, rclone, bind9-dnsutils, netcat |
| `security` | ufw (SSH + 80/443), fail2ban sshd, unattended-upgrades, hardening SSH opsional |

Alias yang dipasang mencakup versi bash dan fish untuk: `ls/ll/la/l/lt` (eza),
`cat` (bat), docker (`dps`, `dcu`, `dcl`, `dprune`, …), git (`gs`, `gcs`, `gl`,
`glg`, …), serta `ports`, `myip`, `update`, `aptclean`, `reload`, `phpswitch`.

## Flag penting

| Flag | Keterangan |
|---|---|
| `--all` / `--only=a,b` | pilih semua / komponen tertentu |
| `--dry-run` | tampilkan aksi, tidak mengubah sistem |
| `-y, --yes` | tanpa konfirmasi (otomasi) |
| `--target-user=NAMA` | user yang dikonfigurasi (butuh root) |
| `--user-password=PW` | password user baru (kosong = acak, ditampilkan sekali) |
| `--swap-size=2G` / `--no-swap` | ukuran swapfile / lewati |
| `--no-zram` | lewati zram |
| `--timezone=Asia/Jakarta` | aktifkan set timezone |
| `--ssh-port=22` | port SSH untuk ufw + fail2ban |
| `--ssh-hardening` | matikan login password SSH (baca peringatan di bawah) |
| `--no-ufw`, `--no-fail2ban`, `--no-unattended` | lewati bagian keamanan tertentu |
| `--no-aliases-override` | jangan timpa alias `ls`/`cat` (pakai `lse`/`batp`) |
| `--starship` | aktifkan prompt starship |
| `--no-fish-default` | jangan jadikan fish shell default |
| `--ssh-passphrase=…` | passphrase untuk SSH key yang dibuat |

`./install.sh --help` menampilkan daftar lengkap.

## Keamanan & rollback

- Backup: `backups/<timestamp>/` (file user) dan `backups/<timestamp>/etc/`
  (file sistem, nama path di-flatten).
- Config user ditulis dalam blok bertanda `# >>> ubuntu-server-setup >>>` …
  `# <<< ubuntu-server-setup <<<`. Isi di luar blok tidak disentuh; rerun hanya
  mengganti blok tersebut.
- Log: `logs/install-<timestamp>.log`.
- **Hardening SSH** hanya dijalankan jika `authorized_keys` target ada dan
  `sshd -t` lolos. Jika validasi gagal, file hardening dihapus otomatis dan
  konfigurasi lama dipakai. Tetap uji login key di sesi baru **sebelum** menutup
  sesi lama:

  ```bash
  ssh -i ~/.ssh/id_ed25519 user@IP_VPS
  ```

- `fail2ban` memakai backend `systemd`; cek `fail2ban-client status sshd`.
- `unattended-upgrades` tidak melakukan reboot otomatis.

## Catatan

- **Grup docker**: setelah instalasi, logout/login (atau `newgrp docker`) agar
  user bisa memakai docker tanpa sudo.
- **fish + starship**: jika prompt tide terdeteksi (mis. kamu membawa dotfile
  sendiri), starship tidak diaktifkan secara default agar prompt tidak bentrok.
- **zram + swapfile**: swappiness diset 100 saat zram aktif, 10 saat hanya
  swapfile.
- **`yq`**: dipasang dari rilis mikefarah (v4). `apt install yq` di Ubuntu
  memberi versi 3 dengan sintaks berbeda.
- **`bat`/`fd`**: binary Ubuntu bernama `batcat`/`fdfind`; installer membuat
  symlink `bat`/`fd` di `~/.local/bin`.
- **gh signing key**: butuh scope `admin:ssh_signing_key`. Jika gagal:
  `gh auth refresh -s admin:ssh_signing_key`.
- **Mode `--all --yes`**: langkah GitHub tidak bisa memulai device-flow login
  sendiri. Jalankan `gh auth login` (atau set `GH_TOKEN`) dulu, kalau tidak
  langkah SSH key/signing dilewati dengan peringatan. Di mode TUI login
  ditawarkan langsung.
- **eza di 22.04**: tidak ada di repo apt, installer mengambil rilis GitHub.
- **Paket opsional**: kalau sebuah paket tidak ada di repo (mis. `just`/`duf` di
  22.04), installer memberi peringatan dan melanjutkan; paket inti
  (`git`, `curl`, `jq`, `build-essential`, …) tetap wajib berhasil.
- **Swap best-effort**: kalau kernel menolak `swapon` (container, OpenVZ/LXC
  tanpa dukungan swap), swapfile dihapus lagi dan instalasi lanjut tanpa swap.
  zram juga dilewati bila modul `zram` tidak tersedia.
- **PATH `~/.local/bin`**: ditulis ke `.bashrc` *dan* `.profile`, karena
  `.bashrc` Ubuntu berhenti lebih awal pada shell non-interaktif. Shell `fish`
  sudah memakai `~/.local/bin` secara default.
- **Prasyarat unduhan**: langkah `github`/`docker`/`dev` otomatis memasang
  `ca-certificates`, `curl`, `gnupg`, dan `jq` bila belum ada, jadi
  `--only=docker` tetap jalan di sistem minimal.

## Sudah diuji di container

Uji end-to-end dilakukan di container Ubuntu 24.04 (systemd sebagai PID 1,
privileged, cgroup host) dan Ubuntu 26.04 (unprivileged, tanpa systemd):

| Skenario | Hasil |
|---|---|
| `--all --yes` dari container kosong (24.04, privileged) | exit 0, 21 langkah sukses |
| `--all --yes` dari container kosong (26.04, unprivileged) | exit 0, 0 error; ufw/fail2ban/zram dilewati dengan warning |
| `--only=system,base,shell` | swap/zram ditolak kernel → warning, lanjut normal |
| `--only=github,docker,dev,ops,security` | gh terpasang, docker daemon aktif, ufw/fail2ban aktif |
| `--only=shell --target-user=deploy` | user dibuat, masuk grup sudo, ownership & fish default benar |
| TUI asli (`whiptail`) | menu tampil, ESC → "dibatalkan", exit 1 |
| `docker run hello-world` | sukses (docker-in-docker, butuh volume untuk `/var/lib/docker` & `/var/lib/containerd`) |

Container tanpa `CAP_NET_ADMIN` (dan VPS OpenVZ/LXC sejenis) tidak bisa
menjalankan `iptables`, jadi `ufw` dilewati dengan peringatan — atur firewall
dari panel provider/host. Instalasi tetap selesai dengan exit 0.

Yang **belum** teruji otomatis: login `gh` sungguhan (device flow), pendaftaran
SSH key ke akun GitHub, hardening SSH pada sshd nyata, dan boot VPS asli.

## Struktur

```
install.sh          # seluruh installer (single-file)
README.md
logs/               # log per run (dibuat otomatis)
backups/            # backup file yang diubah (dibuat otomatis)
```
