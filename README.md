# BirdApp

App de iOS que identifica aves **por su canto y por foto**, con todos los modelos ejecutándose en el dispositivo.

## Características

- 🐦 **Identificación de aves por sonido** con el modelo [BirdNET](https://birdnet.cornell.edu/) (BirdNET_GLOBAL_6K_V2.4) ejecutado localmente vía **Core ML**.
- 📷 **Identificación por foto** (pestaña *Foto*): elige una imagen o dispara con la cámara y la clasifica en el dispositivo. Usa [Google AIY Birds V1](https://www.kaggle.com/models/google/aiy) (MobileNetV2 entrenado con iNaturalist, 964 especies) convertido a Core ML, precedido de un recorte automático del ave con la saliencia de Vision. Los resultados se mapean a la taxonomía de BirdNET, así que reutilizan los nombres nativos y el filtro por ubicación.
- 🔊 **Escuchar el canto** de la especie identificada, desde el archivo de [xeno-canto](https://xeno-canto.org) (requiere una clave API gratuita, ver abajo).
- 🎤 **Escucha en directo** desde el micrófono, con extracción de mel-espectrograma propia (`MelSpectrogramExtractor`, `filterbank1/2.bin`).
- 📍 **Filtro por ubicación y temporada** (`LocationFilter`): pondera las especies probables según dónde y cuándo estás (influencia configurable).
- 🌐 **Nombres comunes nativos** en muchos idiomas (archivos `BirdNET_GLOBAL_6K_V2.4_Labels_*.txt`).
- 🖼️ **Ficha de cada ave** con imagen y descripción desde Wikipedia (`WikipediaImageService`).
- 🕑 **Historial de detecciones** con de-duplicación.
- 📱 **Widgets** (WidgetKit): última ave detectada y control de escucha, con comunicación entre procesos vía notificaciones Darwin.
- 🗣️ **App Shortcuts / Siri** (`BirdShortcuts`).
- ⚙️ **Ajustes avanzados** de detección: umbral de confianza, sensibilidad (pendiente sigmoide), suavizado temporal, filtro paso-alto, *gates* de señal/clipping, audio sin procesar, etc.

## Requisitos

- Xcode 15 o superior
- iOS 17.0+
- Dispositivo real recomendado (el simulador no tiene micrófono ni cámara fiables)

## Instalación

No hay dependencias externas: toda la inferencia usa Core ML y Vision del sistema.

```bash
open BirdApp.xcodeproj
```

O desde la línea de comandos:

```bash
xcodebuild build -project BirdApp.xcodeproj -scheme BirdApp \
  -destination 'generic/platform=iOS Simulator'
```

> El `Podfile` de la raíz es un vestigio de una versión anterior basada en TensorFlow Lite. **No lo uses**: no hay `Pods/` ni workspace, y ningún fichero Swift importa TensorFlowLite.

## Cantos de aves (xeno-canto)

Reproducir el canto de una especie requiere una clave API personal de [xeno-canto](https://xeno-canto.org), gratuita para cualquier miembro registrado con el correo verificado. Se introduce en **Ajustes → Cantos**.

Para desarrollo puedes evitar teclearla en cada instalación creando `BirdApp/DeveloperKeys.plist`:

```xml
<plist version="1.0">
<dict>
	<key>xenocanto_api_key</key>
	<string>TU_CLAVE</string>
</dict>
</plist>
```

Ese fichero está en `.gitignore` y se carga sólo como valor por defecto (lo que se escriba en Ajustes tiene prioridad). **Bórralo antes de publicar en la App Store**: una clave dentro del `.ipa` es extraíble y su abuso se penalizaría a tu cuenta.

## Estructura del proyecto

```
BirdApp/
├── BirdApp/                       # Target principal
│   ├── BirdAppApp.swift           # Entrada + observador Darwin (Stop desde widget)
│   ├── ContentView.swift / ListenView.swift / OnboardingView.swift
│   ├── AudioAnalyzer.swift        # Captura y troceado de audio del micro
│   ├── MelSpectrogramExtractor.swift  # Pre-proceso (mel-espectrograma)
│   ├── BirdNETAnalyzer.swift      # Inferencia con el modelo BirdNET
│   ├── PhotoIdentifier.swift / PhotoView.swift     # Identificación por foto
│   ├── XenoCantoService.swift / BirdSongPlayer.swift  # Búsqueda y reproducción de cantos
│   ├── BirdIdentifier.swift / BirdDetection.swift  # Lógica de identificación
│   ├── ModelManager.swift         # Carga de los modelos
│   ├── LocationFilter.swift / LocationManager.swift  # Filtro geo/estacional
│   ├── WikipediaImageService.swift
│   ├── DetectionStore.swift / HistoryView.swift
│   ├── SettingsView.swift / BirdDetailView.swift
│   └── BirdNET_*_Labels_*.txt     # Etiquetas en múltiples idiomas
├── BirdWidget/                    # Extensión de widgets
├── Tools/                         # Scripts (add_widget_target.rb, convert_photo_model.py)
├── Podfile
└── PrivacyInfo.xcprivacy          # Manifiesto de privacidad
```

### Modelo y assets de ML

En la raíz del repo y bajo `BirdApp/` se incluyen los artefactos del modelo:

- `BirdNET_classifier_only.tflite` / `.onnx` — clasificador.
- `BirdNET_Classifier.mlpackage` — versión Core ML (canto).
- `BirdPhoto_Classifier.mlpackage` — clasificador de imagen (Google AIY Birds V1), generado por `Tools/convert_photo_model.py`.
- `filterbank1.bin`, `filterbank2.bin` — bancos de filtros para el mel-espectrograma.
- `BirdNET_GLOBAL_6K_V2.4_Labels*.txt` — etiquetas de especies.

#### Regenerar el modelo de fotos

```bash
python3 Tools/convert_photo_model.py   # requiere tensorflow + coremltools
```

Dos detalles no evidentes, documentados en el propio script: la salida del modelo se llama `logits` pero **ya son probabilidades** (aplicarle un softmax la aplana), y **hay que convertir en FLOAT32** — en FLOAT16 el modelo pierde precisión hasta devolver una constante que ignora la entrada.

#### Cobertura del modelo de fotos

964 especies, de las que el 87,8 % mapean directamente contra las 6522 de BirdNET. Sobre una muestra de 96 especies ibéricas comunes cubre el **79 %**; el modelo tiene sesgo norteamericano y le faltan aves habituales en España como *Sturnus unicolor*, *Luscinia megarhynchos*, *Curruca melanocephala*, *Cettia cetti* u *Oriolus oriolus*, con las que devolverá la especie parecida más cercana.

> ⚠️ Estos ficheros pueden ser grandes. Considera **Git LFS** para versionarlos (ver REVISION.md).

## Ajustes de detección (valores por defecto)

| Ajuste | Valor | Descripción |
|---|---|---|
| `confidence_threshold` | 0.35 | Umbral mínimo de confianza |
| `detection_sensitivity` | 1.3 | Pendiente del sigmoide (0.5–1.5) |
| `temporal_smoothing` | false | Consenso entre ventanas solapadas |
| `location_filter_influence` | 0.7 | 0 = sin filtro … 1 = filtro completo |
| `high_pass_filter` | false | Filtro paso-alto |
| `signal_gate` | false | Descartar silencio / ruido grave |
| `clip_gate` | true | Descartar audio saturado |
| `unprocessed_audio` | true | Micrófono sin DSP del sistema |

## Privacidad

- Requiere permiso de **micrófono** para escuchar el canto y de **cámara** para identificar por foto.
- Opcionalmente, **ubicación** para el filtro geográfico/estacional.
- Toda la inferencia se ejecuta **en el dispositivo**: ni el audio ni las fotos salen de él. Sólo se hacen peticiones de red para material de referencia — imágenes y descripciones de Wikipedia, y grabaciones de xeno-canto —, siempre a partir del nombre científico, nunca de tus datos.

## Créditos

- Modelo **BirdNET** — K. Lisa Yang Center for Conservation Bioacoustics, Cornell Lab of Ornithology.
- Clasificador de imagen **Google AIY Birds V1**, entrenado con datos de iNaturalist.
- Grabaciones de **[xeno-canto](https://xeno-canto.org)**, con licencia Creative Commons. La app acredita al autor de cada grabación al reproducirla, como exigen esas licencias.
- Imágenes y descripciones desde Wikipedia.

## Licencia

Proyecto personal de Bruno Altamirano. El modelo BirdNET está sujeto a su propia licencia (uso no comercial; revisa los términos de Cornell antes de distribuir).
