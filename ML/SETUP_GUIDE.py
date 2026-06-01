"""
RPi 5 COMPLETE SETUP GUIDE
============================
Follow every step in order. Don't skip anything.
This guide covers OS setup, wiring, software, and testing.
"""

# ══════════════════════════════════════════════════════════════
# PHASE 1 — OS AND HARDWARE SETUP (Do this first)
# ══════════════════════════════════════════════════════════════

"""
STEP 1: Flash Raspberry Pi OS onto SD Card
──────────────────────────────────────────
On your LAPTOP (not RPi):

1. Download Raspberry Pi Imager from:
   https://www.raspberrypi.com/software/

2. Open Imager:
   - Device: Raspberry Pi 5
   - OS: "Raspberry Pi OS (64-bit)" — use 64-bit, NOT 32-bit
   - Storage: your SD card (32GB minimum)

3. Click the gear icon ⚙ before writing — configure:
   - Hostname: autonomous-car
   - Enable SSH: YES
   - Username: pi
   - Password: your choice (remember it)
   - WiFi SSID and password: your home WiFi

4. Click WRITE → wait 5-10 minutes

5. Insert SD into RPi 5, connect HDMI + keyboard + mouse (or just use SSH)
   Power on with USB-C 5V/5A supply

6. First boot takes ~2 minutes. You'll see desktop or login prompt.
"""


"""
STEP 2: First Boot Configuration
──────────────────────────────────
Either use the desktop or SSH in:
    ssh pi@autonomous-car.local
    (password you set in Imager)

Run these commands ONE BY ONE:

    sudo apt update && sudo apt upgrade -y

This takes ~5 minutes. Say yes to everything.
"""


"""
STEP 3: Enable UART for Basys 3 Communication
───────────────────────────────────────────────
The UART on RPi 5 needs to be enabled and freed from the console.

Run:
    sudo raspi-config

Navigate:
    Interface Options → Serial Port
    "Would you like a login shell accessible over serial?" → NO
    "Would you like the serial port hardware enabled?" → YES
    Finish → YES to reboot

After reboot, verify UART is available:
    ls /dev/ttyAMA*
    You should see: /dev/ttyAMA0  (this connects to Basys 3)

Test UART is free:
    python3 -c "import serial; s=serial.Serial('/dev/ttyAMA0',115200); print('UART OK'); s.close()"
"""


"""
STEP 4: Wire Everything Up
───────────────────────────
IMPORTANT: All connections made with power OFF.

─── OV7670 → Basys 3 (same as before, no change) ───────────────────

─── Basys 3 → Raspberry Pi 5 ──────────────────────────────────────
Basys 3 Pmod JC Pin 1  (UART TX)  →  RPi Pin 10  (GPIO 15, RX)
Basys 3 Pmod JC Pin 7  (UART RX)  →  RPi Pin  8  (GPIO 14, TX)
Basys 3 Pmod GND                  →  RPi Pin  6  (GND)

Both are 3.3V logic — NO level shifter needed.

RPi 5 GPIO layout (BCM numbering):
   Pin  1 = 3.3V    Pin  2 = 5V
   Pin  3 = GPIO 2  Pin  4 = 5V
   Pin  5 = GPIO 3  Pin  6 = GND     ← Connect Basys GND here
   Pin  7 = GPIO 4  Pin  8 = GPIO 14 (TX) ← Connect to Basys JC Pin 7
   Pin  9 = GND     Pin 10 = GPIO 15 (RX) ← Connect to Basys JC Pin 1
   ...
   Pin 11 = GPIO 17 (AIN1)
   Pin 12 = GPIO 18 (PWMA)  ← Hardware PWM
   Pin 13 = GPIO 27 (AIN2)
   Pin 15 = GPIO 22 (BIN1)
   Pin 16 = GPIO 23 (BIN2)
   Pin 33 = GPIO 13 (PWMB)  ← Hardware PWM
   Pin 25 = GND (for TB6612FNG)

─── Raspberry Pi 5 → TB6612FNG ────────────────────────────────────
RPi Pin 11 (GPIO 17)  →  TB6612FNG  AIN1
RPi Pin 13 (GPIO 27)  →  TB6612FNG  AIN2
RPi Pin 12 (GPIO 18)  →  TB6612FNG  PWMA   (hardware PWM pin)
RPi Pin 15 (GPIO 22)  →  TB6612FNG  BIN1
RPi Pin 16 (GPIO 23)  →  TB6612FNG  BIN2
RPi Pin 33 (GPIO 13)  →  TB6612FNG  PWMB   (hardware PWM pin)
RPi Pin  1 (3.3V)     →  TB6612FNG  STBY   (must be HIGH to enable)
RPi Pin  1 (3.3V)     →  TB6612FNG  VCC    (logic supply)
Battery + (7.4V)      →  TB6612FNG  VM     (motor supply)
Common GND            →  TB6612FNG  GND

─── TB6612FNG → Motors ─────────────────────────────────────────────
TB6612FNG AO1  →  Left Motor  +
TB6612FNG AO2  →  Left Motor  -
TB6612FNG BO1  →  Right Motor +
TB6612FNG BO2  →  Right Motor -

─── ESP32-CAM Setup ─────────────────────────────────────────────────
Option A (recommended): USB cable from ESP32-CAM to RPi 5 USB port
Option B: WiFi — ESP32-CAM hosts a stream, RPi fetches frames

For USB option: Flash ESP32-CAM with the camera server sketch (see below)
"""


