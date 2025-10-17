# Script para verificar alignment de librerías .so
$objdump = "$env:LOCALAPPDATA\Android\Sdk\ndk\29.0.14206865\toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-objdump.exe"
$tempDir = Get-ChildItem -Path "$env:TEMP\apk_extract_*" -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName

Write-Host ""
Write-Host "=== Verificando alineamiento de 16KB en librerias .so ===" -ForegroundColor Cyan
Write-Host ""

$hasIssues = $false
$soFiles = Get-ChildItem -Path $tempDir -Recurse -Filter "*.so"

foreach ($so in $soFiles) {
    Write-Host "Verificando: $($so.Name) ($($so.Directory.Name))" -ForegroundColor Yellow
    
    $output = & $objdump -p $so.FullName 2>&1 | Select-String "LOAD"
    $alignments = @()
    
    foreach ($line in $output) {
        if ($line -match 'align 2\*\*(\d+)') {
            $alignPower = [int]$matches[1]
            $alignBytes = [math]::Pow(2, $alignPower)
            $alignments += $alignPower
            
            if ($alignPower -ge 14) {
                $sizeKB = [math]::Round($alignBytes/1024)
                Write-Host "  OK align 2**$alignPower = $($sizeKB)KB" -ForegroundColor Green
            } else {
                Write-Host "  ERROR align 2**$alignPower = $alignBytes bytes (< 16KB)" -ForegroundColor Red
                $hasIssues = $true
            }
        }
    }
    
    if ($alignments.Count -eq 0) {
        Write-Host "  ADVERTENCIA: No se pudo verificar el alineamiento" -ForegroundColor Yellow
    }
    
    Write-Host ""
}

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

if ($hasIssues) {
    Write-Host "ERROR: Algunas librerias NO tienen alineamiento de 16KB" -ForegroundColor Red
    Write-Host "Estas librerias necesitan ser recompiladas" -ForegroundColor Yellow
} else {
    Write-Host "EXITO: Todas las librerias tienen alineamiento correcto de 16KB!" -ForegroundColor Green
}

Write-Host ""

