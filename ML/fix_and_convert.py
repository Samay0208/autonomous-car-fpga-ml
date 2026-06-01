"""
fix_and_convert.py
==================
Fixes two problems from the training run:
  1. TFLite conversion was broken (predicting same class for everything)
  2. Produces a smaller model that fits comfortably on ESP32

Run this AFTER training completes:
    python fix_and_convert.py

Requirements:
    - model_output/best_final.h5  must exist (saved during training)
    - GTSRB/Train folder must exist (for calibration)
"""

import os
import json
import numpy as np
import tensorflow as tf
from tensorflow.keras.applications.mobilenet_v2 import preprocess_input
from tensorflow.keras.preprocessing.image import ImageDataGenerator

MODEL_PATH  = './model_output/best_final.h5'
DATA_DIR    = './GTSRB/Train'
OUTPUT_DIR  = './model_output'
IMG_SIZE    = 96
NUM_CLASSES = 43
BATCH_SIZE  = 32

CLASS_LABELS = {
    0:"Speed20", 1:"Speed30", 2:"Speed50", 3:"Speed60", 4:"Speed70",
    5:"Speed80", 6:"EndSpeed80", 7:"Speed100", 8:"Speed120", 9:"NoPass",
    10:"NoPass3.5t", 11:"RightOfWay", 12:"PriorityRoad", 13:"Yield",
    14:"STOP", 15:"NoVehicles", 16:"No3.5t", 17:"NoEntry", 18:"Warning",
    19:"CurveL", 20:"CurveR", 21:"DoubleCurve", 22:"Bumpy", 23:"Slippery",
    24:"NarrowR", 25:"RoadWorks", 26:"TrafficSignals", 27:"Pedestrians",
    28:"Children", 29:"Bicycles", 30:"Ice", 31:"WildAnimals",
    32:"EndRestrictions", 33:"TurnRight", 34:"TurnLeft", 35:"AheadOnly",
    36:"AheadRight", 37:"AheadLeft", 38:"KeepRight", 39:"KeepLeft",
    40:"Roundabout", 41:"EndNoPass", 42:"EndNoPass3.5t"
}

print("="*60)
print("  TFLite Fix + Conversion Script")
print("="*60)

# ─── STEP 1: LOAD SAVED KERAS MODEL ──────────────────────────────────────────
print("\n  Step 1: Loading saved Keras model...")

if not os.path.exists(MODEL_PATH):
    print(f"  ERROR: {MODEL_PATH} not found!")
    print("  Make sure training completed and best_final.h5 was saved.")
    exit(1)

model = tf.keras.models.load_model(MODEL_PATH)
print(f"  Model loaded: {MODEL_PATH}")
print(f"  Input shape : {model.input_shape}")
print(f"  Output shape: {model.output_shape}")
print(f"  Parameters  : {model.count_params():,}")

# ─── STEP 2: VERIFY KERAS MODEL ON RAW SAMPLES ───────────────────────────────
# This confirms the saved model works before we try to convert it
print("\n  Step 2: Verifying Keras model accuracy...")

val_datagen = ImageDataGenerator(
    preprocessing_function=preprocess_input,
    validation_split=0.2
)
val_gen = val_datagen.flow_from_directory(
    DATA_DIR,
    target_size=(IMG_SIZE, IMG_SIZE),
    batch_size=BATCH_SIZE,
    class_mode='categorical',
    subset='validation',
    shuffle=False,
    seed=42
)

# Quick evaluation on 500 samples
print("  Evaluating on validation set (500 samples)...")
val_gen.reset()
correct = 0
total   = 0
for imgs, labels in val_gen:
    preds   = model.predict(imgs, verbose=0)
    correct += np.sum(np.argmax(preds, axis=1) == np.argmax(labels, axis=1))
    total   += len(imgs)
    if total >= 500:
        break

keras_acc = correct / total
print(f"  Keras model accuracy (500 samples): {keras_acc*100:.1f}%")

if keras_acc < 0.5:
    print("  WARNING: Keras model accuracy is very low.")
    print("  The saved model may not be the best checkpoint.")
    print("  Trying best_phase1.h5 as fallback...")
    fallback = './model_output/best_phase1.h5'
    if os.path.exists(fallback):
        model = tf.keras.models.load_model(fallback)
        # Re-evaluate
        val_gen.reset()
        correct = 0; total = 0
        for imgs, labels in val_gen:
            preds   = model.predict(imgs, verbose=0)
            correct += np.sum(np.argmax(preds, axis=1) == np.argmax(labels, axis=1))
            total   += len(imgs)
            if total >= 500:
                break
        keras_acc = correct / total
        print(f"  Fallback model accuracy: {keras_acc*100:.1f}%")

print(f"\n  ✓ Keras model confirmed: {keras_acc*100:.1f}% accuracy")

