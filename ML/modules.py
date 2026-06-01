#!/usr/bin/env python3
"""
fpga_interface.py
Parses 13-byte UART packets from Basys 3 FPGA

Packet format:
  0xAA  sign_class  sign_conf
  red_H red_L  yel_H yel_L  grn_H grn_L
  left_x  right_x  center_err
  0x55
"""
import serial
import struct

PACKET_LEN   = 13
START_MARKER = 0xAA
END_MARKER   = 0x55

class FPGAInterface:
    def __init__(self, port='/dev/ttyAMA0', baud=115200):
        self.ser = serial.Serial(port, baud, timeout=0.1)
        self.buf = bytearray()
        self.parsed = 0
        self.errors = 0
        print(f"[FPGA] Connected on {port} @ {baud}")

    def read_packet(self):
        if self.ser.in_waiting:
            self.buf.extend(self.ser.read(self.ser.in_waiting))

        while len(self.buf) >= PACKET_LEN:
            if self.buf[0] != START_MARKER:
                self.buf.pop(0)
                self.errors += 1
                continue
            if self.buf[PACKET_LEN-1] != END_MARKER:
                self.buf.pop(0)
                self.errors += 1
                continue

            pkt = self.buf[:PACKET_LEN]
            self.buf = self.buf[PACKET_LEN:]
            self.parsed += 1

            center_err = struct.unpack('b', bytes([pkt[11]]))[0]  # signed byte

            return {
                'sign_class'  : pkt[1],
                'sign_conf'   : pkt[2],
                'red_area'    : (pkt[3] << 8) | pkt[4],
                'yellow_area' : (pkt[5] << 8) | pkt[6],
                'green_area'  : (pkt[7] << 8) | pkt[8],
                'left_x'      : pkt[9],
                'right_x'     : pkt[10],
                'center_err'  : center_err,
            }
        return None

    def close(self):
        self.ser.close()


# ──────────────────────────────────────────────────────────────────────────────
"""
motor_controller.py
Controls TB6612FNG dual motor driver via RPi 5 GPIO
"""
import RPi.GPIO as GPIO

