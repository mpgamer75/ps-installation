$scriptContent = @'
function Format-FileSize {
    param([long]$Size)
    if ($Size -gt 1TB) { return "{0:N2} TB" -f ($Size / 1TB) }
    if ($Size -gt 1GB) { return "{0:N2} GB" -f ($Size / 1GB) }
    if ($Size -gt 1MB) { return "{0:N2} MB" -f ($Size / 1MB) }
    if ($Size -gt 1KB) { return "{0:N2} KB" -f ($Size / 1KB) }
    return "$Size B"
}

function Format-Bar {
    param (
        [double]$Percent,
        [int]$Length = 20
    )
    $filled = [math]::Round($Percent * $Length / 100)
    $empty = $Length - $filled
    $bar = "█" * $filled + "░" * $empty
    return $bar
}

function Get-CPUUsage {
    try {
        $cpu = (Get-CimInstance Win32_Processor).LoadPercentage
        if ($null -eq $cpu) {
            return 0
        }
        return [int]$cpu
    }
    catch {
        return 0
    }
}

function Show-Monitor {
    # Informations système
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor
    $cs = Get-CimInstance Win32_ComputerSystem
    
    while ($true) {
        Clear-Host
        $currentTime = Get-Date

        # En-tête
        Write-Host "=== MONITEUR SYSTÈME ===" -ForegroundColor Cyan
        Write-Host "Mise à jour: $($currentTime.ToString('HH:mm:ss'))" -ForegroundColor DarkGray
        Write-Host "$($os.Caption)" -ForegroundColor Yellow
        Write-Host "CPU: $($cpu.Name)" -ForegroundColor Yellow
        Write-Host "Cores: $($cpu.NumberOfCores) Physiques / $($cpu.NumberOfLogicalProcessors) Logiques`n" -ForegroundColor Yellow

        # CPU Usage
        $cpuLoad = Get-CPUUsage
        $cpuColor = if ($cpuLoad -gt 90) { "Red" } elseif ($cpuLoad -gt 70) { "Yellow" } else { "Green" }
        Write-Host "CPU Usage: " -NoNewline
        Write-Host "$cpuLoad% " -NoNewline -ForegroundColor $cpuColor
        Write-Host (Format-Bar -Percent $cpuLoad) -ForegroundColor $cpuColor

        # Mémoire
        $memoryUsed = $cs.TotalPhysicalMemory - $os.FreePhysicalMemory * 1KB
        $memoryPercent = [math]::Round(($memoryUsed / $cs.TotalPhysicalMemory) * 100, 1)
        $memColor = if ($memoryPercent -gt 90) { "Red" } elseif ($memoryPercent -gt 70) { "Yellow" } else { "Green" }
        
        Write-Host "Mémoire: " -NoNewline
        Write-Host "$memoryPercent% " -NoNewline -ForegroundColor $memColor
        Write-Host "$(Format-Bar -Percent $memoryPercent) " -NoNewline -ForegroundColor $memColor
        Write-Host "($(Format-FileSize $memoryUsed) / $(Format-FileSize $cs.TotalPhysicalMemory))"

        # Disques
        Write-Host "`nDisques:" -ForegroundColor Cyan
        Get-WmiObject Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
            $freeSpace = $_.FreeSpace
            $totalSpace = $_.Size
            $usedSpace = $totalSpace - $freeSpace
            $usedPercent = [math]::Round(($usedSpace / $totalSpace) * 100, 1)
            $diskColor = if ($usedPercent -gt 90) { "Red" } elseif ($usedPercent -gt 70) { "Yellow" } else { "Green" }
            
            Write-Host "$($_.DeviceID) " -NoNewline
            Write-Host "$usedPercent% " -NoNewline -ForegroundColor $diskColor
            Write-Host (Format-Bar -Percent $usedPercent) -ForegroundColor $diskColor
            Write-Host "  $(Format-FileSize $freeSpace) libres sur $(Format-FileSize $totalSpace)" -ForegroundColor DarkGray
        }

        # Réseau
        Write-Host "`nRéseau:" -ForegroundColor Cyan
        Get-NetAdapter | Where-Object Status -eq 'Up' | ForEach-Object {
            try {
                $stats = $_ | Get-NetAdapterStatistics -ErrorAction SilentlyContinue
                Write-Host "$($_.Name) ($($_.LinkSpeed))" -ForegroundColor Yellow
                if ($stats) {
                    Write-Host "  ↑ $(Format-FileSize $stats.SentBytes) " -NoNewline -ForegroundColor Green
                    Write-Host "↓ $(Format-FileSize $stats.ReceivedBytes)" -ForegroundColor Blue
                }
            } catch {
                Write-Host "  Statistiques non disponibles" -ForegroundColor DarkGray
            }
        }

        # Processus les plus gourmands
        Write-Host "`nProcessus (Top 5):" -ForegroundColor Cyan
        Get-Process | Sort-Object CPU -Descending | Select-Object -First 5 | ForEach-Object {
            $procColor = if ($_.CPU -gt 50) { "Red" } elseif ($_.CPU -gt 20) { "Yellow" } else { "Green" }
            Write-Host "$($_.ProcessName) " -NoNewline
            Write-Host "CPU: $([math]::Round($_.CPU, 1))% " -NoNewline -ForegroundColor $procColor
            Write-Host "MEM: $(Format-FileSize $_.WorkingSet64)" -ForegroundColor Cyan
        }

        # Services critiques
        Write-Host "`nServices critiques:" -ForegroundColor Cyan
        $criticalServices = @(
            @{Name='wuauserv'; Display='Windows Update'},
            @{Name='MpsSvc'; Display='Pare-feu Windows Defender'},
            @{Name='WinDefend'; Display='Service antivirus Microsoft Defender'}
        )
        
        foreach ($service in $criticalServices) {
            $status = Get-Service -Name $service.Name -ErrorAction SilentlyContinue
            if ($status) {
                $statusColor = if ($status.Status -eq 'Running') { "Green" } else { "Red" }
                Write-Host "$($service.Display): " -NoNewline
                Write-Host $status.Status -ForegroundColor $statusColor
            }
        }

        Write-Host "`nAppuyez sur 'Q' pour quitter, autre touche pour rafraîchir" -ForegroundColor DarkGray

        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq "Q") {
                break
            }
        }

        Start-Sleep -Seconds 2
    }
}

