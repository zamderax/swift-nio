<#
    Runs `swift` with a configurable timeout, terminating the process if it
    exceeds the allotted time. Defaults to `swift build` with a 5-minute limit.

    Usage examples:
      .\Invoke-SwiftBuildWithTimeout.ps1
      .\Invoke-SwiftBuildWithTimeout.ps1 -TimeoutSeconds 120 build --target NIOPosix
      .\Invoke-SwiftBuildWithTimeout.ps1 test

    Parameters:
      -TimeoutSeconds: Maximum runtime in seconds (default 300).
      Remaining arguments are forwarded to `swift`. When none are supplied,
      the script runs `swift build`.
#>

[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 300,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$SwiftArguments
)

if (-not $SwiftArguments -or $SwiftArguments.Count -eq 0) {
    $SwiftArguments = @('build')
}

$workingDirectory = Get-Location
$timeoutMilliseconds = [math]::Max(1, $TimeoutSeconds * 1000)

$tempStdOut = [System.IO.Path]::GetTempFileName()
$tempStdErr = [System.IO.Path]::GetTempFileName()

try {
$process = Start-Process -FilePath 'swift' `
        -ArgumentList $SwiftArguments `
        -WorkingDirectory $workingDirectory.Path `
        -NoNewWindow `
        -PassThru `
        -RedirectStandardOutput $tempStdOut `
        -RedirectStandardError $tempStdErr

    if (-not $process) {
        throw "Failed to start swift process."
    }

    $exited = $process.WaitForExit($timeoutMilliseconds)

    if (-not $exited) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        # Ensure the process has ended before reading output.
        $null = $process.WaitForExit()
    }

$stdout = if (Test-Path $tempStdOut) { Get-Content -Path $tempStdOut -Raw -ErrorAction SilentlyContinue } else { "" }
$stderr = if (Test-Path $tempStdErr) { Get-Content -Path $tempStdErr -Raw -ErrorAction SilentlyContinue } else { "" }
$exitCode = $process.ExitCode

if ($stdout) {
    Write-Output $stdout
}
if ($stderr) {
    if ($exitCode -and $exitCode -ne 0) {
        Write-Error $stderr
    } else {
        Write-Warning $stderr
    }
}

if (-not $exited) {
    throw "swift $(($SwiftArguments -join ' ')) timed out after $TimeoutSeconds seconds"
}

if ($exitCode -and $exitCode -ne 0) {
    throw "swift exited with code $exitCode"
}
}
finally {
    Remove-Item -Path $tempStdOut, $tempStdErr -Force -ErrorAction SilentlyContinue
}
