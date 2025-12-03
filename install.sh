#!/bin/bash
set -e

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root."
  exit 1
fi

if [ "$(uname -m)" != "x86_64" ]; then
  echo "WARNING: Optimized for x86_64 nettops."
  read -p "Continue? (y/N): " -n 1 -r
  echo
  if ! [[ $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

echo "[*] Installing packages..."
(
  apt update -qq 2>/dev/null || true
  apt install -y -o DPkg::Lock::Timeout=60 \
    xserver-xorg xinit mpv udisks2 x11-xserver-utils \
    xterm ffmpeg gstreamer1.0-libav ntfs-3g exfat-fuse exfatprogs \
    feh imagemagick curl x11-utils xosd-bin 2>/dev/null || echo "Continuing."
)

if ! id "player" &>/dev/null; then
  adduser --disabled-password --gecos "" player 2>/dev/null || true
fi
usermod -aG audio,video,input,dialout player 2>/dev/null || true

# Autologin on tty1
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin player --noclear %I $TERM
EOF

# Background
BACKGROUND_DIR="/home/player/background"
BACKGROUND_FILE="$BACKGROUND_DIR/default.jpg"
mkdir -p "$BACKGROUND_DIR"
chown player:player "$BACKGROUND_DIR"

ELKA_URL="https://raw.githubusercontent.com/deddosouru/scripts/main/elka-ukrasena-ognami.jpg"
echo "[*] Downloading background..."
if command -v curl >/dev/null && curl -fsSL --max-time 15 "$ELKA_URL" -o "$BACKGROUND_FILE"; then
  echo -e "\033[1;32m[OK] Background downloaded.\033[0m"
else
  echo -e "\033[1;33m[!] Failed. Creating black fallback.\033[0m"
  if command -v convert >/dev/null; then
    convert -size 1920x1080 xc:black "$BACKGROUND_FILE" 2>/dev/null || touch "$BACKGROUND_FILE"
  else
    touch "$BACKGROUND_FILE"
  fi
fi
chown player:player "$BACKGROUND_FILE"

# Video playback script — WITH loop and shuffle
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

# LOOP + SHUFFLE ENABLED
exec mpv --no-terminal --fs --panscan=1 --loop-playlist=inf --shuffle --hwdec=auto "${VIDEO_FILES[@]}"
EOF
chmod +x /home/player/play-videos.sh
chown player:player /home/player/play-videos.sh

# USB watcher with OSD/xmessage fallback and sda/mmcblk fix
cat > /home/player/usb-watcher.sh <<'EOF'
#!/bin/bash
exec >> /home/player/usb-watcher.log 2>&1
set -x

BG="/home/player/background/default.jpg"
LOG="/home/player/usb-watcher.log"

# Determine OSD method
if command -v osd_cat >/dev/null && [ -n "$DISPLAY" ]; then
  use_osd="yes"
else
  use_osd="no"
fi

# Unified notification function
notify() {
  local msg="$1"
  export DISPLAY=:0
  if [ "$use_osd" = "yes" ]; then
    echo "$msg" | osd_cat -p top -A center -d 4 -f "-*-*-*-*-*-*-24-*-*-*-*-*-*-*" 2>/dev/null &
  else
    timeout 4 xmessage -center "$msg" 2>/dev/null &
  fi
}

show_bg() {
  pkill -f feh 2>/dev/null; sleep 1
  export DISPLAY=:0
  [ -f "$BG" ] && feh --bg-fill "$BG" &
  notify "Background displayed"
}

stop_all() {
  pkill -f mpv 2>/dev/null; pkill -f feh 2>/dev/null; sleep 2
}

show_bg

# Manual menu
while true; do
  if [ -f /tmp/menu-request ]; then
    rm -f /tmp/menu-request
    {
      echo "=== SYSTEM CONTROL MENU ==="
      echo "1) Restart X"
      echo "2) Power off"
      echo "3) Reboot"
      echo "4) Show logs"
      echo "5) Show background"
      read -t 30 -p "Choice: " choice
      case "$choice" in
        1) notify "Restarting X..."; pkill -f "xinit|Xorg"; sleep 2; sudo -u player startx & ;;
        2) notify "Shutting down..."; sudo poweroff ;;
        3) notify "Rebooting..."; sudo reboot ;;
        4) tail -n 20 "$LOG" > /dev/tty2 ;;
        5) stop_all; show_bg ;;
        *) echo "Cancelled." ;;
      esac
    } > /dev/tty2 2>&1
  fi

  # Detect REMOVABLE USB (supports sda, sdb, etc.; ignores mmcblk*)
  USB_PART=""
  while IFS= read -r line; do
    DEV=$(echo "$line" | awk '{print $1}')
    RM=$(echo "$line" | awk '{print $2}')
    TYPE=$(echo "$line" | awk '{print $3}')
    NAME=$(echo "$line" | awk '{print $6}')
    if [ "$RM" = "1" ] && [ "$TYPE" = "part" ] && [[ "$NAME" != mmcblk* ]]; then
      USB_PART="/dev/$DEV"
      break
    fi
  done < <(lsblk -r -d -o NAME,REMovable,TYPE,SIZE,MOUNTPOINT,PKNAME 2>/dev/null | tail -n +2)

  if [ -n "$USB_PART" ]; then
    notify "USB detected: $USB_PART"
    MOUNT_POINT=$(lsblk -n -o MOUNTPOINT "$USB_PART" 2>/dev/null)
    if [ -z "$MOUNT_POINT" ]; then
      MOUNT_POINT="/mnt/usb-$(basename "$USB_PART")"
      mkdir -p "$MOUNT_POINT"
      if mount "$USB_PART" "$MOUNT_POINT" 2>/dev/null; then
        notify "Mounted: $MOUNT_POINT"
      else
        notify "Mount failed: $USB_PART"
        sleep 2
        continue
      fi
    fi

    if [ -d "$MOUNT_POINT" ]; then
      shopt -s nullglob nocaseglob
      VIDEO_FILES=("$MOUNT_POINT"/*.mp4 "$MOUNT_POINT"/*.mkv "$MOUNT_POINT"/*.avi "$MOUNT_POINT"/*.mov)
      if [ ${#VIDEO_FILES[@]} -gt 0 ]; then
        notify "Found ${#VIDEO_FILES[@]} video(s). Starting looped shuffle playback..."
        stop_all
        sudo -u player /home/player/play-videos.sh "$MOUNT_POINT" < /dev/tty1 > /dev/tty1 2>&1 &
      else
        notify "No video files in $MOUNT_POINT"
      fi
    fi
  fi

  sleep 5
done
EOF
chmod +x /home/player/usb-watcher.sh
chown player:player /home/player/usb-watcher.sh

# .xinitrc
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

# .bashrc
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

# X permissions
mkdir -p /etc/X11
cat > /etc/X11/Xwrapper.config <<'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF

# sudoers
echo 'player ALL=(ALL) NOPASSWD: /sbin/reboot, /sbin/poweroff, /usr/bin/pkill, /usr/bin/startx' > /etc/sudoers.d/99-player-nopasswd
chmod 440 /etc/sudoers.d/99-player-nopasswd

echo ""
echo -e "\033[1;32m[SUCCESS] Setup complete!\033[0m"
echo ""
echo "Features:"
echo " - Loop playback + shuffle enabled"
echo " - Supports ANY removable USB (sda, sdb, etc.)"
echo " - eMMC (mmcblk*) correctly ignored"
echo " - On-screen debug messages (osd_cat or xmessage)"
echo ""
echo -e "\033[1;33m[INFO] Control:\033[0m"
echo "   TTY2: touch /tmp/menu-request → manage system"
echo ""
echo "Reboot to apply: sudo reboot"
