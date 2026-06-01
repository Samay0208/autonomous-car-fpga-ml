"""
continue_phase2.py
==================
Run this AFTER Windows Update reboot.
Loads the saved phase1_best.keras checkpoint and runs Phase 2 only.

Skips Phase 1 entirely — saves ~3 hours of training time.

Run:
    python continue_phase2.py
"""

import os
import json
import math
import numpy as np
import tensorflow as tf
from tensorflow.keras.applications.efficientnet import preprocess_input
from tensorflow.keras.preprocessing.image import ImageDataGenerator
from tensorflow.keras.callbacks import EarlyStopping, ModelCheckpoint, LearningRateScheduler
from sklearn.utils.class_weight import compute_class_weight

# ─── CONFIG ───────────────────────────────────────────────────────────────────
PHASE1_MODEL = './models/phase1_best.keras'   # Saved by ModelCheckpoint
DATA_DIR     = './GTSRB/Train'
OUTPUT_DIR   = './models'
IMG_SIZE     = 224
BATCH_SIZE   = 32
EPOCHS_FINE  = 20
NUM_CLASSES  = 43

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
print("  Phase 2 Continuation — Starting from Phase 1 checkpoint")
print("="*60)

# ─── CHECK CHECKPOINT ─────────────────────────────────────────────────────────
if not os.path.exists(PHASE1_MODEL):
    print(f"\n  ERROR: {PHASE1_MODEL} not found!")
    print("\n  Checking what IS in models/ folder...")
    if os.path.exists('./models'):
        files = os.listdir('./models')
        if files:
            for f in files:
                size = os.path.getsize(f'./models/{f}') // 1024
                print(f"    {f}  ({size} KB)")
        else:
            print("    models/ folder is empty")
    print("\n  Options:")
    print("  1. Use existing model: model_final_int8.tflite (87% accuracy)")
    print("  2. Retrain from scratch: python train_efficientnet_rpi5.py")
    exit(1)

print(f"\n  ✓ Found checkpoint: {PHASE1_MODEL}")
size_mb = os.path.getsize(PHASE1_MODEL) / (1024*1024)
print(f"  Checkpoint size: {size_mb:.1f} MB")

# ─── DATA ─────────────────────────────────────────────────────────────────────
print("\n  Loading data pipeline...")

datagen = ImageDataGenerator(
    preprocessing_function=preprocess_input,
    validation_split=0.2
)

train_gen = datagen.flow_from_directory(
    DATA_DIR, target_size=(IMG_SIZE, IMG_SIZE),
    batch_size=BATCH_SIZE, class_mode='categorical',
    subset='training', shuffle=True, seed=42
)

val_gen = datagen.flow_from_directory(
    DATA_DIR, target_size=(IMG_SIZE, IMG_SIZE),
    batch_size=BATCH_SIZE, class_mode='categorical',
    subset='validation', shuffle=False, seed=42
)

print(f"  Train: {train_gen.samples} | Val: {val_gen.samples}")

weights = compute_class_weight('balanced',
    classes=np.unique(train_gen.classes), y=train_gen.classes)
class_weights = dict(enumerate(weights))

# ─── LOAD PHASE 1 MODEL ───────────────────────────────────────────────────────
print(f"\n  Loading phase 1 model...")
model = tf.keras.models.load_model(PHASE1_MODEL)

# Quick accuracy check
print("  Checking phase 1 accuracy on 300 samples...")
val_gen.reset()
correct = 0; total = 0
for imgs, labels in val_gen:
    preds = model.predict(imgs, verbose=0)
    correct += np.sum(np.argmax(preds, 1) == np.argmax(labels, 1))
    total += len(imgs)
    if total >= 300: break
p1_acc = correct / total
print(f"  Phase 1 checkpoint accuracy: {p1_acc*100:.1f}%")

# ─── PHASE 2: FINE-TUNE WITH BN FROZEN ────────────────────────────────────────
print(f"\n{'─'*60}")
print("  Phase 2: Fine-tuning (Conv unfrozen, BN always frozen)")
print(f"{'─'*60}")

# Find base model
base_model = None
for layer in model.layers:
    if 'efficientnet' in layer.name.lower():
        base_model = layer
        break

if base_model is None:
    print("  Could not find EfficientNet base — using all layers")
    base_model = model

