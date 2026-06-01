"""
retrain_phase2_fixed.py
========================
Fixes the BatchNorm save/load bug from the previous run.

Root cause:
  When base_model.trainable = True, BatchNorm layers use LIVE batch statistics.
  On save + reload, they revert to ImageNet statistics → accuracy collapses to 32%.

Fix:
  During fine-tuning, freeze ALL BatchNormalization layers explicitly.
  Only unfreeze Conv layers. This way saved model uses correct stored statistics.

Starts from best_phase1.h5 (already saved, no need to redo phase 1).
Runtime: ~40-50 minutes.

Run:
    python retrain_phase2_fixed.py
"""

import os
import json
import math
import numpy as np
import tensorflow as tf
from tensorflow.keras.applications.mobilenet_v2 import preprocess_input
from tensorflow.keras.preprocessing.image import ImageDataGenerator
from tensorflow.keras.callbacks import EarlyStopping, ModelCheckpoint, LearningRateScheduler

# ─── CONFIG ───────────────────────────────────────────────────────────────────
PHASE1_MODEL = './model_output/best_phase1.h5'
DATA_DIR     = './GTSRB/Train'
OUTPUT_DIR   = './model_output'
IMG_SIZE     = 96
NUM_CLASSES  = 43
BATCH_SIZE   = 32
EPOCHS_FINE  = 20       # More epochs this time

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
# ──────────────────────────────────────────────────────────────────────────────

os.makedirs(OUTPUT_DIR, exist_ok=True)

print("="*60)
print("  Phase 2 Retrain — BatchNorm Fix")
print("="*60)

# ─── CHECK PHASE 1 MODEL EXISTS ───────────────────────────────────────────────
if not os.path.exists(PHASE1_MODEL):
    print(f"\n  ERROR: {PHASE1_MODEL} not found!")
    print("  Options:")
    print("  1. Check if best_phase1.h5 exists in model_output/")
    print("  2. If only best_final.h5 exists, change PHASE1_MODEL above")
    exit(1)

# ─── DATA PIPELINE ────────────────────────────────────────────────────────────
print("\n  Loading data pipeline...")

datagen = ImageDataGenerator(
    preprocessing_function=preprocess_input,
    validation_split=0.2
)

train_gen = datagen.flow_from_directory(
    DATA_DIR,
    target_size=(IMG_SIZE, IMG_SIZE),
    batch_size=BATCH_SIZE,
    class_mode='categorical',
    subset='training',
    shuffle=True,
    seed=42
)

val_gen = datagen.flow_from_directory(
    DATA_DIR,
    target_size=(IMG_SIZE, IMG_SIZE),
    batch_size=BATCH_SIZE,
    class_mode='categorical',
    subset='validation',
    shuffle=False,
    seed=42
)

print(f"  Train: {train_gen.samples} | Val: {val_gen.samples}")

# ─── LOAD PHASE 1 MODEL ───────────────────────────────────────────────────────
print(f"\n  Loading phase 1 model: {PHASE1_MODEL}")
model = tf.keras.models.load_model(PHASE1_MODEL)

# Quick check on phase 1 accuracy
print("  Verifying phase 1 model...")
val_gen.reset()
correct = 0; total = 0
for imgs, labels in val_gen:
    preds = model.predict(imgs, verbose=0)
    correct += np.sum(np.argmax(preds,1) == np.argmax(labels,1))
    total   += len(imgs)
    if total >= 300: break

p1_acc = correct / total
print(f"  Phase 1 val accuracy (300 samples): {p1_acc*100:.1f}%")

# ─── PHASE 2: FINE-TUNE WITH BATCHNORM FROZEN ─────────────────────────────────
print(f"\n{'─'*60}")
print("  PHASE 2: Fine-tuning (Conv layers only, BN frozen)")
print(f"{'─'*60}")

# Find the base model inside the loaded model
base_model = None
for layer in model.layers:
    if 'mobilenetv2' in layer.name.lower():
        base_model = layer
        break

if base_model is None:
    # Try getting it directly if model structure differs
    print("  Searching for base model layers...")
    base_model = model

# THE FIX: Unfreeze Conv layers, keep BatchNorm FROZEN
total_layers = len(base_model.layers)
freeze_until = total_layers - 40   # Unfreeze last 40 layers
unfrozen_conv = 0
frozen_bn     = 0

for i, layer in enumerate(base_model.layers):
    is_bn   = isinstance(layer, tf.keras.layers.BatchNormalization)
    is_late = (i >= freeze_until)

    if is_bn:
        layer.trainable = False   # ALWAYS freeze BatchNorm
        frozen_bn += 1
    elif is_late:
        layer.trainable = True    # Unfreeze late Conv layers
        unfrozen_conv += 1
    else:
        layer.trainable = False   # Freeze early layers