class MotorController:
    def __init__(self, config):
        self.cfg    = config
        self.pwm_a  = None
        self.pwm_b  = None
        self.last   = None

    def setup(self):
        GPIO.setmode(GPIO.BCM)
        GPIO.setwarnings(False)
        pins = [
            self.cfg['motor_ain1'], self.cfg['motor_ain2'],
            self.cfg['motor_ain1'], self.cfg['motor_bin1'],
            self.cfg['motor_bin2'], self.cfg['motor_stby'],
            self.cfg['motor_pwma'], self.cfg['motor_pwmb'],
        ]
        for p in [self.cfg['motor_ain1'], self.cfg['motor_ain2'],
                  self.cfg['motor_bin1'], self.cfg['motor_bin2'],
                  self.cfg['motor_stby'], self.cfg['motor_pwma'],
                  self.cfg['motor_pwmb']]:
            GPIO.setup(p, GPIO.OUT)

        GPIO.output(self.cfg['motor_stby'], GPIO.HIGH)  # Enable driver
        self.pwm_a = GPIO.PWM(self.cfg['motor_pwma'], 1000)
        self.pwm_b = GPIO.PWM(self.cfg['motor_pwmb'], 1000)
        self.pwm_a.start(0)
        self.pwm_b.start(0)
        print("[MOTOR] TB6612FNG initialized")

    def _set_motors(self, ain1, ain2, bin1, bin2, speed_a, speed_b):
        GPIO.output(self.cfg['motor_ain1'], ain1)
        GPIO.output(self.cfg['motor_ain2'], ain2)
        GPIO.output(self.cfg['motor_bin1'], bin1)
        GPIO.output(self.cfg['motor_bin2'], bin2)
        self.pwm_a.ChangeDutyCycle(speed_a)
        self.pwm_b.ChangeDutyCycle(speed_b)

    def stop(self):
        self._set_motors(0, 0, 0, 0, 0, 0)

    def forward(self, speed=None):
        s = speed or self.cfg['speed_full']
        self._set_motors(1, 0, 1, 0, s, s)

    def slow(self):
        self._set_motors(1, 0, 1, 0, self.cfg['speed_slow'], self.cfg['speed_slow'])

    def reverse(self):
        self._set_motors(0, 1, 0, 1, self.cfg['speed_slow'], self.cfg['speed_slow'])

    def turn_left(self):
        s = self.cfg['speed_turn']
        self._set_motors(0, 1, 1, 0, s, s)  # Left reverse, right forward

    def turn_right(self):
        s = self.cfg['speed_turn']
        self._set_motors(1, 0, 0, 1, s, s)  # Left forward, right reverse

    def steer(self, center_err):
        """Differential steering based on lane center error"""
        s = self.cfg['speed_full']
        err = max(-80, min(80, center_err))
        left_speed  = s + err * 0.3
        right_speed = s - err * 0.3
        left_speed  = max(20, min(100, left_speed))
        right_speed = max(20, min(100, right_speed))
        self._set_motors(1, 0, 1, 0, left_speed, right_speed)

    def execute(self, command):
        if command == self.last:
            return
        self.last = command
        print(f"[MOTOR] → {command}")
        if   command == "STOP"     : self.stop()
        elif command == "FORWARD"  : self.forward()
        elif command == "SLOW"     : self.slow()
        elif command == "REVERSE"  : self.reverse()
        elif command == "LEFT"     : self.turn_left()
        elif command == "RIGHT"    : self.turn_right()

    def cleanup(self):
        self.stop()
        if self.pwm_a: self.pwm_a.stop()
        if self.pwm_b: self.pwm_b.stop()
        GPIO.cleanup()


# ──────────────────────────────────────────────────────────────────────────────
"""
navigation_fsm.py
Navigation decision state machine — fuses all sensor inputs
"""
import time
from enum import Enum

class NavState(Enum):
    MOVING   = "Moving"
    SLOWING  = "Slowing"
    STOPPED  = "Stopped at sign"
    OBSTACLE = "Obstacle avoidance"
    RECOVERY = "Recovering"
    LANE_FIX = "Correcting lane"

class SignClass:
    NONE       = 0
    STOP       = 1
    WARNING    = 2
    GO         = 3
    PROHIBITION= 4
    SPEED_LIMIT= 5

class NavigationFSM:
    def __init__(self, config):
        self.cfg         = config
        self.state       = NavState.MOVING
        self.stop_time   = 0
        self.slow_time   = 0
        self.sign_hist   = []
        self.HIST_LEN    = 5
        self.stop_wait   = 2.0  # Seconds to wait at stop sign

    def _dominant_sign(self):
        if not self.sign_hist:
            return SignClass.NONE
        from collections import Counter
        c = Counter(self.sign_hist)
        return c.most_common(1)[0][0]

    def step(self, sign_class, sign_conf, obstacle, center_err, left_x, right_x):
        # Update sign history (only trust high-confidence detections)
        if sign_conf > 80:
            self.sign_hist.append(sign_class)
            if len(self.sign_hist) > self.HIST_LEN:
                self.sign_hist.pop(0)

        sign = self._dominant_sign()

        # ── Emergency: obstacle detected by YOLO ──────────────────────────
        if obstacle:
            if self.state != NavState.OBSTACLE:
                print(f"[NAV] OBSTACLE detected → STOP")
            self.state = NavState.OBSTACLE
            return "STOP"

        # ── State machine ─────────────────────────────────────────────────
        if self.state == NavState.MOVING:
            if sign == SignClass.STOP:
                print("[NAV] STOP sign → stopping")
                self.state = NavState.STOPPED
                self.stop_time = time.time()
                return "STOP"
            elif sign == SignClass.WARNING:
                print("[NAV] WARNING → slowing")
                self.state = NavState.SLOWING
                self.slow_time = time.time()
                return "SLOW"
            elif abs(center_err) > 20:
                # Lane correction via differential steering
                return f"STEER:{center_err}"
            return "FORWARD"

        elif self.state == NavState.SLOWING:
            elapsed = time.time() - self.slow_time
            if sign == SignClass.STOP:
                self.state = NavState.STOPPED
                self.stop_time = time.time()
                return "STOP"
            elif sign != SignClass.WARNING and elapsed > 3.0:
                print("[NAV] Warning cleared → MOVING")
                self.state = NavState.MOVING
                return "FORWARD"
            return "SLOW"

        elif self.state == NavState.STOPPED:
            elapsed = time.time() - self.stop_time
            if sign != SignClass.STOP and elapsed > self.stop_wait:
                print("[NAV] Stop cleared → MOVING")
                self.state = NavState.MOVING
                return "FORWARD"
            return "STOP"

        elif self.state == NavState.OBSTACLE:
            if not obstacle:
                print("[NAV] Obstacle cleared → MOVING")
                self.state = NavState.MOVING
                return "FORWARD"
            return "STOP"

        return "FORWARD"


