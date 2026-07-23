# Tools

Scripts de apoyo. Ninguno se ejecuta en la app: producen los recursos que la app
lleva empaquetados.

## Clasificador ibérico de fotos (fase 2 — NO integrada, 2026-07-23)

El modelo mundial (Google AIY Birds V1) sólo cubre el 79 % de las especies
ibéricas comunes: le faltan aves tan corrientes aquí como el estornino negro, la
curruca cabecinegra o el ruiseñor. Esta tubería entrena un clasificador
específico que convive con él — la app elige uno u otro según el GPS.

**ESTADO: probada pero no integrada.** El dataset descargado (78k fotos) se
borró; los scripts se conservan y regeneran todo. Dos aprendizajes decisivos:

1. **`MLImageClassifier` (el `xcrun swift Tools/train_iberian.swift`) NO funciona
   headless** con >~5.000 imágenes: revienta con `CVPixelBufferPool Width=0,
   Height=0` (agota IOSurfaces). No es dato corrupto ni nº de clases. **Úsalo
   desde la app Create ML.app (GUI)**, que tiene sesión gráfica y no sufre el
   bug — arrastra `Tools/dataset` a un proyecto Image Classifier y entrena.
2. **El workaround "dos fases" (`extract_features.swift` + `compose_model.py`)
   sí corre headless pero topa en ~42 % top-1 / 62 % top-3**, porque su extractor
   `VisionFeaturePrint.Scene` (768-dim) está pensado para escenas, no para
   distinguir especies casi idénticas. Un clasificador más potente encima no
   ayuda (medido). Sólo el fine-tuning CNN de la GUI subiría de ahí.

Ejecutar en orden desde `/Users/bruno/BirdApp/BirdApp`:

```bash
# 1. Qué especies cubrir (~390). Las deduce del meta-modelo de BirdNET que ya
#    va en la app, muestreado sobre una máscara de tierra peninsular.
python3 Tools/iberian_species.py --out Tools/iberian_species_peninsular.txt

# 2. (Opcional) Cuántas fotos hay disponibles por especie.
python3 Tools/inat_census.py

# 3. Descargar el set de entrenamiento (~2,6 GB, ~3 h).
python3 Tools/inat_download.py --per-species 250

# 4. Entrenar (minutos: sólo se entrena la cabeza sobre scenePrint).
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift Tools/train_iberian.swift Tools/dataset Tools/BirdPhoto_Iberian.mlmodel

# 5. Instalar en la app (se auto-empaqueta: carpeta sincronizada por Xcode).
cp Tools/BirdPhoto_Iberian.mlmodel BirdApp/
```

`ModelManager` lo localiza solo; si el archivo no está, la app sigue funcionando
con el modelo mundial en todas partes.

### Decisiones que costaron un rato y conviene no revisar a ciegas

- **La rejilla geográfica no puede ser un rectángulo lat/lon.** Sus esquinas
  caen en el mar de Alborán y frente a Argel, y el meta-modelo devuelve allí
  aves norteafricanas con p≈0,99 (*Passer simplex*, *Pycnonotus barbatus*). De
  ahí la máscara de polígono en `iberian_species.py`. Queda una fuga residual
  de tres especies con p≈0,07–0,34: es inevitable, Tarifa está a 14 km de
  Marruecos, y esas aves aparecen de verdad como divagantes en el sur.
- **No usar `order_by=votes` en iNaturalist.** Las fotos más votadas son las
  espectaculares o raras: el primer mirlo que devolvió era un ejemplar
  leucístico (blanco). Para entrenar se quieren pájaros típicos.
- **La clase `__background__` es obligatoria.** AIY la trae de fábrica y
  `PhotoIdentifier` la usa para responder "aquí no hay ningún pájaro". Create ML
  no genera nada equivalente, así que `inat_download.py` la construye con fotos
  de plantas, insectos, hongos, etc. Sin ella, una foto de una silla se
  clasificaría con toda confianza como algún párido.
- **Las fotos se guardan reescaladas a 320 px.** El extractor de rasgos trabaja
  a 299×299, así que lo demás es detalle que se tira: 2,6 GB en vez de 17 GB.

## Otros

- `convert_photo_model.py` — convierte AIY Birds V1 (SavedModel TF1) a Core ML.
  Ojo: la salida `logits` YA son probabilidades (no aplicar softmax) y hay que
  convertir con `compute_precision=FLOAT32` — en FLOAT16 el modelo devuelve una
  constante que ignora la entrada.
- `add_widget_target.rb` — crea el target del widget con la gema `xcodeproj`.
  No es idempotente del todo: ver notas en el propio script antes de re-ejecutar.
