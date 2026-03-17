# PSScriptAnalyzer settings for DFIR-Updater
# https://github.com/PowerShell/PSScriptAnalyzer
#
# Usage:
#   Invoke-ScriptAnalyzer -Path . -Settings .\PSScriptAnalyzerSettings.psd1 -Recurse

@{
    # ── Severity levels to report ────────────────────────────────────────────
    Severity = @('Error', 'Warning', 'Information')

    # ── Rules to exclude ─────────────────────────────────────────────────────
    # These are intentionally excluded because they are too noisy or
    # inappropriate for this project's architecture.
    ExcludeRules = @(
        # This project uses Install-*, Remove-*, etc. without ShouldProcess
        # on many lightweight wrappers. The main Install-ToolUpdate already
        # supports ShouldProcess where it matters.
        'PSUseShouldProcessForStateChangingFunctions'

        # WPF GUI code uses $_ extensively in event handlers and short
        # pipelines where an explicit variable name reduces readability.
        'PSReviewUnusedParameter'

        # The GUI script dot-sources modules and uses script-scope variables
        # extensively. These are by design, not accidental globals.
        'PSAvoidGlobalVars'

        # Many helper functions are intentionally simple and do not need
        # full cmdlet binding. Suppressing this avoids hundreds of warnings.
        'PSUseCmdletCorrectly'

        # Write-Host is used intentionally for diagnostic console output
        # alongside the WPF GUI (the [DIAG] messages).
        'PSAvoidUsingWriteHost'

        # ConvertTo-SecureString with -AsPlainText is not used, but the
        # rule can false-positive on GitHub token handling.
        'PSAvoidUsingConvertToSecureStringWithPlainText'
    )

    # ── Rules to include (all others are included by default) ────────────────
    # Explicitly listing important security and correctness rules ensures
    # they remain active even if defaults change in future versions.
    IncludeRules = @(
        # Security: catch plaintext credentials and hardcoded passwords
        'PSAvoidUsingPlainTextForPassword'
        'PSAvoidUsingUsernameAndPasswordParams'

        # Security: avoid Invoke-Expression which can execute arbitrary code
        'PSAvoidUsingInvokeExpression'

        # Security: prefer -LiteralPath over -Path to avoid wildcard injection
        'PSUseLiteralPath'

        # Correctness: detect common mistakes
        'PSUseApprovedVerbs'
        'PSAvoidUsingEmptyCatchBlock'
        'PSUseDeclaredVarsMoreThanAssignments'
        'PSAvoidDefaultValueSwitchParameter'
        'PSAvoidUsingPositionalParameters'
        'PSMisleadingBacktick'
        'PSMissingModuleManifestField'
        'PSPossibleIncorrectComparisonWithNull'
        'PSPossibleIncorrectUsageOfAssignmentOperator'
        'PSPossibleIncorrectUsageOfRedirectionOperator'

        # Best practices
        'PSUseOutputTypeCorrectly'
        'PSProvideCommentHelp'
        'PSAvoidUsingCmdletAliases'
        'PSAvoidTrailingWhitespace'
        'PSUseConsistentIndentation'
        'PSUseConsistentWhitespace'
        'PSAlignAssignmentStatement'
    )

    # ── Rule-specific configuration ──────────────────────────────────────────
    Rules = @{
        PSUseConsistentIndentation = @{
            Enable          = $true
            IndentationSize = 4
            Kind            = 'space'
            # Do not enforce pipeline indentation - the codebase uses both styles
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
        }

        PSUseConsistentWhitespace = @{
            Enable                          = $true
            CheckInnerBrace                 = $true
            CheckOpenBrace                  = $true
            CheckOpenParen                  = $true
            CheckOperator                   = $false  # Too noisy with alignment-style assignments
            CheckPipe                       = $true
            CheckPipeForRedundantWhitespace = $false
            CheckSeparator                  = $true
        }

        PSAlignAssignmentStatement = @{
            Enable         = $true
            CheckHashtable = $true
        }

        PSProvideCommentHelp = @{
            Enable                  = $true
            ExportedOnly            = $true
            Placement               = 'begin'
            BlockComment            = $true
        }

        PSAvoidUsingCmdletAliases = @{
            # Allow common, universally-understood aliases
            AllowList = @('cd', 'cls', 'select', 'where', 'foreach', 'sort')
        }
    }
}
