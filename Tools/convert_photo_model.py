#!/usr/bin/env python3
"""Convierte el SavedModel de Google AIY Birds V1 a Core ML (.mlpackage).

- OJO: la salida se llama "logits" pero YA son probabilidades (suman 1). Aplicarle
  un softmax encima las aplana a ~1/965 y en FLOAT16 el modelo colapsa a una
  constante que ignora la entrada. No tocar.
- Entrada como imagen 224x224 escalada a [0,1] (convención de los módulos TF Hub).
- Etiquetas: nombres científicos extraídos del TFLite oficial (964 + __background__).
"""
import os
import sys
import numpy as np
import tensorflow as tf
import coremltools as ct

SAVED_MODEL = "savedmodel"
LABELS = "labels/0-labels.txt"
OUT = "BirdPhoto_Classifier.mlpackage"

labels = [l.strip() for l in open(LABELS, encoding="utf-8") if l.strip()]
print(f"etiquetas: {len(labels)}")

loaded = tf.saved_model.load(SAVED_MODEL)
inner = loaded.signatures["image_classifier"]


@tf.function(input_signature=[tf.TensorSpec([1, 224, 224, 3], tf.float32, name="images")])
def model_fn(images):
    return tf.identity(inner(images=images)["logits"], name="probs")


cf = model_fn.get_concrete_function()

mlmodel = ct.convert(
    [cf],
    source="tensorflow",
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.iOS16,
    # FLOAT16 NO vale: aplana la salida a ~1/965 y el modelo deja de responder a
    # la entrada (comprobado). Con FLOAT32 coincide con TF hasta 1e-3.
    compute_precision=ct.precision.FLOAT32,
    inputs=[ct.ImageType(name="images", shape=(1, 224, 224, 3), scale=1 / 255.0, bias=[0, 0, 0])],
    classifier_config=ct.ClassifierConfig(labels),
)

mlmodel.short_description = "Google AIY Birds V1 (MobileNetV2, iNaturalist) - 964 especies"
mlmodel.author = "Google AIY / convertido para BirdApp"
mlmodel.input_description["images"] = "Foto del ave recortada, 224x224 RGB"
mlmodel.save(OUT)
print(f"guardado -> {OUT}")

# ---- verificación: Core ML debe coincidir con el TF original en fotos reales ----
import glob
from PIL import Image, ImageOps

spec = mlmodel.get_spec()
probs_key = [o.name for o in spec.description.output if o.name != spec.description.predictedFeatureName][0]

fallos, peor = 0, 0.0
for path in sorted(glob.glob("testimg/*.jpg")):
    esperado = os.path.basename(path).rsplit(".", 1)[0].replace("_", " ")
    im = ImageOps.fit(Image.open(path).convert("RGB"), (224, 224), Image.BICUBIC)
    arr = np.asarray(im).astype(np.float32)[None] / 255.0

    tf_p = model_fn(tf.constant(arr)).numpy()[0]
    cm_out = mlmodel.predict({"images": im})
    cm_p = np.array([cm_out[probs_key][l] for l in labels])

    peor = max(peor, float(np.abs(tf_p - cm_p).max()))
    top = labels[int(cm_p.argmax())]
    ok = top.lower() == esperado.lower()
    fallos += not ok
    print(f"{'OK ' if ok else '-- '}{esperado:24s} -> {top} {cm_p.max()*100:5.1f}%  (TF: {labels[int(tf_p.argmax())]} {tf_p.max()*100:.1f}%)")

print(f"\nmax |delta CoreML-TF| = {peor:.5f}   fallos top-1: {fallos}")
sys.exit(1 if fallos or peor > 0.02 else 0)