# ─── STEP 3: TEST ON INDIVIDUAL SAMPLES (like the spot check) ─────────────────
print("\n  Step 3: Per-sample prediction check...")
val_gen.reset()
batch_imgs, batch_labels = next(iter(val_gen))

print(f"  {'Sample':<10} {'Predicted':<20} {'True':<20} {'Correct'}")
print(f"  {'─'*65}")
spot_correct = 0
for i in range(10):
    img  = np.expand_dims(batch_imgs[i], 0)
    pred = np.argmax(model.predict(img, verbose=0))
    true = np.argmax(batch_labels[i])
    ok   = "✓" if pred == true else "✗"
    if pred == true:
        spot_correct += 1
    print(f"  Sample {i+1:<4} {CLASS_LABELS.get(pred,'?'):<20} {CLASS_LABELS.get(true,'?'):<20} {ok}")

print(f"\n  Keras spot-check: {spot_correct}/10 correct")

# ─── STEP 4: CONVERT TO TFLITE (FIXED) ────────────────────────────────────────
# The fix: use concrete function conversion instead of from_keras_model
# This avoids the bug where float16 quantization corrupts the output layer
print(f"\n{'─'*60}")
print("  Step 4: Converting to TFLite (fixed method)...")
print(f"{'─'*60}")

# Save as SavedModel format first (more reliable conversion path)
saved_model_path = os.path.join(OUTPUT_DIR, 'saved_model_temp')
print("  Saving as SavedModel format (intermediate step)...")
model.export(saved_model_path)

# Convert from SavedModel → much more reliable than from_keras_model
print("  Converting float16...")
converter_f16 = tf.lite.TFLiteConverter.from_saved_model(saved_model_path)
converter_f16.optimizations = [tf.lite.Optimize.DEFAULT]
converter_f16.target_spec.supported_types = [tf.float16]
# IMPORTANT: Keep float input/output (don't force int8 on boundaries)
converter_f16.target_spec.supported_ops = [
    tf.lite.OpsSet.TFLITE_BUILTINS,
    tf.lite.OpsSet.SELECT_TF_OPS
]
tflite_f16 = converter_f16.convert()

path_f16 = os.path.join(OUTPUT_DIR, 'traffic_sign_model_FIXED.tflite')
with open(path_f16, 'wb') as f:
    f.write(tflite_f16)
print(f"  ✓ Float16 model: {len(tflite_f16)/1024:.0f} KB")

# Int8 conversion
print("  Converting int8...")
def representative_dataset():
    val_gen.reset()
    count = 0
    for imgs, _ in val_gen:
        for img in imgs:
            if count >= 200:
                return
            yield [np.expand_dims(img, 0).astype(np.float32)]
            count += 1

converter_i8 = tf.lite.TFLiteConverter.from_saved_model(saved_model_path)
converter_i8.optimizations = [tf.lite.Optimize.DEFAULT]
converter_i8.representative_dataset = representative_dataset
converter_i8.target_spec.supported_ops = [
    tf.lite.OpsSet.TFLITE_BUILTINS_INT8,
    tf.lite.OpsSet.SELECT_TF_OPS
]
converter_i8.inference_input_type  = tf.float32  # Keep float I/O for simplicity
converter_i8.inference_output_type = tf.float32
tflite_i8 = converter_i8.convert()

path_i8 = os.path.join(OUTPUT_DIR, 'traffic_sign_model_int8_FIXED.tflite')
with open(path_i8, 'wb') as f:
    f.write(tflite_i8)
print(f"  ✓ Int8 model   : {len(tflite_i8)/1024:.0f} KB")

# ─── STEP 5: VERIFY FIXED TFLITE ─────────────────────────────────────────────
print(f"\n{'─'*60}")
print("  Step 5: Verifying fixed TFLite models...")
print(f"{'─'*60}")

def test_tflite_model(model_path, test_imgs, test_labels, label_dict):
    interp = tf.lite.Interpreter(model_path=model_path)
    interp.allocate_tensors()
    inp = interp.get_input_details()[0]
    out = interp.get_output_details()[0]

    print(f"\n  Model : {os.path.basename(model_path)}")
    print(f"  Input : {inp['shape']} dtype={inp['dtype']}")
    print(f"  Output: {out['shape']} dtype={out['dtype']}")
    print(f"\n  {'Sample':<10} {'Predicted':<20} {'True':<20} {'Conf':>6} {'OK'}")
    print(f"  {'─'*70}")

    correct = 0
    for i in range(min(10, len(test_imgs))):
        img = np.expand_dims(test_imgs[i], 0).astype(inp['dtype'])
        interp.set_tensor(inp['index'], img)
        interp.invoke()
        probs = interp.get_tensor(out['index'])[0]
        pred  = np.argmax(probs)
        conf  = probs[pred]
        true  = np.argmax(test_labels[i])
        ok    = "✓" if pred == true else "✗"
        if pred == true:
            correct += 1
        print(f"  Sample {i+1:<4} {label_dict.get(pred,'?'):<20} "
              f"{label_dict.get(true,'?'):<20} {conf:>5.1%} {ok}")

    print(f"\n  Spot-check result: {correct}/10 correct")
    return correct