"""
STEP 5: Install Software on RPi 5
───────────────────────────────────
SSH into RPi or open a terminal.

5a. Install system packages:
    sudo apt install -y python3-pip python3-dev python3-venv
    sudo apt install -y libopencv-dev python3-opencv
    sudo apt install -y libatlas-base-dev libhdf5-dev
    sudo apt install -y git cmake

5b. Create virtual environment (keeps things clean):
    cd ~
    python3 -m venv autonomous_env
    source autonomous_env/bin/activate
    echo "source ~/autonomous_env/bin/activate" >> ~/.bashrc

5c. Install Python packages (takes 10-15 mins):
    pip install --upgrade pip
    pip install tensorflow          # Full TF, not just lite — RPi 5 can handle it
    pip install ultralytics         # YOLOv8
    pip install opencv-python       # Computer vision
    pip install pyserial            # UART to Basys 3
    pip install RPi.GPIO            # GPIO motor control
    pip install pillow numpy scipy

5d. Verify installations:
    python3 -c "import tensorflow as tf; print('TF version:', tf.__version__)"
    python3 -c "from ultralytics import YOLO; print('YOLO OK')"
    python3 -c "import serial; print('Serial OK')"
    python3 -c "import RPi.GPIO as GPIO; print('GPIO OK')"

All should print without errors.
"""


"""
STEP 6: Copy Project Files to RPi 5
────────────────────────────────────
On your LAPTOP, copy files to RPi using SCP:

    scp main.py pi@autonomous-car.local:~/autonomous_env/
    scp modules.py pi@autonomous-car.local:~/autonomous_env/
    scp models/traffic_sign_efficientnet.h5 pi@autonomous-car.local:~/autonomous_env/models/
    scp models/class_labels.json pi@autonomous-car.local:~/autonomous_env/models/

Or using a USB drive:
    Copy all .py files and model files to USB
    On RPi: cp /media/pi/USBDRIVE/*.py ~/autonomous_env/
"""


"""
STEP 7: Split modules.py into Individual Files
───────────────────────────────────────────────
The modules.py contains multiple classes. Split it:

    cd ~/autonomous_env
    python3 << 'SPLIT_EOF'
import re

with open('modules.py') as f:
    content = f.read()

# The file has sections separated by triple-quote docstrings
# Just run modules.py to make everything available,
# OR manually split into:
#   fpga_interface.py
#   motor_controller.py
#   navigation_fsm.py
#   object_detector.py
#   sign_verifier.py

print("See modules.py — copy each class into its own file")
SPLIT_EOF

Actually easier: just import everything from modules.py
In main.py, change imports to:
    from modules import FPGAInterface, MotorController, NavigationFSM
    from modules import NavigationFSM, NavState, SignClass
    from modules import ObjectDetector, SignVerifier

Edit main.py:
    nano main.py
    Change the import section at top to:
        from modules import (FPGAInterface, MotorController,
                             NavigationFSM, NavState, SignClass,
                             ObjectDetector, SignVerifier)
"""


# ══════════════════════════════════════════════════════════════
# PHASE 2 — TESTING EACH COMPONENT INDIVIDUALLY
# ══════════════════════════════════════════════════════════════

"""
STEP 8: Test UART Connection (Basys 3 ↔ RPi 5)
─────────────────────────────────────────────────
First flash the Basys 3 bitstream. Then:

On RPi 5, run this test:

    python3 << 'TEST_EOF'
import serial, time

ser = serial.Serial('/dev/ttyAMA0', 115200, timeout=2)
print("Waiting for packets from Basys 3...")
buf = bytearray()
t = time.time()
while time.time() - t < 10:
    if ser.in_waiting:
        buf.extend(ser.read(ser.in_waiting))
        while len(buf) >= 13:
            if buf[0] == 0xAA and buf[12] == 0x55:
                print(f"Packet: sign={buf[1]} conf={buf[2]} "
                      f"red={buf[3]<<8|buf[4]} "
                      f"left_x={buf[9]} right_x={buf[10]} "
                      f"err={buf[11]}")
                buf = buf[13:]
            else:
                buf.pop(0)
ser.close()
TEST_EOF

Expected output (with camera connected and LED1 on Basys 3 lit):
    Packet: sign=0 conf=0 red=0 left_x=20 right_x=140 err=0

If nothing appears: check wiring, check Basys 3 is flashed, check LED1 is on.
"""


