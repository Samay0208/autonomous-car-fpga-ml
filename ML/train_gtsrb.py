"""
GTSRB Traffic Sign Classifier — MobileNetV2 Transfer Learning
Run this FIRST. Takes 1-2 hours. Let it run while you work on VHDL.

STEP 1: Install dependencies
    pip install tensorflow pillow numpy scikit-learn

STEP 2: Download dataset from Kaggle
    https://www.kaggle.com/datasets/meowmeowmeowmeowmeow/gtsrb-german-traffic-sign
    Extract so folder structure is:
        GTSRB/
            Train/   <-- 43 subfolders (00000 to 00042)
            Test/
            Meta/

STEP 3: Run this script
    python train_gtsrb.py

Output: traffic_sign_model.tflite  (~2MB, ready for ESP32)
"""

"""
train_gtsrb_v2.py — FIXED Training Script
==========================================
Key fixes from v1:
  1. CRITICAL: MobileNetV2 requires preprocess_input() → [-1,1] range
     NOT rescale=1/255 → [0,1]. This alone was killing accuracy.
  2. Larger image (96x96 vs 64x64) — signs have fine detail
  3. Full MobileNetV2 alpha=1.0 instead of 0.5
  4. Class weights to handle GTSRB class imbalance
  5. Cosine annealing LR instead of step reduce
  6. More fine-tuning layers unfrozen (40 vs 20)
  7. Correct augmentation (no horizontal flip on signs)

Expected accuracy: 95-98%
Run time: 45-90 minutes depending on your machine

Setup:
    pip install tensorflow pillow numpy scikit-learn
    python train_gtsrb_v2.py
"""

import os
import json
import numpy as np
import tensorflow as tf
from tensorflow.keras.applications import MobileNetV2
from tensorflow.keras.applications.mobilenet_v2 import preprocess_input
from tensorflow.keras.layers import Dense, GlobalAveragePooling2D, Dropout, BatchNormalization
from tensorflow.keras.models import Model
from tensorflow.keras.preprocessing.image import ImageDataGenerator
from tensorflow.keras.callbacks import EarlyStopping, ModelCheckpoint, LearningRateScheduler
from sklearn.utils.class_weight import compute_class_weight
import math

# ─── CONFIG ───────────────────────────────────────────────────────────────────
IMG_SIZE     = 96          # Better detail than 64. Signs have text/shapes.
BATCH_SIZE   = 32
EPOCHS_HEAD  = 20          # Train head only (base frozen)
EPOCHS_FINE  = 15          # Fine-tune top 40 layers
NUM_CLASSES  = 43
DATA_DIR     = './GTSRB/Train'
OUTPUT_DIR   = './model_output'
# ──────────────────────────────────────────────────────────────────────────────

os.makedirs(OUTPUT_DIR, exist_ok=True)

# ─── STEP 1: VERIFY DATASET ───────────────────────────────────────────────────
print("="*60)
print("  Step 1: Verifying dataset structure...")
print("="*60)

if not os.path.exists(DATA_DIR):
    print(f"\n  ERROR: Dataset not found at '{DATA_DIR}'")
    print("  Make sure your folder structure is:")
    print("    GTSRB/Train/0/*.png")
    print("    GTSRB/Train/1/*.png  ...etc")
    exit(1)

class_folders = [d for d in os.listdir(DATA_DIR)
                 if os.path.isdir(os.path.join(DATA_DIR, d))]
print(f"  Found {len(class_folders)} class folders")

if len(class_folders) < 43:
    print(f"  WARNING: Expected 43 classes, found {len(class_folders)}")

total_images = 0
class_counts = {}
for folder in sorted(class_folders):
    folder_path = os.path.join(DATA_DIR, folder)
    images = [f for f in os.listdir(folder_path)
              if f.lower().endswith(('.png', '.jpg', '.jpeg', '.ppm'))]
    class_counts[folder] = len(images)
    total_images += len(images)

print(f"  Total images     : {total_images}")
print(f"  Min class size   : {min(class_counts.values())} images")
print(f"  Max class size   : {max(class_counts.values())} images")
print(f"  Image size used  : {IMG_SIZE}x{IMG_SIZE}")
print()

# ─── STEP 2: DATA GENERATORS ─────────────────────────────────────────────────
# CRITICAL FIX: Use preprocessing_function=preprocess_input
# This scales pixels to [-1, 1] range which MobileNetV2 was trained on.
# The old script used rescale=1/255 which gave [0,1] — wrong for pretrained weights.

