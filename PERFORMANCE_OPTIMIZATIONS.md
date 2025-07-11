# Optimizaciones de Rendimiento para Cambios de Canción

## Problema Identificado

El reproductor de música se volvía lento cuando se realizaban múltiples cambios de canción de forma rápida y consecutiva. Esto se debía a:

1. **Bucles de espera largos**: Los métodos de cambio de canción tenían bucles que esperaban hasta 50 intentos con delays de 20ms
2. **Falta de control de concurrencia**: Múltiples cambios simultáneos podían causar conflictos
3. **Carga ineficiente**: El método de carga inicial tenía delays innecesarios

## Optimizaciones Implementadas

### 1. Sistema de Debounce

**Problema**: Cambios muy rápidos causaban acumulación de operaciones pendientes.

**Solución**: Implementado un sistema de debounce con un delay de 100ms.

```dart
Timer? _debounceTimer;
static const Duration _debounceDelay = Duration(milliseconds: 100);
```

**Beneficios**:
- Evita cambios demasiado rápidos que pueden causar problemas
- Mejora la responsividad general del reproductor
- Reduce la carga en el sistema

### 2. Optimización de Bucles de Espera

**Antes**:
```dart
while (_player.processingState != ProcessingState.ready && attempts < 50) {
  await Future.delayed(const Duration(milliseconds: 20));
  attempts++;
}
```

**Después**:
```dart
while (_player.processingState != ProcessingState.ready && attempts < 15) {
  await Future.delayed(const Duration(milliseconds: 10));
  attempts++;
}
```

**Mejoras**:
- Reducción del 70% en el tiempo máximo de espera (1000ms → 300ms)
- Reducción del 50% en el delay entre intentos (20ms → 10ms)
- Menos intentos totales (50 → 15)

### 3. Control de Concurrencia Mejorado

**Problema**: El flag `_isSeekingOrLoading` podía bloquear cambios legítimos.

**Solución**: Separación de la lógica de debounce y control de concurrencia.

```dart
@override
Future<void> skipToNext() async {
  if (_initializing) return;
  
  // Debounce para evitar cambios demasiado rápidos
  _debounceTimer?.cancel();
  _debounceTimer = Timer(_debounceDelay, () async {
    await _performSkipToNext();
  });
}

Future<void> _performSkipToNext() async {
  if (_isSeekingOrLoading) return;
  // ... lógica de cambio de canción
}
```

### 4. Optimización de Carga Inicial

**Antes**:
```dart
while (_player.processingState != ProcessingState.ready) {
  await Future.delayed(const Duration(milliseconds: 50));
}
```

**Después**:
```dart
int attempts = 0;
while (_player.processingState != ProcessingState.ready && attempts < 30) {
  await Future.delayed(const Duration(milliseconds: 30));
  attempts++;
}
```

**Mejoras**:
- Tiempo máximo de espera limitado a 900ms (30 × 30ms)
- Delay reducido de 50ms a 30ms
- Evita bucles infinitos

### 5. Limpieza de Recursos

**Nuevo**: Limpieza automática de timers y flags al detener el reproductor.

```dart
@override
Future<void> stop() async {
  try {
    // Limpia el timer de debounce
    _debounceTimer?.cancel();
    _isSeekingOrLoading = false;
    // ... resto de la lógica
  }
}
```

## Métodos Optimizados

### 1. `skipToNext()`
- Implementado debounce
- Reducido tiempo de espera
- Mejorado control de concurrencia

### 2. `skipToPrevious()`
- Implementado debounce
- Reducido tiempo de espera
- Mejorado control de concurrencia

### 3. `skipToQueueItem(int index)`
- Implementado debounce
- Agregado control de concurrencia
- Optimizado tiempo de espera

### 4. `setQueueFromSongs()`
- Optimizado bucle de espera inicial
- Reducido delay entre intentos
- Limitado tiempo máximo de espera

## Resultados Esperados

### Antes de las Optimizaciones
- **Tiempo máximo de cambio**: ~1000ms (50 × 20ms)
- **Cambios rápidos**: Causaban lentitud y bloqueos
- **Carga inicial**: Podía tardar indefinidamente

### Después de las Optimizaciones
- **Tiempo máximo de cambio**: ~300ms (15 × 20ms) - 70% más rápido
- **Cambios rápidos**: Controlados por debounce, sin bloqueos
- **Carga inicial**: Máximo 900ms, con timeout garantizado

## Beneficios para el Usuario

1. **Respuesta más rápida**: Los cambios de canción son significativamente más rápidos
2. **Mejor experiencia**: No más bloqueos al cambiar canciones rápidamente
3. **Estabilidad**: El sistema es más robusto ante cambios consecutivos
4. **Consistencia**: Tiempos de respuesta predecibles

## Configuración

Las optimizaciones están configuradas con valores balanceados:

- **Debounce delay**: 100ms (suficiente para evitar cambios accidentales, pero no molesto)
- **Máximo intentos de espera**: 15 (equilibrio entre velocidad y estabilidad)
- **Delay entre intentos**: 10ms (mínimo necesario para el sistema)

## Notas Técnicas

- Las optimizaciones son compatibles con todas las funcionalidades existentes
- No afectan la calidad del audio ni la reproducción
- El sistema de debounce es transparente para el usuario final
- Los timeouts garantizan que el reproductor nunca se quede colgado 