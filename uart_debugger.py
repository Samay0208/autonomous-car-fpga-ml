import serial
import struct
import time
import argparse

def main():
    parser = argparse.ArgumentParser(description="Read UART packets from Basys 3 FPGA")
    parser.add_argument('--port', type=str, required=True, help="Serial port (e.g., COM3 on Windows, /dev/ttyUSB0 or /dev/serial0 on RPi)")
    parser.add_argument('--baud', type=int, default=115200, help="Baud rate (default: 115200)")
    args = parser.parse_args()

    try:
        ser = serial.Serial(args.port, args.baud, timeout=1)
        print(f"Listening on {args.port} at {args.baud} baud...")
    except Exception as e:
        print(f"Error opening serial port: {e}")
        return

    # Buffer to hold incoming bytes
    buffer = bytearray()

    while True:
        if ser.in_waiting > 0:
            buffer.extend(ser.read(ser.in_waiting))
        
        # Look for the start marker (0xAA) and end marker (0x55) in 13-byte packet
        while len(buffer) >= 13:
            if buffer[0] == 0xAA and buffer[12] == 0x55:
                # We have a valid packet!
                packet = buffer[:13]
                buffer = buffer[13:] # remove from buffer
                
                # Parse the packet
                sign_class_raw = packet[1]
                sign_conf = packet[2]
                red_area = (packet[3] << 8) | packet[4]
                yel_area = (packet[5] << 8) | packet[6]
                grn_area = (packet[7] << 8) | packet[8]
                lane_left = packet[9]
                lane_right = packet[10]
                steer_err_raw = packet[11]
                
                # Convert signed 8-bit steering error
                steer_err = steer_err_raw if steer_err_raw < 128 else steer_err_raw - 256
                
                sign_classes = {0: "NONE", 1: "STOP", 2: "WARNING", 3: "GO", 4: "PROHIBITION"}
                detected_sign = sign_classes.get(sign_class_raw, "UNKNOWN")
                
                print(f"--- FRAME ---")
                print(f"Sign: {detected_sign} (Conf: {sign_conf}/255)")
                print(f"Blobs: Red Area={red_area}, Yellow Area={yel_area}, Green Area={grn_area}")
                print(f"Lane: Left={lane_left}, Right={lane_right} | Steering Err: {steer_err}")
                print("")
                
            else:
                # If first byte isn't start marker, shift by 1 and try again
                buffer.pop(0)
                
        time.sleep(0.01)

if __name__ == "__main__":
    main()
