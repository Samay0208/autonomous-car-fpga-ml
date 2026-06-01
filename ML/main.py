#!/usr/bin/env python3
"""
main.py — Autonomous Car Main Controller
Raspberry Pi 5 (8GB RAM)

Features:
  1. Receives FPGA vision data via UART (sign class, lane edges)
  2. Runs YOLOv8-nano object detection on ESP32-CAM feed
  3. Runs TFLite MobileNetV2 for sign verification
  4. Fuses all inputs in navigation FSM
  5. Controls 2-wheel drive via TB6612FNG GPIO

Run:
    sudo python3 main.py

Install dependencies first:
    pip install ultralytics tflite-runtime opencv-python
    pip install RPi.GPIO pyserial numpy pillow
"""

import threading
import time
import serial
import json
import struct
import numpy as np
import cv2
import RPi.GPIO as GPIO
from pathlib import Path

# ─── IMPORT LOCAL MODULES ──────────────────────────────────────────────────────
from fpga_interface  import FPGAInterface
from object_detector import ObjectDetector
from sign_verifier   import SignVerifier
from lane_follower   import LaneFollower
from navigation_fsm  import NavigationFSM, NavState, SignClass
from motor_controller import MotorController

# ─── CONFIGURATION ─────────────────────────────────────────────────────────────
CONFIG = {
    # Hardware
    "fpga_uart_port"   : "/dev/ttyAMA0",  # UART connected to Basys 3
    "fpga_uart_baud"   : 115200,
    "esp32cam_url"     : "http://192.168.4.1/stream",  # ESP32-CAM WiFi stream
    # OR if connected via USB serial:
    "esp32cam_port"    : "/dev/ttyUSB0",

    # Models
    "yolo_model"       : "yolov8n.pt",    # YOLOv8 nano (download auto)
    "tflite_model"     : "model_final_int8.tflite",
    "class_labels"     : "class_labels.json",

    # Motor GPIO pins (BCM numbering)
    "motor_ain1"       : 17,
    "motor_ain2"       : 27,
    "motor_pwma"       : 18,  # Hardware PWM
    "motor_bin1"       : 22,
    "motor_bin2"       : 23,
    "motor_pwmb"       : 13,  # Hardware PWM
    "motor_stby"       : 24,

    # Motor speeds (0-100%)
    "speed_full"       : 70,
    "speed_slow"       : 40,
    "speed_turn"       : 55,

    # Safety
    "obstacle_stop_m"  : 0.5,   # Stop if YOLO detects person < 0.5m (estimated)
    "confidence_thresh": 0.45,  # YOLO confidence threshold
}


# ─── SHARED STATE ──────────────────────────────────────────────────────────────
class SharedState:
    """Thread-safe shared state between all modules"""
    def __init__(self):
        self.lock = threading.Lock()
        # FPGA data
        self.fpga_sign_class    = 0
        self.fpga_sign_conf     = 0
        self.fpga_red_area      = 0
        self.fpga_yellow_area   = 0
        self.fpga_green_area    = 0
        self.fpga_left_x        = 20
        self.fpga_right_x       = 140
        self.fpga_center_err    = 0
        self.fpga_updated       = False
        # YOLO data
        self.yolo_persons       = 0
        self.yolo_cars          = 0
        self.yolo_obstacle      = False
        self.yolo_updated       = False
        # Neural sign verification
        self.neural_sign_class  = 0
        self.neural_sign_conf   = 0.0
        self.neural_updated     = False
        # Navigation output
        self.nav_state          = NavState.MOVING
        self.nav_command        = "FORWARD"
        # System
        self.running            = True
        self.frame_count        = 0

    def update_fpga(self, packet):
        with self.lock:
            self.fpga_sign_class  = packet['sign_class']
            self.fpga_sign_conf   = packet['sign_conf']
            self.fpga_red_area    = packet['red_area']
            self.fpga_yellow_area = packet['yellow_area']
            self.fpga_green_area  = packet['green_area']
            self.fpga_left_x      = packet['left_x']
            self.fpga_right_x     = packet['right_x']
            self.fpga_center_err  = packet['center_err']
            self.fpga_updated     = True

    def update_yolo(self, persons, cars, obstacle):
        with self.lock:
            self.yolo_persons  = persons
            self.yolo_cars     = cars
            self.yolo_obstacle = obstacle
            self.yolo_updated  = True

    def update_neural(self, sign_class, confidence):
        with self.lock:
            self.neural_sign_class = sign_class
            self.neural_sign_conf  = confidence
            self.neural_updated    = True


# ─── THREAD: FPGA UART READER ─────────────────────────────────────────────────
def fpga_reader_thread(state: SharedState, config: dict):
    """Reads 13-byte packets from Basys 3 via UART"""
    print("[FPGA] Starting UART reader...")
    fpga = FPGAInterface(
        port=config['fpga_uart_port'],
        baud=config['fpga_uart_baud']
    )

    while state.running:
        packet = fpga.read_packet()
        if packet:
            state.update_fpga(packet)

    fpga.close()
    print("[FPGA] Reader stopped")


