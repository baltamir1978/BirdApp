# BirdApp

App de iOS que identifica aves por su canto en tiempo real, usando el modelo de aprendizaje automático **BirdNET** ejecutado en el dispositivo.

## Características

- 🐦 **Identificación de aves por sonido** con el modelo [BirdNET](https://birdnet.cornell.edu/) (BirdNET_GLOBAL_6K_V2.4) ejecutado localmente vía **TensorFlow Lite** / Core ML.
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
- **CocoaPods** (el proyecto usa `TensorFlowLiteSwift`)
- Dispositivo real recomendado (acceso a micrófono)

## Instalación

```bash
# 1. Instala las dependencias
cd BirdApp
pod install

# 2. Abre SIEMPRE el workspace, no el .xcodeproj
open BirdApp.xcworkspace
```

> El `Podfile` fija `platform :ios, '17.0'` y `pod 'TensorFlowLiteSwift', '~> 2.14'`.

## Estructura del proyecto

```
BirdApp/
├── BirdApp/                       # Target principal
│   ├── BirdAppApp.swift           # Entrada + observador Darwin (Stop desde widget)
│   ├── ContentView.swift / ListenView.swift / OnboardingView.swift
│   ├── AudioAnalyzer.swift        # Captura y troceado de audio del micro
│   ├── MelSpectrogramExtractor.swift  # Pre-proceso (mel-espectrograma)
│   ├── BirdNETAnalyzer.swift      # Inferencia con el modelo BirdNET
│   ├── BirdIdentifier.swift / BirdDetection.swift  # Lógica de identificación
│   ├── ModelManager.swift         # Carga del modelo
│   ├── LocationFilter.swift / LocationManager.swift  # Filtro geo/estacional
│   ├── WikipediaImageService.swift
│   ├── DetectionStore.swift / HistoryView.swift
│   ├── SettingsView.swift / BirdDetailView.swift
│   └── BirdNET_*_Labels_*.txt     # Etiquetas en múltiples idiomas
├── BirdWidget/                    # Extensión de widgets
├── Tools/                         # Scripts (add_widget_target.rb)
├── Podfile
└── PrivacyInfo.xcprivacy          # Manifiesto de privacidad
```

### Modelo y assets de ML

En la raíz del repo y bajo `BirdApp/` se incluyen los artefactos del modelo:

- `BirdNET_classifier_only.tflite` / `.onnx` — clasificador.
- `BirdNET_Classifier.mlpackage` — versión Core ML.
- `filterbank1.bin`, `filterbank2.bin` — bancos de filtros para el mel-espectrograma.
- `BirdNET_GLOBAL_6K_V2.4_Labels*.txt` — etiquetas de especies.

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

- Requiere permiso de **micrófono** para escuchar el canto.
- Opcionalmente, **ubicación** para el filtro geográfico/estacional.
- Toda la inferencia se ejecuta **en el dispositivo**; el audio no se envía a servidores.

## Créditos

- Modelo **BirdNET** — K. Lisa Yang Center for Conservation Bioacoustics, Cornell Lab of Ornithology.
- Imágenes y descripciones desde Wikipedia.

## Licencia

Proyecto personal de Bruno Altamirano. El modelo BirdNET está sujeto a su propia licencia (uso no comercial; revisa los términos de Cornell antes de distribuir).