total_layers = len(base_model.layers)
frozen_bn = 0; unfrozen_conv = 0

for i, layer in enumerate(base_model.layers):
    if isinstance(layer, tf.keras.layers.BatchNormalization):
        layer.trainable = False   # CRITICAL: always freeze BN
        frozen_bn += 1
    else:
        layer.trainable = (i >= total_layers - 50)
        if layer.trainable:
            unfrozen_conv += 1

# Also freeze BN in head
for layer in model.layers:
    if isinstance(layer, tf.keras.layers.BatchNormalization):
        layer.trainable = False

print(f"  Total base layers   : {total_layers}")
print(f"  Unfrozen Conv layers: {unfrozen_conv}")
print(f"  Frozen BN layers    : {frozen_bn} ← prevents save/load bug")

def cosine_lr(epoch, lr):
    lr_min = 1e-6; lr_max = 5e-5
    return lr_min + 0.5*(lr_max-lr_min)*(1+math.cos(math.pi*epoch/EPOCHS_FINE))

model.compile(
    optimizer=tf.keras.optimizers.Adam(5e-5),
    loss='categorical_crossentropy',
    metrics=['accuracy', tf.keras.metrics.TopKCategoricalAccuracy(k=3, name='top3')]
)

best_path = os.path.join(OUTPUT_DIR, 'final_best.keras')
callbacks = [
    EarlyStopping(monitor='val_accuracy', patience=5,
                  restore_best_weights=True, verbose=1),
    ModelCheckpoint(best_path, monitor='val_accuracy',
                    save_best_only=True, verbose=1),
    LearningRateScheduler(cosine_lr, verbose=0)
]

print(f"\n  Training Phase 2 ({EPOCHS_FINE} epochs)...")
h = model.fit(
    train_gen, validation_data=val_gen,
    epochs=EPOCHS_FINE, class_weight=class_weights,
    callbacks=callbacks, verbose=1
)

best_acc = max(h.history['val_accuracy'])
print(f"\n  Phase 2 best accuracy: {best_acc*100:.1f}%")

# ─── VERIFY RELOAD ────────────────────────────────────────────────────────────
print("\n  Verifying save/reload (checking BatchNorm bug is fixed)...")
model_final = tf.keras.models.load_model(best_path)
val_gen.reset()
correct = 0; total = 0
for imgs, labels in val_gen:
    preds = model_final.predict(imgs, verbose=0)
    correct += np.sum(np.argmax(preds,1) == np.argmax(labels,1))
    total += len(imgs)
    if total >= 500: break
reload_acc = correct/total
print(f"  Reloaded accuracy: {reload_acc*100:.1f}%")
gap = abs(best_acc - reload_acc)
print(f"  Gap: {gap*100:.1f}% {'✓ OK' if gap < 0.03 else '⚠ still some gap'}")

# ─── TFLITE EXPORT ────────────────────────────────────────────────────────────
print(f"\n  Converting to TFLite...")
saved_path = os.path.join(OUTPUT_DIR, 'saved_model_final')
model_final.export(saved_path)

conv = tf.lite.TFLiteConverter.from_saved_model(saved_path)
conv.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS,
                                   tf.lite.OpsSet.SELECT_TF_OPS]
tflite = conv.convert()
tflite_path = os.path.join(OUTPUT_DIR, 'traffic_sign_efficientnet.tflite')
with open(tflite_path, 'wb') as f:
    f.write(tflite)
print(f"  ✓ TFLite: {tflite_path} ({len(tflite)//1024} KB)")

# Save labels
with open(os.path.join(OUTPUT_DIR,'class_labels.json'),'w') as f:
    json.dump(CLASS_LABELS, f, indent=2)

# ─── SUMMARY ─────────────────────────────────────────────────────────────────
print(f"\n{'='*60}")
print("  DONE")
print(f"{'='*60}")
print(f"  Phase 1 accuracy  : {p1_acc*100:.1f}%  (loaded from checkpoint)")
print(f"  Phase 2 accuracy  : {best_acc*100:.1f}%")
print(f"  Reload check      : {reload_acc*100:.1f}%")
print(f"  TFLite model      : {len(tflite)//1024} KB")
print(f"\n  Copy to RPi 5:")
print(f"    models/traffic_sign_efficientnet.tflite")
print(f"    models/class_labels.json")
print(f"{'='*60}")
