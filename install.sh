#!/bin/bash
set -e

# Проверка root
if [ "$EUID" -eq 0 ]; then
  echo "Запускайте скрипт от обычного пользователя с sudo-доступом (не от root)."
  exit 1
fi

if ! command -v sudo &> /dev/null; then
  echo "sudo не найден. Установите или запустите от пользователя с правами администратора."
  exit 1
fi

echo "[*] Установка зависимостей..."
sudo apt update
sudo apt install -y xserver-xorg xinit mpv udisks2 x11-xserver-utils

# Создание пользователя player
if ! id "player" &>/dev/null; then
  echo "[*] Создание пользователя 'player'..."
  sudo adduser --disabled-password --gecos "" player
  sudo usermod -aG audio,video player
fi

# Настройка автологина в tty1
echo "[*] Настройка автологина в tty1..."
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
cat <<EOF | sudo tee /etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin player --noclear %I \$TERM
EOF

# Скрипт воспроизведения
echo "[*] Создание скрипта воспроизведения..."
cat <<'EOF' | sudo tee /home/player/play_usb.sh
#!/bin/bash
sleep 10

USB_MEDIA="/media/player"
MAX_WAIT=300
COUNT=0

while [ $COUNT -lt $MAX_WAIT ]; do
  if ls "$USB_MEDIA"/*/ >/dev/null 2>&1; then
    break
  fi
  sleep 1
  ((COUNT++))
done

VIDEO_DIR=$(ls -1d "$USB_MEDIA"/*/ 2>/dev/null | head -n1)

if [ -z "$VIDEO_DIR" ]; then
  echo "USB flash not found or no media mounted."
  sleep 10
  exit 1
fi

# Отключаем энергосбережение и курсор
xset s off
xset -dpms
xsetroot -cursor_name left_ptr

# Запуск mpv
exec mpv --no-terminal --fs --panscan=1 --loop-playlist=inf --shuffle=no \
  --hwdec=auto \
  "$VIDEO_DIR"/*.mp4 "$VIDEO_DIR"/*.mkv "$VIDEO_DIR"/*.avi "$VIDEO_DIR"/*.mov
EOF

sudo chmod +x /home/player/play_usb.sh
sudo chown player:player /home/player/play_usb.sh

# Автозапуск X при входе в tty1
echo "[*] Настройка автозапуска X + mpv..."
cat <<'EOF' | sudo tee -a /home/player/.bashrc

# Auto-start video player on tty1
if [ -z "\$DISPLAY" ] && [ "\$(tty)" = "/dev/tty1" ]; then
  export DISPLAY=:0
  xinit /home/player/play_usb.sh -- -nocursor
fi
EOF

sudo chown player:player /home/player/.bashrc

echo ""
echo "Настройка завершена!"
echo "1. Перезагрузите устройство: sudo reboot"
echo "2. Вставьте FAT32 USB-флешку с видео в корне"
echo "3. После загрузки (~15 сек) начнётся воспроизведение"
echo ""
echo "Пользователь: player (без пароля)"
