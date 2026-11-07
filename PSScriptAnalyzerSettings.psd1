# PSScriptAnalyzer settings for CI (.github/workflows/ci.yml). Every rule runs except these, each excluded on purpose:
@{
    ExcludeRules = @(
        # The installer and the tests talk to a person at a console; Write-Host with colors is the interface.
        'PSAvoidUsingWriteHost',
        # Small internal helpers (Write-QkFileBytes $path $bytes, Remove-QkTreeSafely $path) read better positionally.
        'PSAvoidUsingPositionalParameters',
        # These are installer scripts, not a module: there is no -WhatIf mode to offer, and the helpers that change
        # state are only called after the user ran install.ps1 / uninstall.ps1 and accepted the UAC prompt.
        'PSUseShouldProcessForStateChangingFunctions',
        # Get-QkPaths, Initialize-QkLogFolders, New-QkTaskDefinitions ... return several things by design.
        'PSUseSingularNouns'
    )
}