print("  Step 2: Building data pipeline (correct preprocessing)...")

train_datagen = ImageDataGenerator(
    preprocessing_function=preprocess_input,  # ← THE KEY FIX
    rotation_range=15,
    width_shift_range=0.1,
    height_shift_range=0.1,
    zoom_range=0.2,
    brightness_range=[0.6, 1.4],
    shear_range=0.1,
    horizontal_flip=False,   # Traffic signs must NOT be flipped
    fill_mode='nearest',
    validation_split=0.2
)

val_datagen = ImageDataGenerator(
    preprocessing_function=preprocess_input,  # Same preprocessing, no augmentation
    validation_split=0.2
)

train_gen = train_datagen.flow_from_directory(
    DATA_DIR,
    target_size=(IMG_SIZE, IMG_SIZE),
    batch_size=BATCH_SIZE,
    class_mode='categorical',
    subset='training',
    shuffle=True,
    seed=42
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

print(f"  Training samples   : {train_gen.samples}")
print(f"  Validation samples : {val_gen.samples}")

# ─── STEP 3: CLASS WEIGHTS (handle imbalanced GTSRB) ─────────────────────────
# GTSRB has very unequal class sizes (30 to 2250 images per class).
# Class weights make the model pay more attention to rare classes.
print("\n  Step 3: Computing class weights for imbalanced dataset...")

all_labels = train_gen.classes
class_weights_array = compute_class_weight(
    class_weight='balanced',
    classes=np.unique(all_labels),
    y=all_labels
)
class_weight_dict = dict(enumerate(class_weights_array))
print(f"  Class weight range : {min(class_weights_array):.2f} to {max(class_weights_array):.2f}")

# ─── STEP 4: MODEL ────────────────────────────────────────────────────────────
print("\n  Step 4: Building MobileNetV2 model (alpha=1.0, full size)...")

base_model = MobileNetV2(
    input_shape=(IMG_SIZE, IMG_SIZE, 3),
    include_top=False,
    weights='imagenet',
    alpha=1.0   # Full model — much better than 0.5 for sign recognition
)
base_model.trainable = False  # Freeze all for phase 1

x = base_model.output
x = GlobalAveragePooling2D()(x)
x = BatchNormalization()(x)
x = Dropout(0.4)(x)
x = Dense(256, activation='relu')(x)
x = BatchNormalization()(x)
x = Dropout(0.3)(x)
output = Dense(NUM_CLASSES, activation='softmax')(x)

model = Model(inputs=base_model.input, outputs=output)

total_params = model.count_params()
print(f"  Total parameters   : {total_params:,}")

# ─── STEP 5: COSINE LR SCHEDULE ──────────────────────────────────────────────
def cosine_lr_phase1(epoch, lr):
    """Cosine annealing for phase 1: starts at 1e-3, ends at 1e-5"""
    lr_min  = 1e-5
    lr_max  = 1e-3
    cos_val = math.cos(math.pi * epoch / EPOCHS_HEAD)
    return lr_min + 0.5 * (lr_max - lr_min) * (1 + cos_val)

def cosine_lr_phase2(epoch, lr):
    """Cosine annealing for fine-tuning: starts at 5e-5, ends at 1e-6"""
    lr_min  = 1e-6
    lr_max  = 5e-5
    cos_val = math.cos(math.pi * epoch / EPOCHS_FINE)
    return lr_min + 0.5 * (lr_max - lr_min) * (1 + cos_val)

# ─── PHASE 1: TRAIN HEAD ONLY ─────────────────────────────────────────────────
print(f"\n{'─'*60}")
print("  PHASE 1: Training classification head")
print("  Base model: FROZEN | Head: TRAINING")
print(f"  Epochs: {EPOCHS_HEAD} | LR: 1e-3 → 1e-5 (cosine)")
print(f"{'─'*60}")

model.compile(
    optimizer=tf.keras.optimizers.Adam(learning_rate=1e-3),
    loss='categorical_crossentropy',
    metrics=['accuracy', tf.keras.metrics.TopKCategoricalAccuracy(k=3, name='top3_acc')]
)

callbacks_p1 = [
    EarlyStopping(
        monitor='val_accuracy',
        patience=5,
        restore_best_weights=True,
        verbose=1
    ),
    ModelCheckpoint(
        os.path.join(OUTPUT_DIR, 'best_phase1.h5'),
        monitor='val_accuracy',
        save_best_only=True,
        verbose=0
    ),
    LearningRateScheduler(cosine_lr_phase1, verbose=0)
]

history1 = model.fit(
    train_gen,
    validation_data=val_gen,
    epochs=EPOCHS_HEAD,
    callbacks=callbacks_p1,
    class_weight=class_weight_dict,
    verbose=1
)

best_p1_acc = max(history1.history['val_accuracy'])
print(f"\n  ✓ Phase 1 best val accuracy : {best_p1_acc*100:.1f}%")

# ─── PHASE 2: FINE-TUNING ─────────────────────────────────────────────────────
print(f"\n{'─'*60}")
print("  PHASE 2: Fine-tuning — unfreezing top 40 base layers")
print(f"  Epochs: {EPOCHS_FINE} | LR: 5e-5 → 1e-6 (cosine)")
print(f"{'─'*60}")

base_model.trainable = True
total_layers = len(base_model.layers)
freeze_until = total_layers - 40

for i, layer in enumerate(base_model.layers):
    layer.trainable = (i >= freeze_until)

trainable_count = sum(1 for l in base_model.layers if l.trainable)
print(f"  Unfrozen base layers : {trainable_count} / {total_layers}")

model.compile(
    optimizer=tf.keras.optimizers.Adam(learning_rate=5e-5),
    loss='categorical_crossentropy',
    metrics=['accuracy', tf.keras.metrics.TopKCategoricalAccuracy(k=3, name='top3_acc')]
)

callbacks_p2 = [
    EarlyStopping(
        monitor='val_accuracy',
        patience=5,
        restore_best_weights=True,
        verbose=1
    ),
    ModelCheckpoint(
        os.path.join(OUTPUT_DIR, 'best_final.h5'),
        monitor='val_accuracy',
        save_best_only=True,
        verbose=0
    ),
    LearningRateScheduler(cosine_lr_phase2, verbose=0)
]

history2 = model.fit(
    train_gen,
    validation_data=val_gen,
    epochs=EPOCHS_FINE,
    callbacks=callbacks_p2,
    class_weight=class_weight_dict,
    verbose=1
)

best_p2_acc = max(history2.history['val_accuracy'])
print(f"\n  ✓ Phase 2 best val accuracy : {best_p2_acc*100:.1f}%")

final_acc = best_p2_acc

# ─── STEP 6: EVALUATE ON VALIDATION SET ──────────────────────────────────────
print(f"\n{'─'*60}")
print("  Final evaluation on validation set...")
print(f"{'─'*60}")

val_gen.reset()
results = model.evaluate(val_gen, verbose=1)
print(f"  Val Loss     : {results[0]:.4f}")
print(f"  Val Accuracy : {results[1]*100:.2f}%")
print(f"  Top-3 Acc    : {results[2]*100:.2f}%")

# ─── STEP 7: PER-CLASS ACCURACY ──────────────────────────────────────────────
print(f"\n  Computing per-class accuracy...")
val_gen.reset()
y_pred_probs = model.predict(val_gen, verbose=0)
y_pred       = np.argmax(y_pred_probs, axis=1)
y_true       = val_gen.classes[:len(y_pred)]

class_labels = {
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

print(f"\n  {'Class':<20} {'Accuracy':>10}")
print(f"  {'─'*32}")
worst_classes = []
for cls_id in range(NUM_CLASSES):
    mask     = y_true == cls_id
    if mask.sum() == 0:
        continue
    cls_acc  = (y_pred[mask] == cls_id).mean()
    name     = class_labels.get(cls_id, str(cls_id))
    if cls_acc < 0.85:
        worst_classes.append((cls_id, name, cls_acc))
    marker = " ←" if cls_acc < 0.85 else ""
    print(f"  {name:<20} {cls_acc*100:>9.1f}%{marker}")

if worst_classes:
    print(f"\n  Classes below 85% accuracy (may need more training):")
    for cls_id, name, acc in sorted(worst_classes, key=lambda x: x[2]):
        print(f"    Class {cls_id:2d} ({name}): {acc*100:.1f}%")

# ─── STEP 8: TFLITE CONVERSION ────────────────────────────────────────────────
print(f"\n{'─'*60}")
print("  Step 8: Converting to TFLite...")
print(f"{'─'*60}")

# Float16 — for ESP32-S3 (has PSRAM, can handle larger model)
print("  Converting float16 model...")
conv_f16 = tf.lite.TFLiteConverter.from_keras_model(model)
conv_f16.optimizations         = [tf.lite.Optimize.DEFAULT]
conv_f16.target_spec.supported_types = [tf.float16]
tflite_f16 = conv_f16.convert()

path_f16 = os.path.join(OUTPUT_DIR, 'traffic_sign_model.tflite')
with open(path_f16, 'wb') as f:
    f.write(tflite_f16)
print(f"  ✓ Float16 saved: {len(tflite_f16)/1024:.0f} KB → {path_f16}")

# Int8 — for ESP32-CAM (less RAM available)
print("  Converting int8 model (needs calibration data)...")

def representative_data():
    val_gen.reset()
    for i, (imgs, _) in enumerate(val_gen):
        if i >= 150:
            break
        for img in imgs:
            yield [np.expand_dims(img, 0).astype(np.float32)]

conv_i8 = tf.lite.TFLiteConverter.from_keras_model(model)
conv_i8.optimizations = [tf.lite.Optimize.DEFAULT]
conv_i8.representative_dataset = representative_data
conv_i8.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
conv_i8.inference_input_type  = tf.int8
conv_i8.inference_output_type = tf.int8
tflite_i8 = conv_i8.convert()

path_i8 = os.path.join(OUTPUT_DIR, 'traffic_sign_model_int8.tflite')
with open(path_i8, 'wb') as f:
    f.write(tflite_i8)
print(f"  ✓ Int8 saved   : {len(tflite_i8)/1024:.0f} KB → {path_i8}")

# ─── STEP 9: VERIFY TFLITE ────────────────────────────────────────────────────
print(f"\n  Verifying TFLite model on 10 samples...")
interpreter = tf.lite.Interpreter(model_path=path_f16)
interpreter.allocate_tensors()
inp  = interpreter.get_input_details()
out  = interpreter.get_output_details()

val_gen.reset()
batch_imgs, batch_labels = next(iter(val_gen))
correct = 0
for i in range(min(10, len(batch_imgs))):
    img = np.expand_dims(batch_imgs[i], 0).astype(np.float32)
    interpreter.set_tensor(inp[0]['index'], img)
    interpreter.invoke()
    pred = np.argmax(interpreter.get_tensor(out[0]['index']))
    true = np.argmax(batch_labels[i])
    if pred == true:
        correct += 1
    print(f"  Sample {i+1}: pred={class_labels.get(pred,'?'):<15} true={class_labels.get(true,'?')}")

print(f"\n  TFLite spot-check: {correct}/10 correct")

# ─── STEP 10: SAVE LABELS & SUMMARY ──────────────────────────────────────────
with open(os.path.join(OUTPUT_DIR, 'class_labels.json'), 'w') as f:
    json.dump(class_labels, f, indent=2)

# Save preprocessing info (important for ESP32 inference)
info = {
    "img_size"        : IMG_SIZE,
    "num_classes"     : NUM_CLASSES,
    "preprocessing"   : "mobilenet_v2_preprocess_input",
    "input_range"     : "[-1, 1]",
    "formula"         : "pixel = (raw_pixel / 127.5) - 1.0",
    "val_accuracy"    : round(final_acc * 100, 2),
    "float16_model"   : "traffic_sign_model.tflite",
    "int8_model"      : "traffic_sign_model_int8.tflite"
}
with open(os.path.join(OUTPUT_DIR, 'model_info.json'), 'w') as f:
    json.dump(info, f, indent=2)

# ─── FINAL SUMMARY ────────────────────────────────────────────────────────────
print(f"\n{'='*60}")
print("  TRAINING COMPLETE")
print(f"{'='*60}")
print(f"  Phase 1 accuracy   : {best_p1_acc*100:.1f}%")
print(f"  Final accuracy     : {final_acc*100:.1f}%")
print(f"  Float16 model      : {len(tflite_f16)/1024:.0f} KB  → ESP32-S3")
print(f"  Int8 model         : {len(tflite_i8)/1024:.0f} KB  → ESP32-CAM")
print(f"  Output folder      : {OUTPUT_DIR}/")
print(f"{'='*60}")
print()
print("  IMPORTANT — Preprocessing for ESP32:")
print("  When running inference on ESP32, scale pixels like this:")
print("  pixel_normalized = (raw_pixel_0_255 / 127.5) - 1.0")
print("  This maps [0,255] → [-1,1]")
print()
print("  Next step: Copy .tflite file to ESP32")