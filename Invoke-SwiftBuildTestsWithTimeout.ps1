<#
    Runs `swift build --build-tests` with a configurable timeout, terminating
    the process if it exceeds the allotted time. Defaults to a 5-minute limit.

    Usage examples:
      .\Invoke-SwiftBuildTestsWithTimeout.ps1
      .\Invoke-SwiftBuildTestsWithTimeout.ps1 -TimeoutSeconds 120 --product NIOFS

    Parameters:
      -TimeoutSeconds: Maximum runtime in seconds (default 300).
      Remaining arguments are forwarded after `swift build --build-tests`.
#>

[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 300,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$AdditionalArguments
)

$swiftArguments = @('build', '--build-tests')
if ($AdditionalArguments) {
    $swiftArguments += $AdditionalArguments
}

$invokeScript = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-SwiftBuildWithTimeout.ps1'

& $invokeScript -TimeoutSeconds $TimeoutSeconds @swiftArguments
