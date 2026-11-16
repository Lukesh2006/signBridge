#!/usr/bin/env bash
# Install or update the SignBridge backend on an Ubuntu / Linux Mint laptop.
#
#   sudo bash install.sh                      # install or update the code
#   sudo bash install.sh "/media/$USER/BUG 2/signBridge"
#                                             # ...and copy seed clips from the USB drive
#
# Safe to run again: it updates the code and keeps existing settings and recordings.
# Full guide: docs/self-hosting-ubuntu.md
set -euo pipefail

REPO_URL="https://github.com/Lukesh2006/signBridge.git"
APP_DIR=/opt/signbridge
DATA_DIR=/var/lib/signbridge
CONF_DIR=/etc/signbridge
UV_DIR=/opt/uv
USB_DIR="${1:-}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run with sudo: sudo bash $0 $*" >&2
  exit 1
fi

echo "==> System packages"
apt-get update -qq
apt-get install -y -qq git python3 python3-venv curl libgl1 libglib2.0-0 >/dev/null

echo "==> Service user"
id signbridge >/dev/null 2>&1 || useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin signbridge

echo "==> Code in $APP_DIR"
if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" pull --ff-only
else
  git clone --depth 1 "$REPO_URL" "$APP_DIR"
fi

echo "==> Python dependencies (uv)"
if [ ! -x "$UV_DIR/bin/uv" ]; then
  python3 -m venv "$UV_DIR"
  "$UV_DIR/bin/pip" install --quiet uv
fi
# Keep any Python that uv downloads outside root's home, so the service can use it.
export UV_PYTHON_INSTALL_DIR="$UV_DIR/python"
cd "$APP_DIR/backend"
"$UV_DIR/bin/uv" sync --frozen

echo "==> Data folder $DATA_DIR"
mkdir -p "$DATA_DIR/training_samples" "$DATA_DIR/personal_models"
if [ -n "$USB_DIR" ]; then
  if [ -d "$USB_DIR/training_samples/seed" ]; then
    cp -rn "$USB_DIR/training_samples/seed" "$DATA_DIR/training_samples/"
    echo "    copied seed clips"
  fi
  if [ -f "$USB_DIR/personal_models/continuous_seed.json" ]; then
    cp -n "$USB_DIR/personal_models/continuous_seed.json" "$DATA_DIR/personal_models/"
    echo "    copied seed model"
  fi
fi
chown -R signbridge:signbridge "$DATA_DIR"
chmod 750 "$DATA_DIR"

echo "==> Settings in $CONF_DIR"
mkdir -p "$CONF_DIR"
[ -f "$CONF_DIR/signbridge.env" ] || cp deployment/ubuntu/signbridge.env.example "$CONF_DIR/signbridge.env"
chown -R root:signbridge "$CONF_DIR"
chmod 750 "$CONF_DIR"
chmod 640 "$CONF_DIR"/*

echo "==> systemd service"
cp deployment/ubuntu/signbridge-backend.service /etc/systemd/system/signbridge-backend.service
systemctl daemon-reload

if [ -f "$CONF_DIR/firebase.json" ] && [ -f "$CONF_DIR/firebase-admin.json" ]; then
  systemctl enable signbridge-backend >/dev/null
  systemctl restart signbridge-backend
  echo "==> Waiting for the backend to start"
  for _ in $(seq 1 30); do
    if curl -fsS http://127.0.0.1:5000/health >/dev/null 2>&1; then
      echo "    Backend is running: http://127.0.0.1:5000/health"
      exit 0
    fi
    sleep 2
  done
  echo "    Backend did not answer yet. Check: sudo journalctl -u signbridge-backend -n 50" >&2
  exit 1
else
  echo
  echo "Next: put firebase.json and firebase-admin.json in $CONF_DIR (guide step 2),"
  echo "then run this script again."
fi
