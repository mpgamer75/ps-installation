$scriptContent = @'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$reminderDataPath = "$env:USERPROFILE\AppData\Local\RemindSystem"
$reminderFile = "$reminderDataPath\reminders.json"

# Création du dossier de données s'il n'existe pas
if (-not (Test-Path $reminderDataPath)) {
    New-Item -ItemType Directory -Path $reminderDataPath -Force | Out-Null
}

function Load-Reminders {
    if (Test-Path $reminderFile) {
        $reminders = Get-Content $reminderFile | ConvertFrom-Json
        return $reminders
    }
    return @()
}

function Save-Reminders {
    param($reminders)
    $reminders | ConvertTo-Json | Set-Content $reminderFile
}

function Show-Notification {
    param (
        [string]$Title,
        [string]$Message
    )
    
    $notification = New-Object System.Windows.Forms.NotifyIcon
    $notification.Icon = [System.Drawing.SystemIcons]::Information
    $notification.BalloonTipTitle = $Title
    $notification.BalloonTipText = $Message
    $notification.Visible = $true
    $notification.ShowBalloonTip(10000)
}

function Add-Reminder {
    Clear-Host
    Write-Host "=== AJOUTER UN RAPPEL ===" -ForegroundColor Cyan

    # Titre du rappel
    Write-Host "`nQuel est votre rappel ?" -ForegroundColor Yellow
    $title = Read-Host "Titre"

    # Date du rappel
    $dateValid = $false
    do {
        Write-Host "`nQuand souhaitez-vous être rappelé ?" -ForegroundColor Yellow
        Write-Host "Format: JJ/MM/AAAA (exemple: 25/12/2024)"
        $dateStr = Read-Host "Date"
        
        if ($dateStr -match "^\d{2}/\d{2}/\d{4}$") {
            try {
                $date = [DateTime]::ParseExact($dateStr, "dd/MM/yyyy", $null)
                $dateValid = $true
            }
            catch {
                Write-Host "Date invalide!" -ForegroundColor Red
            }
        }
        else {
            Write-Host "Format de date incorrect!" -ForegroundColor Red
        }
    } while (-not $dateValid)

    # Heure du rappel
    $timeValid = $false
    do {
        Write-Host "`nÀ quelle heure ?" -ForegroundColor Yellow
        Write-Host "Format: HH:MM (exemple: 14:30)"
        $timeStr = Read-Host "Heure"
        
        if ($timeStr -match "^\d{2}:\d{2}$") {
            try {
                $time = [DateTime]::ParseExact($timeStr, "HH:mm", $null)
                $dateTime = $date.Date.Add($time.TimeOfDay)
                $timeValid = $true
            }
            catch {
                Write-Host "Heure invalide!" -ForegroundColor Red
            }
        }
        else {
            Write-Host "Format d'heure incorrect!" -ForegroundColor Red
        }
    } while (-not $timeValid)

    # Créer le rappel
    $reminder = @{
        Title = $title
        DateTime = $dateTime.ToString("O")
        Completed = $false
        Id = [Guid]::NewGuid().ToString()
    }

    # Charger et sauvegarder les rappels
    $reminders = Load-Reminders
    $reminders += $reminder
    Save-Reminders $reminders

    # Créer une tâche planifiée
    $action = New-ScheduledTaskAction `
        -Execute "PowerShell.exe" `
        -Argument "-WindowStyle Hidden -Command `"[System.Windows.Forms.MessageBox]::Show('$title', 'Rappel!', 'OK', 'Information')`""
    
    $trigger = New-ScheduledTaskTrigger -Once -At $dateTime
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun
    Register-ScheduledTask -TaskName "Reminder_$($reminder.Id)" -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

    Write-Host "`nRappel créé avec succès!" -ForegroundColor Green
    Write-Host "Titre: $title" -ForegroundColor Yellow
    Write-Host "Date et heure: $($dateTime.ToString('dd/MM/yyyy HH:mm'))" -ForegroundColor Yellow
}