# ──────────────────────────────────────────────────────────────────────────────
"""
object_detector.py
YOLOv8-nano object detection for obstacle avoidance
"""
class ObjectDetector:
    def __init__(self, model_path, conf_thresh=0.45):
        try:
            from ultralytics import YOLO
            self.model = YOLO(model_path)
            self.conf  = conf_thresh
            self.ready = True
            print(f"[YOLO] Model loaded: {model_path}")
        except Exception as e:
            print(f"[YOLO] Failed to load model: {e}")
            self.ready = False

    def detect(self, frame):
        if not self.ready:
            return {}
        results = self.model(frame, conf=self.conf, verbose=False)
        counts = {}
        for r in results:
            for box in r.boxes:
                cls_name = self.model.names[int(box.cls[0])]
                counts[cls_name] = counts.get(cls_name, 0) + 1
        return counts


# ──────────────────────────────────────────────────────────────────────────────
"""
sign_verifier.py
TFLite MobileNetV2 sign classification (neural verification of FPGA result)
"""
import numpy as np
import json

class SignVerifier:
    SIGN_MAP = {
        14: 1,   # GTSRB class 14 = STOP → our class 1
        13: 2,   # Yield → warning
        35: 3,   # Ahead only → go
        17: 4,   # No entry → prohibition
    }

    def __init__(self, model_path, labels_path=None, img_size=96):
        try:
            import tflite_runtime.interpreter as tflite
        except:
            import tensorflow.lite as tflite

        self.interpreter = tflite.Interpreter(model_path=model_path)
        self.interpreter.allocate_tensors()
        self.inp = self.interpreter.get_input_details()[0]
        self.out = self.interpreter.get_output_details()[0]
        self.img_size = img_size

        if labels_path:
            with open(labels_path) as f:
                self.labels = json.load(f)
        else:
            self.labels = {}

        print(f"[NEURAL] TFLite model loaded: {model_path}")

    def classify(self, frame_bgr):
        """Classify a sign crop. Returns (class_id, confidence)"""
        import cv2
        img = cv2.resize(frame_bgr, (self.img_size, self.img_size))
        img = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
        img = (img.astype(np.float32) / 127.5) - 1.0  # MobileNetV2 preprocessing
        img = np.expand_dims(img, 0)

        self.interpreter.set_tensor(self.inp['index'], img)
        self.interpreter.invoke()
        probs = self.interpreter.get_tensor(self.out['index'])[0]

        cls_id   = int(np.argmax(probs))
        conf     = float(probs[cls_id])
        our_cls  = self.SIGN_MAP.get(cls_id, 0)
        return our_cls, conf
