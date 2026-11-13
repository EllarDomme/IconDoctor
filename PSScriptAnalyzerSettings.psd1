@{
    # Rules we deliberately suppress, with the reason. Keeping this list
    # short and justified is the point: everything else must stay clean.
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The CLI is a console UI; Write-Host is the intended renderer.
        'PSAvoidUsingWriteHost'

        # -Scan / -Diagnose / -Fix are switch parameters that select a
        # parameter set; they are read via $PSCmdlet.ParameterSetName.
        'PSReviewUnusedParameter'

        # Repair functions expose -WhatIf explicitly because several of them
        # are also called programmatically from Invoke-IconRepair, where the
        # CmdletBinding WhatIf plumbing would be re-entrant.
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseSupportsShouldProcess'

        # "IconTargets" is the domain term for the set of shortcuts scanned.
        'PSUseSingularNouns'

        # Cleanup paths use empty catch blocks on purpose: a failed temp-file
        # deletion must never abort a repair.
        'PSAvoidUsingEmptyCatchBlock'
    )
}