# Démarrer le moniteur
Show-Monitor
'@

function Install-MonitorPackage {
    try {
        # Créer le dossier de destination s'il n'existe pas
        $installPath = "C:\Program Files\WindowsPowerShell\Scripts"
        if (-not (Test-Path $installPath)) {
            New-Item -ItemType Directory -Path $installPath -Force | Out-Null
        }

        # Installe le script
        $scriptFile = Join-Path $installPath "monitor.ps1"
        Set-Content -Path $scriptFile -Value $scriptContent

        # Créer le fichier .cmd
        $cmdContent = @"
@echo off
powershell -ExecutionPolicy Bypass -File "$scriptFile" %*
"@
        $cmdFile = Join-Path $installPath "monitor.cmd"
        Set-Content -Path $cmdFile -Value $cmdContent

        # Met à jour le PATH si nécessaire
        $currentPath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
        if ($currentPath -notlike "*$installPath*") {
            [Environment]::SetEnvironmentVariable("PATH", "$currentPath;$installPath", "Machine")
        }

        Write-Host "Le paquet monitor a été installé avec succès!" -ForegroundColor Green
        Write-Host "Tapez 'monitor' dans PowerShell pour l'utiliser." -ForegroundColor Yellow
        return $true
    }
    catch {
        Write-Error "Erreur lors de l'installation de monitor: $_"
        return $false
    }
}

# Exécute l'installation
Install-MonitorPackage