"""
STEP 9: Test Motors
────────────────────
Run motor test WITHOUT anything connected to the mat first.
Lift the bot off the ground.

    python3 << 'MOTOR_TEST_EOF'
import RPi.GPIO as GPIO
import time

GPIO.setmode(GPIO.BCM)
GPIO.setwarnings(False)

pins = {'ain1':17, 'ain2':27, 'pwma':18, 'bin1':22, 'bin2':23, 'pwmb':13, 'stby':24}
for p in pins.values():
    GPIO.setup(p, GPIO.OUT)

GPIO.output(pins['stby'], GPIO.HIGH)  # Enable

pwma = GPIO.PWM(pins['pwma'], 1000)
pwmb = GPIO.PWM(pins['pwmb'], 1000)
pwma.start(0); pwmb.start(0)

def forward(speed=60):
    GPIO.output(pins['ain1'], 1); GPIO.output(pins['ain2'], 0)
    GPIO.output(pins['bin1'], 1); GPIO.output(pins['bin2'], 0)
    pwma.ChangeDutyCycle(speed); pwmb.ChangeDutyCycle(speed)

def stop():
    pwma.ChangeDutyCycle(0); pwmb.ChangeDutyCycle(0)

print("Forward 2 seconds...")
forward(60)
time.sleep(2)
stop()
print("Stop 1 second...")
time.sleep(1)

print("Forward again...")
forward(40)
time.sleep(2)
stop()

pwma.stop(); pwmb.stop()
GPIO.cleanup()
print("Motor test done!")
MOTOR_TEST_EOF

Both wheels should spin forward. If one goes backward: swap its AO1/AO2 wires on TB6612FNG.
If neither moves: check STBY pin is HIGH, check battery connected to VM.
"""


"""
STEP 10: Test YOLOv8 Object Detection
───────────────────────────────────────
    python3 << 'YOLO_TEST_EOF'
from ultralytics import YOLO
import cv2

model = YOLO('yolov8n.pt')  # Downloads ~6MB on first run
print("YOLOv8 loaded")

# Test on a webcam frame or static image
# If you have a USB webcam connected:
cap = cv2.VideoCapture(0)
if cap.isOpened():
    ret, frame = cap.read()
    if ret:
        results = model(frame, conf=0.4, verbose=False)
        for r in results:
            for box in r.boxes:
                cls = model.names[int(box.cls[0])]
                conf = float(box.conf[0])
                print(f"  Detected: {cls} ({conf:.1%})")
    cap.release()
else:
    # Test on a test image
    import numpy as np
    fake_img = np.zeros((480,640,3), dtype=np.uint8)
    results = model(fake_img, verbose=False)
    print("YOLO inference OK (no objects in blank image)")

print("YOLO test done!")
YOLO_TEST_EOF
"""


"""
STEP 11: Test TFLite Sign Classifier
──────────────────────────────────────
    python3 << 'TFLITE_TEST_EOF'
import tensorflow as tf
import numpy as np
import json

model_path = 'models/traffic_sign_efficientnet.h5'
# OR use tflite:
# from modules import SignVerifier
# v = SignVerifier('models/traffic_sign_efficientnet.tflite')

model = tf.keras.models.load_model(model_path)
print(f"Model loaded, input: {model.input_shape}")

# Test with random image (just checking it runs)
import numpy as np
fake = np.random.rand(1, 224, 224, 3).astype('float32')
# Apply preprocessing
fake = fake * 2.0 - 1.0  # scale to [-1,1]
pred = model.predict(fake, verbose=0)
print(f"Output shape: {pred.shape}")
print(f"Predicted class: {np.argmax(pred[0])} (confidence: {pred[0].max():.1%})")
print("TFLite sign classifier OK!")
TFLITE_TEST_EOF
"""


# ══════════════════════════════════════════════════════════════
# PHASE 3 — LINE FOLLOWING MAT SETUP
# ══════════════════════════════════════════════════════════════

