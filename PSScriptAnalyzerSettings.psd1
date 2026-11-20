@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Outils interactifs en console : Write-Host est le bon canal (couleurs, pas de pollution du pipeline).
        'PSAvoidUsingWriteHost',
        # Fonctions internes de mise en forme : pas de ShouldProcess ni de noms au singulier imposés.
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingularNouns',
        # Les fichiers de src/ sont en UTF-8 avec BOM ; install.ps1 et uninstall.ps1 sont volontairement en ASCII pur.
        'PSUseBOMForUnicodeEncodedFile',
        # Faux positifs : les paramètres de script sont lus depuis les fonctions du même fichier.
        'PSReviewUnusedParameter'
    )
    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
