#!/bin/bash
set -e

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root."
  exit 1
fi

if [ "$(uname -m)" != "x86_64" ]; then
  echo "WARNING: This script is optimized for x86_64 (nettop)."
  read -p "Continue anyway? (y/N): " -n 1 -r
  echo
  if ! [[ $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

echo "[*] Installing required packages..."
(
  apt update -qq 2>/dev/null || true
  apt install -y -o DPkg::Lock::Timeout=60 \
    xserver-xorg xinit mpv udisks2 x11-xserver-utils \
    xterm ffmpeg gstreamer1.0-libav ntfs-3g exfat-fuse exfatprogs \
    feh imagemagick curl x11-utils 2>/dev/null || echo "Continuing with available packages."
)

if ! id "player" &>/dev/null; then
  adduser --disabled-password --gecos "" player 2>/dev/null || true
fi
usermod -aG audio,video,input,dialout player 2>/dev/null || true

# Configure autologin on tty1
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin player --noclear %I $TERM
EOF

# === Download background image ===
BACKGROUND_DIR="/home/player/background"
BACKGROUND_FILE="$BACKGROUND_DIR/default.jpg"
mkdir -p "$BACKGROUND_DIR"
chown player:player "$BACKGROUND_DIR"

ELKA_URL="https://raw.githubusercontent.com/deddosouru/scripts/main/elka-ukrasena-ognami.jpg"
echo "[*] Downloading background image..."
if command -v curl >/dev/null && curl -fsSL --max-time 15 "$ELKA_URL" -o "$BACKGROUND_FILE"; then
  echo -e "\033[1;32m[OK] Background image downloaded successfully.\033[0m"
else
  echo -e "\033[1;33m[!] Failed to download background. Creating black fallback.\033[0m"
  if command -v convert >/dev/null; then
    convert -size 1920x1080 xc:black "$BACKGROUND_FILE" 2>/dev/null || touch "$BACKGROUND_FILE"
  else
    touch "$BACKGROUND_FILE"
  fi
fi
chown player:player "$BACKGROUND_FILE"
# === End background setup ===

# === Video playback script ===
cat > /home/player/play-videos.sh <<'EOF'
#!/bin/bash
exec >> /home/player/usb-watcher.log 2>&1
set -x

VIDEO_DIR="$1"
[ -n "$VIDEO_DIR" ] && [ -d "$VIDEO_DIR" ] || exit 1

pkill -f "mpv.*$VIDEO_DIR" 2>/dev/null
pkill -f "mpv --no-terminal" 2>/dev/null
sleep 2

shopt -s nullglob nocaseglob
VIDEO_FILES=(
  "$VIDEO_DIR"/*.mp4 "$VIDEO_DIR"/*.mkv "$VIDEO_DIR"/*.avi
  "$VIDEO_DIR"/*.mov "$VIDEO_DIR"/*.m4v "$VIDEO_DIR"/*.flv
  "$VIDEO_DIR"/*.webm "$VIDEO_DIR"/*.wmv
)
VIDEO_FILES=($(for f in "${VIDEO_FILES[@]}"; do [ -f "$f" ] && echo "$f"; done))
[ ${#VIDEO_FILES[@]} -gt 0 ] || exit 1

export DISPLAY=:0
xset q >/dev/null || exit 1

exec mpv --no-terminal --fs --panscan=1 --loop-playlist=inf --shuffle --hwdec=auto "${VIDEO_FILES[@]}"
EOF
chmod +x /home/player/play-videos.sh
chown player:player /home/player/play-videos.sh

# === USB watcher + debug menu ===
cat > /home/player/usb-watcher.sh <<'EOF'
#!/bin/bash
exec >> /home/player/usb-watcher.log 2>&1
set -x

BG="/home/player/background/default.jpg"
LOG="/home/player/usb-watcher.log"

show_bg() {
  pkill -f feh 2>/dev/null
  sleep 1
  export DISPLAY=:0
  [ -f "$BG" ] && feh --bg-fill "$BG" &
}

stop_all() {
  pkill -f mpv 2>/dev/null
  pkill -f feh 2>/dev/null
  sleep 2
}

show_bg

# Debug menu (accessible via 'm' key)
debug_menu() {
  echo ""
  echo "=== SYSTEM CONTROL MENU (X SESSION) ==="
  echo "1) Restart X session"
  echo "2) Power off system"
  echo "3) Reboot system"
  echo "4) View logs"
  echo "5) Stop video and show background"
  echo "q) Exit menu"
  echo -n "Your choice: "
  read choice
  case "$choice" in
    1) echo "Restarting X..."; pkill -f "xinit|Xorg"; sleep 2; startx & ;;
    2) echo "Shutting down..."; sudo poweroff ;;
    3) echo "Rebooting..."; sudo reboot ;;
    4) echo "=== LAST 20 LOG LINES ==="; tail -n 20 "$LOG" ;;
    5) echo "Returning to background..."; stop_all; show_bg ;;
    q) echo "Menu closed." ;;
    *) echo "Unknown command." ;;
  esac
  echo ""
}

# Listen for 'm' key press to trigger menu
if command -v xev >/dev/null && command -v xinput >/dev/null; then
  xinput list 2>/dev/null | grep -q -i "keyboard" && {
    xev -event keyboard 2>/dev/null | while read line; do
      if echo "$line" | grep -q '"m" key press'; then
        echo "Key 'm' pressed — opening menu on TTY2..."
        {
          echo "=== CONTROL MENU ACTIVATED ==="
          debug_menu
        } > /dev/tty2 2>&1 &
      fi
    done &
  }
fi

# Main USB monitoring loop
if command -v udevadm >/dev/null; then
  /sbin/udevadm monitor --udev -s block 2>/dev/null | while read line; do
    if echo "$line" | grep -q "add.*s[d-z][0-9]"; then
      DEV=$(echo "$line" | grep -o "s[d-z][0-9]" | head -n1)
      [ -n "$DEV" ] && [ -e "/dev/$DEV" ] && {
        stop_all
        timeout 60s sudo -u player /home/player/play-videos.sh "/dev/$DEV" < /dev/tty1 > /dev/tty1 2>&1 || show_bg
      }
    fi
  done
else
  LAST=""
  while true; do
    CURR=$(lsblk -ndo NAME,TYPE | awk '$2=="part" && $1 ~ /^sd[b-z][0-9]+$/ {print "/dev/"$1}' | head -n1)
    if [ -n "$CURR" ] && [ "$CURR" != "$LAST" ]; then
      stop_all
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

# === .xinitrc (safe, LF-only) ===
{
  echo '#!/bin/bash'
  echo 'export DISPLAY=:0'
  echo 'xset s off 2>/dev/null'
  echo 'xset -dpms 2>/dev/null'
  echo 'xsetroot -cursor_name left_ptr 2>/dev/null'
  echo 'if [ -x /home/player/usb-watcher.sh ]; then'
  echo '  /home/player/usb-watcher.sh < /dev/tty1 > /dev/tty1 2>&1 &'
  echo 'fi'
  echo 'while true; do sleep 30; done'
} > /home/player/.xinitrc
chmod +x /home/player/.xinitrc
chown player:player /home/player/.xinitrc

# === .bashrc autostart ===
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

# === X server permissions ===
mkdir -p /etc/X11
cat > /etc/X11/Xwrapper.config <<'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF

# === Allow player to reboot/poweroff without password ===
echo 'player ALL=(ALL) NOPASSWD: /sbin/reboot, /sbin/poweroff, /usr/bin/pkill, /usr/bin/startx' > /etc/sudoers.d/99-player-nopasswd
chmod 440 /etc/sudoers.d/99-player-nopasswd

echo ""
echo -e "\033[1;32m[SUCCESS] Setup completed!\033[0m"
echo ""
echo "Features:"
echo " - Background: elka-ukrasena-ognami.jpg (or black fallback)"
echo " - Video: looped, shuffled, hot-plug USB support"
echo ""
echo -e "\033[1;33m[INFO] Debug & Control:\033[0m"
echo "   - Press 'm' during X session to activate control menu"
echo "   - Switch to TTY2 (Ctrl+Alt+F2) to interact"
echo "   - Options: restart X, power off, reboot, view logs"
echo ""
echo "Logs: /home/player/usb-watcher.log"
echo "Reboot to apply: sudo reboot"
