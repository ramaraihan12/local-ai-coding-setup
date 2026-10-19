@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Interactive console scripts: colored status lines are the point, nothing pipes their output.
        'PSAvoidUsingWriteHost',
        # env.ps1 and lib-ollama.ps1 are dot-sourced; their variables are used by the calling script.
        'PSUseDeclaredVarsMoreThanAssignments',
        # Script-local helpers (Start-AiWindow, Stop-WithError, ...), not exported cmdlets.
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingularNouns',
        # Best-effort probes (window title, port owner lookup, optional API calls) where a miss is fine.
        'PSAvoidUsingEmptyCatchBlock'
    )
}
