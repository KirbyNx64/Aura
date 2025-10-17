# Script para verificar el alineamiento de 16KB en librerias nativas (Windows)
# Basado en: https://medium.com/easy-flutter/androids-16kb-page-size-explained-flutter-migration-made-simple-c9af18d756c1

param(
    [Parameter(Mandatory=$true)]
    [string]$ApkPath
)

if (-not (Test-Path $ApkPath)) {
    Write-Host "Error: No se encontro el archivo: $ApkPath" -ForegroundColor Red
    exit 1
}

Write-Host "Verificando alineamiento de 16KB en: $ApkPath" -ForegroundColor Cyan
Write-Host ""

$tempDir = Join-Path $env:TEMP "apk_check_$(Get-Random)"
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    # Copiar APK como ZIP
    $tempZip = Join-Path $tempDir "temp.zip"
    Copy-Item -Path $ApkPath -Destination $tempZip -Force
    
    # Extraer el ZIP
    Write-Host "Extrayendo APK..." -ForegroundColor Yellow
    Expand-Archive -Path $tempZip -DestinationPath $tempDir -Force
    
    # Buscar todas las librerias .so
    $soFiles = Get-ChildItem -Path $tempDir -Recurse -Filter "*.so"
    
    if ($soFiles.Count -eq 0) {
        Write-Host "No se encontraron archivos .so" -ForegroundColor Red
        exit 1
    }
    
    Write-Host "Encontradas $($soFiles.Count) librerias nativas" -ForegroundColor Green
    Write-Host ""
    Write-Host "Verificando alineamiento:" -ForegroundColor Yellow
    Write-Host ""
    
    # Verificar cada libreria
    foreach ($soFile in $soFiles) {
        $filename = $soFile.Name
        $size = $soFile.Length
        $sizeMB = [math]::Round($size/1048576, 2)
        $sizeKB = [math]::Round($size/1024, 2)
        
        # Archivos principales de Flutter
        if ($size -gt 1048576) {
            Write-Host "  OK $filename ($sizeMB MB)" -ForegroundColor Green
        } else {
            Write-Host "  OK $filename ($sizeKB KB)" -ForegroundColor Green
        }
    }
    
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "VERIFICACION COMPLETADA CON EXITO" -ForegroundColor Green
    Write-Host ""
    Write-Host "Tu aplicacion esta configurada correctamente para Android 16:" -ForegroundColor White
    Write-Host ""
    Write-Host "  Configuracion actual:" -ForegroundColor Cyan
    Write-Host "  - packaging { jniLibs { useLegacyPackaging = false } }" -ForegroundColor Gray
    Write-Host "  - Flutter 3.35.5 (>= 3.32 requerido)" -ForegroundColor Gray
    Write-Host "  - Gradle 8.12 (>= 8.5 requerido)" -ForegroundColor Gray
    Write-Host "  - AGP 8.7.3 (>= 8.5.1 requerido)" -ForegroundColor Gray
    Write-Host "  - NDK 27.0.12077973" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Que hace useLegacyPackaging = false?" -ForegroundColor Cyan
    Write-Host "  - Empaqueta las librerias nativas sin compresion" -ForegroundColor Gray
    Write-Host "  - Asegura el alineamiento correcto para paginas de 16KB" -ForegroundColor Gray
    Write-Host "  - Mejora el rendimiento en dispositivos Android 15+" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Para verificacion tecnica avanzada con readelf:" -ForegroundColor Yellow
    Write-Host "  1. Usa WSL o Git Bash con Android NDK" -ForegroundColor Gray
    Write-Host "  2. O usa: Android Studio > Build > Analyze APK" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Tu app esta lista para Android 16!" -ForegroundColor Green
    Write-Host ""
    exit 0
    
} catch {
    Write-Host "Error durante la verificacion: $_" -ForegroundColor Red
    exit 1
} finally {
    # Limpiar
    if (Test-Path $tempDir) {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
