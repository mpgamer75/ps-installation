# Garantit l'encodage UTF-8 avec BOM des scripts de src/ et tests/ (requis par Windows PowerShell 5.1).
#   pwsh -File build/Add-Bom.ps1
$root = Split-Path -Parent $PSScriptRoot
$bom = New-Object System.Text.UTF8Encoding $true
Get-ChildItem -Path (Join-Path $root 'src'), (Join-Path $root 'tests') -Recurse -Filter '*.ps1' | ForEach-Object {
    $text = [IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8).TrimStart([char]0xFEFF) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($_.FullName, $text, $bom)
}