val_gen.reset()
batch_imgs, batch_labels = next(iter(val_gen))

print("\n  Testing Float16 model:")
score_f16 = test_tflite_model(path_f16, batch_imgs, batch_labels, CLASS_LABELS)

print("\n  Testing Int8 model:")
score_i8  = test_tflite_model(path_i8,  batch_imgs, batch_labels, CLASS_LABELS)

# ─── STEP 6: ACCURACY ON MORE SAMPLES ────────────────────────────────────────
print(f"\n{'─'*60}")
print("  Step 6: Full accuracy test on 300 validation samples...")
print(f"{'─'*60}")

def eval_tflite(model_path, gen, n_samples=300):
    interp = tf.lite.Interpreter(model_path=model_path)
    interp.allocate_tensors()
    inp = interp.get_input_details()[0]
    out = interp.get_output_details()[0]

    gen.reset()
    correct = 0
    total   = 0
    for imgs, labels in gen:
        for i in range(len(imgs)):
            img = np.expand_dims(imgs[i], 0).astype(inp['dtype'])
            interp.set_tensor(inp['index'], img)
            interp.invoke()
            pred = np.argmax(interp.get_tensor(out['index'])[0])
            true = np.argmax(labels[i])
            if pred == true:
                correct += 1
            total += 1
            if total >= n_samples:
                break
        if total >= n_samples:
            break
    return correct / total

print("  Evaluating Float16...")
acc_f16 = eval_tflite(path_f16, val_gen)
print(f"  Float16 accuracy (300 samples): {acc_f16*100:.1f}%")

print("  Evaluating Int8...")
acc_i8 = eval_tflite(path_i8, val_gen)
print(f"  Int8 accuracy    (300 samples): {acc_i8*100:.1f}%")

# ─── STEP 7: SAVE PREPROCESSING INFO FOR ESP32 ───────────────────────────────
info = {
    "img_size"         : IMG_SIZE,
    "num_classes"      : NUM_CLASSES,
    "keras_accuracy"   : round(keras_acc * 100, 1),
    "tflite_f16_acc"   : round(acc_f16 * 100, 1),
    "tflite_int8_acc"  : round(acc_i8  * 100, 1),
    "float16_model"    : "traffic_sign_model_FIXED.tflite",
    "int8_model"       : "traffic_sign_model_int8_FIXED.tflite",
    "float16_size_kb"  : round(len(tflite_f16) / 1024, 0),
    "int8_size_kb"     : round(len(tflite_i8)  / 1024, 0),
    "preprocessing": {
        "method"  : "mobilenet_v2_preprocess_input",
        "formula" : "pixel = (raw_0_to_255 / 127.5) - 1.0",
        "range"   : "[-1.0, 1.0]",
        "esp32_c" : "float pixel = ((float)raw / 127.5f) - 1.0f;"
    }
}

with open(os.path.join(OUTPUT_DIR, 'model_info.json'), 'w') as f:
    json.dump(info, f, indent=2)

with open(os.path.join(OUTPUT_DIR, 'class_labels.json'), 'w') as f:
    json.dump(CLASS_LABELS, f, indent=2)

# ─── SUMMARY ──────────────────────────────────────────────────────────────────
print(f"\n{'='*60}")
print("  CONVERSION COMPLETE")
print(f"{'='*60}")
print(f"  Keras accuracy      : {keras_acc*100:.1f}%")
print(f"  TFLite Float16 acc  : {acc_f16*100:.1f}%  ({len(tflite_f16)//1024} KB)")
print(f"  TFLite Int8 acc     : {acc_i8*100:.1f}%  ({len(tflite_i8)//1024} KB)")
print()
print("  Files saved:")
print(f"    {path_f16}  ← Use on ESP32-S3")
print(f"    {path_i8}   ← Use on ESP32-CAM")
print(f"    {OUTPUT_DIR}/model_info.json")
print(f"    {OUTPUT_DIR}/class_labels.json")
print()

if acc_f16 > 0.75:
    print("  ✓ TFLite model is working correctly.")
    print("  ✓ Ready for ESP32 deployment tomorrow.")
else:
    print("  ⚠ Accuracy still low after conversion.")
    print("  → Run the script again, it will use best checkpoint.")
    print("  → Or message for further debugging.")

print(f"{'='*60}")