print(f"  Total base layers    : {total_layers}")
print(f"  Unfrozen Conv layers : {unfrozen_conv}")
print(f"  Frozen BN layers     : {frozen_bn}  ← Key fix")

# Also freeze BN in the head
for layer in model.layers:
    if isinstance(layer, tf.keras.layers.BatchNormalization):
        layer.trainable = False

trainable = sum(l.trainable for l in model.layers)
print(f"  Trainable layers     : {trainable}")

# Recompile with low learning rate
model.compile(
    optimizer=tf.keras.optimizers.Adam(learning_rate=1e-4),
    loss='categorical_crossentropy',
    metrics=['accuracy', tf.keras.metrics.TopKCategoricalAccuracy(k=3, name='top3')]
)

# LR schedule
def cosine_lr(epoch, lr):
    lr_min = 1e-6
    lr_max = 1e-4
    return lr_min + 0.5*(lr_max - lr_min)*(1 + math.cos(math.pi * epoch / EPOCHS_FINE))

# Save in .keras format (avoids the .h5 BatchNorm bug entirely)
best_model_path = os.path.join(OUTPUT_DIR, 'best_model_fixed.keras')

callbacks = [
    EarlyStopping(
        monitor='val_accuracy',
        patience=5,
        restore_best_weights=True,
        verbose=1
    ),
    ModelCheckpoint(
        best_model_path,
        monitor='val_accuracy',
        save_best_only=True,
        verbose=1
    ),
    LearningRateScheduler(cosine_lr, verbose=0)
]

print(f"\n  Training for up to {EPOCHS_FINE} epochs...")
print(f"  Saving best model to: {best_model_path}")
print()

history = model.fit(
    train_gen,
    validation_data=val_gen,
    epochs=EPOCHS_FINE,
    callbacks=callbacks,
    verbose=1
)

best_acc = max(history.history['val_accuracy'])
print(f"\n  Best val accuracy: {best_acc*100:.1f}%")

# ─── RELOAD AND VERIFY ────────────────────────────────────────────────────────
print(f"\n{'─'*60}")
print("  Reloading saved model and verifying...")
print(f"{'─'*60}")

model_saved = tf.keras.models.load_model(best_model_path)

val_gen.reset()
correct = 0; total = 0
for imgs, labels in val_gen:
    preds   = model_saved.predict(imgs, verbose=0)
    correct += np.sum(np.argmax(preds,1) == np.argmax(labels,1))
    total   += len(imgs)
    if total >= 500: break

reloaded_acc = correct / total
print(f"  Reloaded model accuracy (500 samples): {reloaded_acc*100:.1f}%")

gap = abs(best_acc - reloaded_acc)
if gap < 0.05:
    print(f"  ✓ Save/load gap: {gap*100:.1f}% — BatchNorm bug is FIXED")
else:
    print(f"  ⚠ Save/load gap: {gap*100:.1f}% — still some difference")

# ─── TFLITE CONVERSION ────────────────────────────────────────────────────────
print(f"\n{'─'*60}")
print("  Converting to TFLite...")
print(f"{'─'*60}")

# Export to SavedModel (most reliable TFLite conversion path)
saved_path = os.path.join(OUTPUT_DIR, 'saved_model_fixed')
model_saved.export(saved_path)

# Float16
print("  Float16 conversion...")
conv = tf.lite.TFLiteConverter.from_saved_model(saved_path)
conv.optimizations = [tf.lite.Optimize.DEFAULT]
conv.target_spec.supported_types = [tf.float16]
tflite_f16 = conv.convert()
path_f16 = os.path.join(OUTPUT_DIR, 'model_final_f16.tflite')
with open(path_f16, 'wb') as f:
    f.write(tflite_f16)
print(f"  ✓ Float16: {len(tflite_f16)//1024} KB → {path_f16}")

# Int8
print("  Int8 conversion...")
def rep_data():
    val_gen.reset()
    count = 0
    for imgs, _ in val_gen:
        for img in imgs:
            if count >= 200: return
            yield [np.expand_dims(img,0).astype(np.float32)]
            count += 1

conv8 = tf.lite.TFLiteConverter.from_saved_model(saved_path)
conv8.optimizations = [tf.lite.Optimize.DEFAULT]
conv8.representative_dataset = rep_data
conv8.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8,
                                    tf.lite.OpsSet.SELECT_TF_OPS]
