#!/bin/bash
# ============================================================
# setup_rpi5.sh
# Run this ONCE on fresh Raspberry Pi 5 to install everything
# Usage: chmod +x setup_rpi5.sh && sudo ./setup_rpi5.sh
# ============================================================

echo "================================================"
echo "  Autonomous Car — RPi 5 Setup Script"
echo "================================================"

# Update system
echo "[1/8] Updating system..."
apt-get update -q && apt-get upgrade -y -q

# Install system packages
echo "[2/8] Installing system packages..."
apt-get install -y python3-pip python3-venv python3-dev
apt-get install -y libopencv-dev python3-opencv
apt-get install -y python3-rpi.gpio python3-serial
apt-get install -y libatlas-base-dev libhdf5-dev

# Enable UART for Basys 3 communication
echo "[3/8] Configuring UART..."
# Add to /boot/config.txt
if ! grep -q "enable_uart=1" /boot/config.txt; then
    echo "enable_uart=1" >> /boot/config.txt
fi
# Disable serial console (so UART is free for Basys 3)
systemctl disable serial-getty@ttyAMA0.service 2>/dev/null || true
sed -i 's/console=serial0,115200 //' /boot/cmdline.txt 2>/dev/null || true

# Install Python packages
echo "[4/8] Installing Python packages..."
pip3 install --break-system-packages \
    ultralytics \
    tflite-runtime \
    pyserial \
    numpy \
    pillow \
    opencv-python \
    RPi.GPIO

# Create project directory
echo "[5/8] Creating project directory..."
mkdir -p /home/pi/autonomous_car
mkdir -p /home/pi/autonomous_car/models
mkdir -p /home/pi/autonomous_car/logs

# Copy Python files (assumes running from project dir)
echo "[6/8] Copying project files..."
cp *.py /home/pi/autonomous_car/
chown -R pi:pi /home/pi/autonomous_car/

# Create systemd service for autostart
echo "[7/8] Creating autostart service..."
cat > /etc/systemd/system/autonomous_car.service << 'SERVICE_EOF'
[Unit]
Description=Autonomous Car Controller
After=network.target

[Service]
Type=simple
User=pi
WorkingDirectory=/home/pi/autonomous_car
ExecStart=/usr/bin/python3 /home/pi/autonomous_car/main.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
# DON'T enable autostart yet — test first
# systemctl enable autonomous_car

# Download YOLOv8 nano model
echo "[8/8] Downloading YOLOv8 nano model (~6MB)..."
python3 -c "
from ultralytics import YOLO
model = YOLO('yolov8n.pt')
print('YOLOv8-nano downloaded successfully')
"

echo ""
echo "================================================"
echo "  SETUP COMPLETE"
echo "================================================"
echo ""
echo "  NEXT STEPS:"
echo "  1. Copy your .tflite model to /home/pi/autonomous_car/models/"
echo "  2. Copy class_labels.json to same folder"
echo "  3. Reboot: sudo reboot"
echo "  4. Test UART: python3 -c \"import serial; s=serial.Serial('/dev/ttyAMA0',115200); print('UART OK')\""
echo "  5. Run: cd /home/pi/autonomous_car && sudo python3 main.py"
echo ""
echo "  UART PINS (connect to Basys 3 Pmod JC):"
echo "  RPi Pin 8  (GPIO 14, TX) → Basys 3 JC Pin 7 (RX)"
echo "  RPi Pin 10 (GPIO 15, RX) → Basys 3 JC Pin 1 (TX)"
echo "  RPi Pin 6  (GND)         → Basys 3 GND"
echo "================================================"