function Show-Reminders {
    Clear-Host
    Write-Host "=== RAPPELS ACTIFS ===" -ForegroundColor Cyan
    
    $reminders = Load-Reminders
    $activeReminders = $reminders | Where-Object { -not $_.Completed }
    
    if ($activeReminders.Count -eq 0) {
        Write-Host "`nAucun rappel actif." -ForegroundColor Yellow
        Start-Sleep -Seconds 2
        return
    }

    $index = 1
    foreach ($reminder in $activeReminders) {
        $dateTime = [DateTime]::Parse($reminder.DateTime)
        $timeLeft = $dateTime - (Get-Date)
        
        Write-Host "`n$index. $($reminder.Title)" -ForegroundColor Green
        Write-Host "   Prévu le: $($dateTime.ToString('dd/MM/yyyy HH:mm'))" -ForegroundColor Gray
        
        if ($timeLeft.TotalMinutes -gt 0) {
            Write-Host "   Dans: $([math]::Floor($timeLeft.TotalHours))h$($timeLeft.Minutes)m" -ForegroundColor Cyan
        }
        else {
            Write-Host "   En retard de: $([math]::Abs([math]::Floor($timeLeft.TotalHours)))h$([math]::Abs($timeLeft.Minutes))m" -ForegroundColor Red
        }
        
        $index++
    }

    Write-Host "`nOptions:" -ForegroundColor Yellow
    Write-Host "1. Marquer comme terminé"
    Write-Host "2. Supprimer"
    Write-Host "3. Retour"

    $choice = Read-Host "`nVotre choix"
    switch ($choice) {
        "1" {
            $reminderIndex = Read-Host "Numéro du rappel à terminer"
            if ($reminderIndex -match '^\d+$' -and [int]$reminderIndex -le $activeReminders.Count) {
                $reminder = $activeReminders[[int]$reminderIndex - 1]
                $reminder.Completed = $true
                Save-Reminders $reminders
                Unregister-ScheduledTask -TaskName "Reminder_$($reminder.Id)" -Confirm:$false
                Write-Host "Rappel marqué comme terminé!" -ForegroundColor Green
            }
        }
        "2" {
            $reminderIndex = Read-Host "Numéro du rappel à supprimer"
            if ($reminderIndex -match '^\d+$' -and [int]$reminderIndex -le $activeReminders.Count) {
                $reminder = $activeReminders[[int]$reminderIndex - 1]
                $reminders = $reminders | Where-Object { $_.Id -ne $reminder.Id }
                Save-Reminders $reminders
                Unregister-ScheduledTask -TaskName "Reminder_$($reminder.Id)" -Confirm:$false
                Write-Host "Rappel supprimé!" -ForegroundColor Green
            }
        }
    }
}

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host "=== SYSTÈME DE RAPPELS ===" -ForegroundColor Cyan
        Write-Host "`nOptions:" -ForegroundColor Yellow
        Write-Host "1. Créer un nouveau rappel"
        Write-Host "2. Voir les rappels actifs"
        Write-Host "3. Quitter"

        $choice = Read-Host "`nVotre choix"
        switch ($choice) {
            "1" { Add-Reminder }
            "2" { Show-Reminders }
            "3" { return }
        }
    }
}

# Vérifier si on a les droits admin pour les tâches planifiées
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")
if (-not $isAdmin) {
    Write-Host "Attention: Certaines fonctionnalités nécessitent des droits administrateur" -ForegroundColor Yellow
}

# Démarrer le programme
Show-Menu
'@

function Install-RemindPackage {
    try {
        # Créer le dossier de destination s'il n'existe pas
        $installPath = "C:\Program Files\WindowsPowerShell\Scripts"
        if (-not (Test-Path $installPath)) {
            New-Item -ItemType Directory -Path $installPath -Force | Out-Null
        }

        # Installer le script
        $scriptFile = Join-Path $installPath "remind.ps1"
        Set-Content -Path $scriptFile -Value $scriptContent

        # Créer le fichier .cmd
        $cmdContent = @"
@echo off
powershell -ExecutionPolicy Bypass -File "$scriptFile" %*
"@
        $cmdFile = Join-Path $installPath "remind.cmd"
        Set-Content -Path $cmdFile -Value $cmdContent

        # Mettre à jour le PATH si nécessaire
        $currentPath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
        if ($currentPath -notlike "*$installPath*") {
            [Environment]::SetEnvironmentVariable("PATH", "$currentPath;$installPath", "Machine")
        }

        Write-Host "Le paquet remind a été installé avec succès!" -ForegroundColor Green
        Write-Host "Tapez 'remind' dans PowerShell pour l'utiliser." -ForegroundColor Yellow
        return $true
    }
    catch {
        Write-Error "Erreur lors de l'installation de remind: $_"
        return $false
    }
}

# Exécuter l'installation
Install-RemindPackage