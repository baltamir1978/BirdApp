# Revisión de código — BirdApp

Revisión del estado del proyecto y recomendaciones antes de publicar/distribuir.

## Resumen

App de identificación de aves por canto con inferencia **en el dispositivo** (BirdNET + TensorFlow Lite / Core ML). Arquitectura clara: captura → pre-proceso (mel-espectrograma) → inferencia → filtro geo/estacional → resultados/historial. Buena atención al detalle (registro de defaults en `UserDefaults`, comunicación entre procesos con el widget vía notificaciones Darwin).

## Estado de Git

- Rama: `main` → `origin` (`github.com/baltamir1978/BirdApp.git`).
- Cambios menores sin commitear: `xcschememanagement.plist` y `xcshareddata/` sin trackear.
- 5 commits; historial corto pero coherente.

## Hallazgos importantes

### ⚠️ 1. Archivos grandes en Git → usar Git LFS
Hay binarios de modelo versionados directamente:

| Archivo | Tamaño aprox. |
|---|---|
| `BirdNET_Classifier.mlpackage/.../model.mlmodel` | ~50 MB |
| `meta_weights.bin` | ~29 MB |

GitHub avisa a partir de 50 MB y **rechaza** ficheros >100 MB. Recomendación: migrar a **Git LFS**:

```bash
git lfs install
git lfs track "*.mlmodel" "*.bin" "*.tflite" "*.onnx" "*.mlpackage/**"
git add .gitattributes
# Reescribir histórico si ya pesa demasiado: git lfs migrate import --include="*.mlmodel,*.bin"
```

### ⚠️ 2. `.gitignore` ignora `*.xcworkspace`
La línea `*.xcworkspace` bajo *CocoaPods* impide versionar `BirdApp.xcworkspace`. Como el proyecto **usa CocoaPods**, hay que abrir el *workspace* para compilar. Quien clone el repo no lo tendrá: deberá ejecutar `pod install` para regenerarlo. Documentado ya en el README, pero conviene dejarlo explícito y verificar que `Podfile.lock` **sí** se versiona (para builds reproducibles).

## Puntos fuertes

- ✅ Inferencia local → privacidad: el audio no sale del dispositivo.
- ✅ `PrivacyInfo.xcprivacy` presente (manifiesto de privacidad de Apple).
- ✅ Comentarios que explican el *por qué* (p. ej. el registro de defaults que evitaba desactivar el filtro de ubicación silenciosamente).
- ✅ Soporte multi-idioma de nombres comunes.
- ✅ Ajustes de detección configurables y bien documentados.

## Recomendaciones adicionales

### Configuración
- Confirmar `NSMicrophoneUsageDescription` y `NSLocationWhenInUseUsageDescription` con textos claros en `Info.plist`.
- Versionar `Podfile.lock`; no versionar `Pods/` (ya ignorado ✅).

### Licencias
- **BirdNET** tiene licencia de uso no comercial (Cornell). Antes de publicar en App Store o distribuir, revisar que el uso cumple los términos y añadir la atribución requerida (incluida en el README).

### Calidad
- Hay tres formatos del modelo en el repo (`.tflite`, `.onnx`, `.mlpackage`). Si solo se usa uno en producción, eliminar los demás del target/repo reduce mucho el tamaño.
- Considerar tests unitarios del pipeline determinista (mel-espectrograma con un WAV fijo → vector esperado; parseo de etiquetas).

## Checklist previo a release

- [ ] Migrar binarios de modelo a Git LFS.
- [ ] Verificar que `pod install` + abrir `.xcworkspace` compila desde un clon limpio.
- [ ] Revisar textos de permisos (micrófono, ubicación).
- [ ] Confirmar atribución y licencia de BirdNET.
- [ ] Eliminar formatos de modelo no usados.
- [ ] Probar widget + señal de Stop entre procesos en dispositivo real.
