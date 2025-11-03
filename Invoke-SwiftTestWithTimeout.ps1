<#
    Runs `swift test` with an optional `--filter` argument under a configurable
    timeout. If the invocation exceeds the allotted time the process is
    terminated. Defaults to a 5-minute limit.

    Usage examples:
      .\Invoke-SwiftTestWithTimeout.ps1
      .\Invoke-SwiftTestWithTimeout.ps1 -Filter NIOFoundationCompatTests
      .\Invoke-SwiftTestWithTimeout.ps1 -TimeoutSeconds 120 -Filter '^NIO.*' --skip-build

    Parameters:
      -TimeoutSeconds: Maximum runtime in seconds (default 300).
      -Filter: Pattern to pass to `swift test --filter`.
      Remaining arguments are forwarded after any filter options.
#>

[CmdletBinding()]
param(
[int]$TimeoutSeconds = 300,
[string]$Filter,
[Parameter(ValueFromRemainingArguments = $true)]
[string[]]$AdditionalArguments
)

# Always make sure tests are built first (no timeout).
swift build --build-tests

# Construct the test invocation; we always skip the build because the
# compilation was done above.
$swiftTestArguments = @('test', '--skip-build')

if ($Filter) {
    $swiftTestArguments += @('--filter', $Filter)
}

if ($AdditionalArguments) {
    $swiftTestArguments += $AdditionalArguments
}

$invokeScript = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-SwiftBuildWithTimeout.ps1'

& $invokeScript -TimeoutSeconds $TimeoutSeconds @swiftTestArguments