conv8.inference_input_type  = tf.float32
conv8.inference_output_type = tf.float32
tflite_i8 = conv8.convert()
path_i8 = os.path.join(OUTPUT_DIR, 'model_final_int8.tflite')
with open(path_i8, 'wb') as f:
    f.write(tflite_i8)
print(f"  ✓ Int8: {len(tflite_i8)//1024} KB → {path_i8}")

# ─── VERIFY TFLITE ────────────────────────────────────────────────────────────
print(f"\n{'─'*60}")
print("  Verifying TFLite models...")
print(f"{'─'*60}")

def eval_tflite(path, gen, n=300):
    interp = tf.lite.Interpreter(model_path=path)
    interp.allocate_tensors()
    inp = interp.get_input_details()[0]
    out = interp.get_output_details()[0]
    gen.reset()
    correct = 0; total = 0
    for imgs, labels in gen:
        for i in range(len(imgs)):
            img = np.expand_dims(imgs[i], 0).astype(np.float32)
            interp.set_tensor(inp['index'], img)
            interp.invoke()
            pred = np.argmax(interp.get_tensor(out['index'])[0])
            if pred == np.argmax(labels[i]): correct += 1
            total += 1
            if total >= n: break
        if total >= n: break
    return correct / total

acc_f16 = eval_tflite(path_f16, val_gen)
acc_i8  = eval_tflite(path_i8,  val_gen)
print(f"  Float16 TFLite accuracy: {acc_f16*100:.1f}%")
print(f"  Int8    TFLite accuracy: {acc_i8*100:.1f}%")

# Spot check
print("\n  Spot check (10 samples):")
val_gen.reset()
batch_imgs, batch_labels = next(iter(val_gen))
interp = tf.lite.Interpreter(model_path=path_f16)
interp.allocate_tensors()
inp_d = interp.get_input_details()[0]
out_d = interp.get_output_details()[0]
correct = 0
for i in range(10):
    img = np.expand_dims(batch_imgs[i], 0).astype(np.float32)
    interp.set_tensor(inp_d['index'], img)
    interp.invoke()
    pred = np.argmax(interp.get_tensor(out_d['index'])[0])
    true = np.argmax(batch_labels[i])
    ok = "✓" if pred == true else "✗"
    if pred == true: correct += 1
    print(f"  {ok} pred={CLASS_LABELS.get(pred,'?'):<18} true={CLASS_LABELS.get(true,'?')}")
print(f"  Spot check: {correct}/10")

# ─── SAVE INFO ────────────────────────────────────────────────────────────────
info = {
    "phase1_accuracy"  : round(p1_acc * 100, 1),
    "phase2_accuracy"  : round(best_acc * 100, 1),
    "reloaded_accuracy": round(reloaded_acc * 100, 1),
    "tflite_f16_acc"   : round(acc_f16 * 100, 1),
    "tflite_int8_acc"  : round(acc_i8  * 100, 1),
    "float16_kb"       : len(tflite_f16) // 1024,
    "int8_kb"          : len(tflite_i8)  // 1024,
    "img_size"         : IMG_SIZE,
    "num_classes"      : NUM_CLASSES,
    "preprocessing"    : {
        "formula" : "pixel = (raw / 127.5) - 1.0",
        "range"   : "[-1.0, 1.0]",
        "esp32"   : "float p = ((float)raw_pixel / 127.5f) - 1.0f;"
    },
    "use_on_esp32_s3"  : "model_final_f16.tflite",
    "use_on_esp32_cam" : "model_final_int8.tflite"
}
with open(os.path.join(OUTPUT_DIR, 'model_info.json'), 'w') as f:
    json.dump(info, f, indent=2)
with open(os.path.join(OUTPUT_DIR, 'class_labels.json'), 'w') as f:
    json.dump(CLASS_LABELS, f, indent=2)

# ─── FINAL SUMMARY ────────────────────────────────────────────────────────────
print(f"\n{'='*60}")
print("  DONE")
print(f"{'='*60}")
print(f"  Phase 1 accuracy      : {p1_acc*100:.1f}%")
print(f"  Phase 2 accuracy      : {best_acc*100:.1f}%")
print(f"  Reloaded (save test)  : {reloaded_acc*100:.1f}%  ← should match phase 2")
print(f"  TFLite Float16        : {acc_f16*100:.1f}%  ({len(tflite_f16)//1024} KB)")
print(f"  TFLite Int8           : {acc_i8*100:.1f}%  ({len(tflite_i8)//1024} KB)")
print(f"{'='*60}")
print(f"\n  Use on ESP32-S3  : model_final_f16.tflite")
print(f"  Use on ESP32-CAM : model_final_int8.tflite")
