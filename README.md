# BirdApp

App de iOS que identifica aves **por su canto y por foto**, con todos los modelos ejecutándose en el dispositivo.

## Características

- 🐦 **Identificación de aves por sonido** con el modelo [BirdNET](https://birdnet.cornell.edu/) (BirdNET_GLOBAL_6K_V2.4) ejecutado localmente vía **Core ML**.
- 📷 **Identificación por foto** (pestaña *Foto*): elige una imagen o dispara con la cámara y la clasifica en el dispositivo. Usa [Google AIY Birds V1](https://www.kaggle.com/models/google/aiy) (MobileNetV2 entrenado con iNaturalist, 964 especies) convertido a Core ML. Los resultados se mapean a la taxonomía de BirdNET, así que reutilizan los nombres nativos y el filtro por ubicación.
- 📤 **Compartir desde Fotos**: BirdApp aparece en la hoja de compartir de Fotos (y de Safari, Mensajes, WhatsApp…). La extensión `BirdShare` deja la imagen **original, con su EXIF intacto** en el App Group y abre la app en la pestaña *Foto*, que sigue con el flujo de siempre: encuadre, clasificación, historial y canto.
- ✂️ **Encuadre manual del ave**: toda foto —de la cámara o de la galería— pasa por una pantalla donde decides qué mirar. Un toque sobre el pájaro lo selecciona (segmentación de sujetos de Vision, el mismo motor del «levantar sujeto del fondo» de iOS), o arrastras un recuadro a mano; también puedes dejar el recorte automático por saliencia. Desde el resultado se reencuadra sin repetir la foto: un recorte malo es la causa más común de una identificación mala.
- 🔊 **Escuchar el canto** de la especie identificada, desde el archivo de [xeno-canto](https://xeno-canto.org) (requiere una clave API gratuita, ver abajo). Disponible desde el resultado por foto, la ficha del ave **y cada fila del historial**.
- 🎤 **Escucha en directo** desde el micrófono, con extracción de mel-espectrograma propia (`MelSpectrogramExtractor`, `filterbank1/2.bin`).
- 🌙 **Escucha en segundo plano** (opt-in, `Ajustes → Segundo plano`): sigue identificando con la app minimizada o la pantalla bloqueada, con auto-apagado configurable para no drenar la batería. Sobrevive interrupciones (llamadas, Siri).
- 🔗 **Fusión audio↔foto**: al identificar una foto, se da preferencia a las especies oídas por el micrófono en los últimos minutos (desempata candidatos parecidos sin inflar los porcentajes).
- 📍 **Filtro por ubicación y temporada** (`LocationFilter`): pondera las especies probables según dónde y cuándo estás (influencia configurable). En las fotos de la galería se usan **la ubicación y la fecha del propio EXIF**, no las de ahora: una foto de un viaje se puntúa contra el lugar y la época en que se tomó. Las fotos de cámara, que no llevan metadatos, usan la posición actual.
- 🤔 **Desempate manual entre especies parecidas**: cuando el segundo candidato queda a menos del 35 % del primero, la app pregunta en vez de elegir por ti. Aparece bajo el resultado de la foto y en la ficha de cualquier detección del historial, incluidas las de sonido; tu elección corrige el historial, el canto y los widgets, y se puede deshacer. Los modelos son más débiles justo entre parejas casi idénticas (trepadores, colirrojos, pitos), donde un detalle decide.
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
│   ├── PhotoFramingView.swift     # Encuadre manual (tocar sujeto o recortar)
│   ├── IncomingPhotoRouter.swift  # Fotos que llegan de la hoja de compartir
│   ├── SpeciesTiebreaker.swift    # «¿Cuál era?» entre especies casi empatadas
│   ├── XenoCantoService.swift / BirdSongPlayer.swift  # Búsqueda y reproducción de cantos
│   ├── BirdIdentifier.swift / BirdDetection.swift  # Lógica de identificación
│   ├── ModelManager.swift         # Carga de los modelos
│   ├── LocationFilter.swift / LocationManager.swift  # Filtro geo/estacional
│   ├── WikipediaImageService.swift
│   ├── DetectionStore.swift / HistoryView.swift
│   ├── SettingsView.swift / BirdDetailView.swift
│   └── BirdNET_*_Labels_*.txt     # Etiquetas en múltiples idiomas
├── BirdWidget/                    # Extensión de widgets
├── BirdShare/                     # Extensión de compartir (entrada desde Fotos)
│   └── ShareViewController.swift  # Puente: guarda la foto y abre la app
├── Shared/                        # Código compilado en la app y sus extensiones
│   └── SharedPhotoInbox.swift     # Buzón de fotos en el App Group
├── Info.plist                     # Base fusionada con las claves generadas (UIBackgroundModes=audio, esquema birdapp://)
├── Tools/                         # Scripts (widget, compartir, modelos, tooling del clasificador ibérico)
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

Ese sesgo también aparece entre especies hermanas: con fotos nítidas de un trepador azul (*Sitta europaea*) acierta al 90-93 %, pero en una foto lejana compite de tú a tú con el trepador canadiense (*Sitta canadensis*) y basta mover el recorte unos píxeles para que el orden cambie. Ahí es donde entran el filtro por ubicación y el desempate manual; el filtro suave por sí solo no siempre separa una pareja así, porque el meta-modelo de BirdNET todavía concede una probabilidad residual a la especie americana en el norte peninsular.

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
| `background_listening` | false | Seguir escuchando con la app minimizada (opt-in) |
| `background_listening_minutes` | 30 | Auto-apagado de la escucha en segundo plano |
| `audio_photo_fusion` | true | Favorecer en foto las especies oídas hace poco |

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
