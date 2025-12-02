#!/bin/bash
set -e

# Proverka: dolzhen byt' zapushen ot root ili pol'zovatelya s dostupom k su
if [ "$(id -u)" -ne 0 ]; then
  echo "Skript nuzhno zapuskat' ot root (ili cherez 'su')."
  echo "Primer: su -c './debian-usb-video-player-setup.sh'"
  exit 1
fi

OS_ID=$(grep -oP '^ID=\K.+' /etc/os-release 2>/dev/null | tr -d '"')
if [ "$OS_ID" != "debian" ]; then
  echo "Vnimanie: skript prednaznachen dlya Debian 12+. Prodolzhit'?"
  read -p " (y/N): " -n 1 -r
  echo
  if ! [[ $REPLY =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

echo "[*] Obnovlenie paketov..."
apt update

echo "[*] Ustanovka zavisimostey: X11, mpv, udisks2..."
apt install -y xserver-xorg xinit mpv udisks2 x11-xserver-utils xinit xterm

# Sozdanie pol'zovatelya 'player', esli ego net
if ! id "player" &>/dev/null; then
  echo "[*] Sozdaem pol'zovatelya 'player'..."
  adduser --disabled-password --gecos "" player
  usermod -aG audio,video,input player
else
  echo "[*] Pol'zovatel 'player' uzhe sushchestvuet."
fi

# Nastrojka avtologina v tty1
echo "[*] Nastrojka avtologina na tty1..."
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin player --noclear %I $TERM
EOF

# Sozdaem .xinitrc — osnovnoj skript dlya X sesii
echo "[*] Sozdaem /home/player/.xinitrc..."
cat > /home/player/.xinitrc <<'EOF'
#!/bin/bash
xset s off
xset -dpms
xsetroot -cursor_name left_ptr

USB_MEDIA="/media/player"
MAX_WAIT=300
COUNT=0

while [ $COUNT -lt $MAX_WAIT ]; do
  VIDEO_DIR=$(ls -1d "$USB_MEDIA"/*/ 2>/dev/null | head -n1)
  if [ -n "$VIDEO_DIR" ]; then
    break
  fi
  sleep 1
  ((COUNT++))
done

if [ -z "$VIDEO_DIR" ]; then
  xmessage -center "USB flash ne naydena ili net video!" &
  sleep 10
  exit 1
fi

exec mpv --no-terminal --fs --panscan=1 --loop-playlist=no --shuffle=no \
  --hwdec=auto \
  "$VIDEO_DIR"/*.mp4 "$VIDEO_DIR"/*.mkv "$VIDEO_DIR"/*.avi "$VIDEO_DIR"/*.mov
EOF

chmod +x /home/player/.xinitrc
chown player:player /home/player/.xinitrc

# Obnovlyaem .bashrc: zapusk startx tol'ko iz tty1
echo "[*] Nastrojka avtozapусka X cherez .bashrc..."
BASHRC_LINE='if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then'

if grep -qF "$BASHRC_LINE" /home/player/.bashrc; then
  echo "[*] .bashrc uzhe soderzhit blok avtozapусka — obnovlyaem..."
  # Udalyaem staryj blok
  sed -i '/^# Auto-start X server/,/^fi$/d' /home/player/.bashrc
fi

cat >> /home/player/.bashrc <<'EOF'

# Auto-start X server (and video player via .xinitrc) only on local tty1
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  if [ -z "$PLAYER_X_STARTED" ]; then
    export PLAYER_X_STARTED=1
    sleep 2
    exec startx
  fi
fi
EOF

chown player:player /home/player/.bashrc

# Reshaem problemu "only console users..." cherez Xwrapper
echo "[*] Nastrojka Xwrapper dlya razresheniya X ot obychnogo pol'zovatelya..."
cat > /etc/X11/Xwrapper.config <<'EOF'
allowed_users=anybody
needs_root_rights=yes
EOF

# Proverka ustanovki
echo ""
echo "✅ NASTROJKA ZAVERShENA!"
echo ""
echo "Chto delat' dal'she:"
echo "1. Perезagruzite sistemу: reboot"
echo "2. Vstav'te FAT32 USB-fleshku s video v korne"
echo "3. Posle zagruzki (~15 sek) nachnetsya vosproizvedenie"
echo ""
echo "Pol'zovatel: player"
echo "Dlya testa v ruchnuю: zaloginites' kak 'player' v TTY1 i vvedite 'startx'"
