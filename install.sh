#!/bin/bash
set -e

if [ "$(id -u)" -ne 0 ]; then
  echo "OSHIBKA: ZAPUSK OT ROOT OBязATELEN!"
  exit 1
fi

if [ "$(uname -m)" != "x86_64" ]; then
  echo "Vnimanie: skript dlya x86_64 (nettop). Prodolzhit'?"
  read -p " (y/N): " -n 1 -r
  echo
  if ! [[ $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

echo "[*] Ustanavlivaem pakety..."
(
  apt update -qq 2>/dev/null || true
  apt install -y -o DPkg::Lock::Timeout=60 \
    xserver-xorg xinit mpv udisks2 x11-xserver-utils \
    xterm ffmpeg gstreamer1.0-libav ntfs-3g exfat-fuse exfatprogs \
    feh imagemagick curl 2>/dev/null || echo "Prodolzhaem bez novyh paketov."
)

if ! id "player" &>/dev/null; then
  adduser --disabled-password --gecos "" player 2>/dev/null || true
fi
usermod -aG audio,video,input,dialout player 2>/dev/null || true

mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin player --noclear %I $TERM
EOF

# === ZAGRUZKA FONA S GITHUB ===
BACKGROUND_DIR="/home/player/background"
BACKGROUND_FILE="$BACKGROUND_DIR/default.jpg"
mkdir -p "$BACKGROUND_DIR"
chown player:player "$BACKGROUND_DIR"

ELKA_URL="https://raw.githubusercontent.com/deddosouru/scripts/main/elka-ukrasena-ognami.jpg"

echo "[*] Popytka zagruzit' fonovoe izobrazhenie s GitHub..."
if command -v curl >/dev/null && curl -fsSL --max-time 15 "$ELKA_URL" -o "$BACKGROUND_FILE"; then
  echo "✅ Fon uspeshno zagruzhен: elka-ukrasena-ognami.jpg"
else
  echo "!!! Ne udalos' zagruzit' fon (net interneta / oshibka). Sozdaem chernyj fon."
  if command -v convert >/dev/null; then
    convert -size 1920x1080 xc:black "$BACKGROUND_FILE" 2>/dev/null || {
      echo "Ne udalos' sozdat' fon cherez ImageMagick — sozdaem pustoj fajl."
      touch "$BACKGROUND_FILE"
    }
  else
    touch "$BACKGROUND_FILE"
  fi
fi
chown player:player "$BACKGROUND_FILE"
# === KONEC ZAGRUZKI FONA ===

cat > /home/player/play-videos.sh <<'EOF'
#!/bin/bash
exec >> /home/player/usb-watcher.log 2>&1
set -x

VIDEO_DIR="$1"
[ -n "$VIDEO_DIR" ] && [ -d "$VIDEO_DIR" ] || { echo "Ne korrektnyj katalog"; exit 1; }

pkill -f "mpv.*$VIDEO_DIR" 2>/dev/null; pkill -f "mpv --no-terminal" 2>/dev/null; sleep 2

shopt -s nullglob nocaseglob
VIDEO_FILES=("$VIDEO_DIR"/*.mp4 "$VIDEO_DIR"/*.mkv "$VIDEO_DIR"/*.avi "$VIDEO_DIR"/*.mov "$VIDEO_DIR"/*.m4v "$VIDEO_DIR"/*.flv "$VIDEO_DIR"/*.webm "$VIDEO_DIR"/*.wmv)
VIDEO_FILES=($(for f in "${VIDEO_FILES[@]}"; do [ -f "$f" ] && echo "$f"; done))

[ ${#VIDEO_FILES[@]} -gt 0 ] || { echo "Net video"; exit 1; }

export DISPLAY=:0
xset q >/dev/null || { echo "X nedostupen"; exit 1; }

exec mpv --no-terminal --fs --panscan=1 --loop-playlist=inf --shuffle --hwdec=auto "${VIDEO_FILES[@]}"
EOF
chmod +x /home/player/play-videos.sh
chown player:player /home/player/play-videos.sh

cat > /home/player/usb-watcher.sh <<'EOF'
#!/bin/bash
exec >> /home/player/usb-watcher.log 2>&1
set -x

BG="/home/player/background/default.jpg"
show_bg() { pkill -f feh 2>/dev/null; sleep 1; export DISPLAY=:0; [ -f "$BG" ] && feh --bg-fill "$BG" &; }
stop_vid() { pkill -f mpv 2>/dev/null; sleep 2; }

show_bg

if command -v udevadm >/dev/null; then
  /sbin/udevadm monitor --udev -s block 2>/dev/null | while read line; do
    if echo "$line" | grep -q "add.*s[d-z][0-9]"; then
      DEV=$(echo "$line" | grep -o "s[d-z][0-9]" | head -n1)
      [ -n "$DEV" ] && [ -e "/dev/$DEV" ] && {
        stop_vid
        timeout 60s sudo -u player /home/player/play-videos.sh "/dev/$DEV" < /dev/tty1 > /dev/tty1 2>&1 || show_bg
      }
    fi
  done
else
  LAST=""
  while true; do
    CURR=$(lsblk -ndo NAME,TYPE | awk '$2=="part" && $1 ~ /^sd[b-z][0-9]+$/ {print "/dev/"$1}' | head -n1)
    if [ -n "$CURR" ] && [ "$CURR" != "$LAST" ]; then
      stop_vid
      timeout 60s sudo -u player /home/player/play-videos.sh "$CURR" < /dev/tty1 > /dev/tty1 2>&1 || show_bg
      LAST="$CURR"
    elif [ -z "$CURR" ] && [ -n "$LAST" ]; then
      show_bg
      LAST=""
    fi
    sleep 5
  done
fi
EOF
chmod +x /home/player/usb-watcher.sh
chown player:player /home/player/usb-watcher.sh

cat > /home/player/.xinitrc <<'EOF'
#!/bin/bash
export DISPLAY=:0
xset s off 2>/dev/null; xset -dpms 2>/dev/null; xsetroot -cursor_name left_ptr 2>/dev/null
[ -x /home/player/usb-watcher.sh ] && /home/player/usb-watcher.sh < /dev/tty1 > /dev/tty1 2>&1 &
while true; do sleep 30; done
EOF
chmod +x /home/player/.xinitrc
chown player:player /home/player/.xinitrc

sed -i '/Auto-start X server/,/^fi$/d' /home/player/.bashrc 2>/dev/null || true
cat >> /home/player/.bashrc <<'EOF'

if [ -z "$DISPLAY" ] && [ -t 0 ] && [ "$(tty)" = "/dev/tty1" ]; then
  if [ -z "$PLAYER_X_STARTED" ]; then
    export PLAYER_X_STARTED=1
    sleep 2
    exec startx
  fi
fi
EOF
chown player:player /home/player/.bashrc

mkdir -p /etc/X11
cat > /etc/X11/Xwrapper.config <<'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF

echo ""
echo "VSE GOTOVO! VASHA YOLKA — FON PO UMOLCHANIYU"
echo ""
echo "Fon: /home/player/background/default.jpg"
echo "Video: zacykleno, sluchajnyj poryadok, podderzhka goryachego podklyucheniya"
echo "Logi: /home/player/usb-watcher.log"
echo ""
echo "Perезagruzka: reboot"