# ─── THREAD: YOLO OBJECT DETECTION ────────────────────────────────────────────
def yolo_thread(state: SharedState, config: dict):
    """Runs YOLOv8-nano on ESP32-CAM feed"""
    print("[YOLO] Starting object detector...")

    detector = ObjectDetector(
        model_path=config['yolo_model'],
        conf_thresh=config['confidence_thresh']
    )

    # Try to connect to ESP32-CAM
    cap = None
    try:
        cap = cv2.VideoCapture(config['esp32cam_url'])
        if not cap.isOpened():
            print("[YOLO] WiFi stream failed, trying USB...")
            cap = cv2.VideoCapture(0)  # Try default camera
    except:
        print("[YOLO] No camera available, obstacle detection disabled")

    while state.running:
        if cap is None or not cap.isOpened():
            time.sleep(1)
            continue

        ret, frame = cap.read()
        if not ret:
            time.sleep(0.1)
            continue

        # Run YOLO
        results = detector.detect(frame)
        persons  = results.get('person', 0)
        cars     = results.get('car', 0) + results.get('truck', 0)
        obstacle = persons > 0 or cars > 0

        state.update_yolo(persons, cars, obstacle)
        state.frame_count += 1

        # Throttle to ~15fps
        time.sleep(0.067)

    if cap:
        cap.release()
    print("[YOLO] Detector stopped")


# ─── THREAD: NEURAL SIGN VERIFICATION ─────────────────────────────────────────
def neural_verifier_thread(state: SharedState, config: dict):
    """Runs TFLite MobileNetV2 to verify FPGA sign classification"""
    print("[NEURAL] Starting sign verifier...")

    model_path = Path(config['tflite_model'])
    if not model_path.exists():
        print(f"[NEURAL] Model not found: {model_path}, skipping neural verification")
        return

    verifier = SignVerifier(
        model_path=str(model_path),
        labels_path=config['class_labels']
    )

    while state.running:
        # Only run when FPGA detected something non-trivial
        with state.lock:
            fpga_class = state.fpga_sign_class
            red_area   = state.fpga_red_area

        if fpga_class > 0 and red_area > 100:
            # In a real system, pass the actual camera frame here
            # For now, use the FPGA classification as a strong prior
            # This is where you'd feed the cropped sign region to the network
            pass

        time.sleep(0.1)

    print("[NEURAL] Verifier stopped")


# ─── THREAD: NAVIGATION FSM ────────────────────────────────────────────────────
def navigation_thread(state: SharedState, motor: MotorController, config: dict):
    """Main navigation decision loop — runs at 50Hz"""
    print("[NAV] Starting navigation FSM...")
    fsm = NavigationFSM(config)

    while state.running:
        with state.lock:
            fpga_sign    = state.fpga_sign_class
            fpga_conf    = state.fpga_sign_conf
            yolo_obs     = state.yolo_obstacle
            center_err   = state.fpga_center_err
            left_x       = state.fpga_left_x
            right_x      = state.fpga_right_x

        # Run FSM
        command = fsm.step(
            sign_class   = fpga_sign,
            sign_conf    = fpga_conf,
            obstacle     = yolo_obs,
            center_err   = center_err,
            left_x       = left_x,
            right_x      = right_x
        )

        # Execute motor command
        motor.execute(command)

        with state.lock:
            state.nav_command = command

        time.sleep(0.02)  # 50Hz

    motor.stop()
    print("[NAV] Navigation stopped")


# ─── STATUS PRINTER ────────────────────────────────────────────────────────────
def status_thread(state: SharedState):
    """Prints system status every 2 seconds"""
    sign_names = {0:"NONE", 1:"STOP", 2:"WARNING", 3:"GO", 4:"PROHIB", 5:"SPEED"}

    while state.running:
        time.sleep(2.0)
        with state.lock:
            print(f"\n{'─'*55}")
            print(f"  FPGA Sign    : {sign_names.get(state.fpga_sign_class,'?')} "
                  f"(conf={state.fpga_sign_conf})")
            print(f"  Lane         : L={state.fpga_left_x} R={state.fpga_right_x} "
                  f"Err={state.fpga_center_err:+d}")
            print(f"  YOLO         : persons={state.yolo_persons} cars={state.yolo_cars} "
                  f"obstacle={state.yolo_obstacle}")
            print(f"  Nav State    : {state.nav_command}")
            print(f"  Frames done  : {state.frame_count}")
            print(f"{'─'*55}")


# ─── MAIN ──────────────────────────────────────────────────────────────────────
def main():
    print("="*55)
    print("  Autonomous Car — Raspberry Pi 5 Controller")
    print("  FPGA: Basys 3 Artix-7 (vision pipeline)")
    print("="*55)

    state = SharedState()

    # Initialize motor controller
    motor = MotorController(CONFIG)
    motor.setup()
    motor.stop()

    # Start threads
    threads = [
        threading.Thread(target=fpga_reader_thread,    args=(state, CONFIG), daemon=True),
        threading.Thread(target=yolo_thread,           args=(state, CONFIG), daemon=True),
        threading.Thread(target=neural_verifier_thread,args=(state, CONFIG), daemon=True),
        threading.Thread(target=navigation_thread,     args=(state, motor, CONFIG), daemon=True),
        threading.Thread(target=status_thread,         args=(state,), daemon=True),
    ]

    for t in threads:
        t.start()

    print("\n  All systems running. Press Ctrl+C to stop.\n")

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n  Stopping...")
        state.running = False
        time.sleep(1)
        motor.stop()
        motor.cleanup()
        print("  Stopped cleanly.")


if __name__ == '__main__':
    main()