"""
STEP 12: Setting Up the Line Following Mat
───────────────────────────────────────────
Your mat/banner works PERFECTLY. Here's the setup:

CAMERA MOUNTING:
  - Mount OV7670 on front of car, angled DOWN at ~45 degrees
  - Should see ~30-50cm of the mat in front
  - Height: 5-10cm from mat surface
  - The camera faces forward and slightly down

WHAT THE FPGA SEES:
  The mat has dark line on light background (or light on dark).
  Sobel edge detection finds the EDGES of this line.
  The lane_detector finds left_x and right_x of the line.
  center_err tells the car if it's drifting off.

THRESHOLD ADJUSTMENT FOR YOUR MAT:
  If your mat has a HIGH contrast line (sharp black on white):
    → Lower the Sobel threshold in vision_pipeline.vhd:
      Change: generic (THRESHOLD : integer := 25;
      To:     generic (THRESHOLD : integer := 15;
    → Resynthesize and flash

  If your mat has a LOWER contrast line:
    → Keep threshold at 25 or raise to 30

TRACK LAYOUT FOR PRESENTATION:
  Arrange your mat in an oval/loop.
  Print A4 paper signs and place them at key points:

         ┌─────────────────────┐
         │   STOP sign here    │
         │                     │
  START  │  ←─────────────     │
         │           │         │
         │  WARNING  │         │
         │   sign    │         │
         └───────────┘         │
                               │
    Print these signs on A4:   │
    - Red STOP octagon         │
    - Yellow warning triangle  │
    - Green circular GO sign   │

The car will:
  1. Follow the line (FPGA lane detection)
  2. Stop at STOP sign (FPGA sign detection → RPi FSM)
  3. Slow at WARNING sign
  4. Continue at GO sign
  5. Stop if you put your hand in front (YOLO person detection)

MAKING THE SIGNS:
  Print these images and tape to cardboard:
  - Google: "stop sign printable" → print on A4, red background
  - Google: "yield sign printable" → yellow triangle
  - Google: "green go sign"
  Place them upright facing the camera at corners of your track.
"""


# ══════════════════════════════════════════════════════════════
# PHASE 4 — RUNNING THE FULL SYSTEM
# ══════════════════════════════════════════════════════════════

"""
STEP 13: Full System Run
─────────────────────────
Final checklist before running:

□ Basys 3 flashed with bitstream (LED 1 should be ON)
□ OV7670 connected to Basys 3 Pmod JA/JB/JC
□ Basys 3 UART connected to RPi 5 pins 8/10/6
□ TB6612FNG wired to RPi GPIO and motors
□ 18650 battery connected to TB6612FNG VM
□ RPi 5 powered via USB-C
□ Bot lifted off ground for first test

Run the system:
    cd ~/autonomous_env
    source ~/autonomous_env/bin/activate
    sudo python3 main.py

You should see:
    =========================================
      Autonomous Car — Raspberry Pi 5 Controller
      FPGA: Basys 3 Artix-7 (vision pipeline)
    =========================================
    [FPGA] Connected on /dev/ttyAMA0 @ 115200
    [MOTOR] TB6612FNG initialized
    [YOLO] Model loaded: yolov8n.pt
    [NEURAL] TFLite model loaded
    [NAV] Starting navigation FSM...
    All systems running. Press Ctrl+C to stop.

Status prints every 2 seconds:
    ─────────────────────────────────────────────────────
      FPGA Sign    : NONE (conf=0)
      Lane         : L=20 R=140 Err=+0
      YOLO         : persons=0 cars=0 obstacle=False
      Nav State    : FORWARD
    ─────────────────────────────────────────────────────

STEP 14: First Live Test
─────────────────────────
1. Put bot on the mat, motors running
2. Watch lane data: L and R values should change as bot moves
3. Hold a red sign in front of camera → should print STOP
4. Put your hand in front → YOLO should say obstacle=True → STOP

STEP 15: Troubleshooting
─────────────────────────
Problem: No UART packets from FPGA
    → Check Basys 3 LED 1 is on (camera configured)
    → Check wire from JC Pin 1 → RPi Pin 10
    → Check ground connection

Problem: Motors don't respond
    → Check battery voltage (should be 7.4V)
    → Check STBY pin is connected to 3.3V
    → Run motor test from Step 9

Problem: Sign not detected
    → Check OV7670 connections
    → Watch Basys 3 LEDs 14-15 (should light up when red sign visible)
    → Try better lighting (bright room)

Problem: YOLO not detecting objects
    → Make sure USB camera or ESP32-CAM is connected
    → Check cap = cv2.VideoCapture(0) opens correctly

Problem: Car doesn't follow mat line
    → Camera angle: tilt more downward
    → Threshold: lower from 25 to 15 in VHDL
    → Check lane_valid LED (LED 12) on Basys 3
"""
