function Find-Program {
    [CmdletBinding()]
    param(
        # Name of the program to find
        [Parameter()]
        [string]
        $Name
    )

    $msg = "Searching for program $Name"
    Write-Verbose $msg
    $results = @(Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue)
    if ($results.Length -eq 0) {
        Write-Verbose "$msg - Not found"
        return $null
    }
    $first = $results[0]
    $item = Get-Item $First.Path
    Write-Verbose "$msg - Found: ${item.FullName}"
    return $item
}

function Invoke-ExternalCommand {
    [CmdletBinding(PositionalBinding = $false)]
    param(
        # Ignore the exit code and return it unchanged
        [Parameter()]
        [switch]
        $PassThruExitCode,
        # Directory in which to run the command
        [Parameter()]
        [string]
        $WorkDir,
        # Command to execute
        [Parameter(ValueFromRemainingArguments = $True, Mandatory = $True)]
        [string[]]
        $_Command,
        # Don't pipe output to the host console
        [Parameter()]
        [switch]
        $HideOutput
    )

    $ErrorActionPreference = "Stop"

    $program = $_Command[0]
    $arglist = $_Command.Clone()
    $arglist = $arglist[1..$arglist.Length]

    if (! $WorkDir) {
        $WorkDir = $PWD
    }

    Push-Location $WorkDir
    try {
        $ErrorActionPreference = "Continue"
        if ($HideOutput) {
            $output = & $program @arglist 2>&1
        }
        else {
            & $program @arglist 2>&1 | Tee-Object -Variable output | Out-Host
        }
        $retc = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = "Stop"
        Pop-Location
    }

    $stderr = $output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
    $stdout = $output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
    $stderr = $stderr -join "`n"
    $stdout = $stdout -join "`n"

    if (! $PassThruExitCode) {
        if ($retc -ne 0) {
            throw "Executing program $program failed with exit code $retc"
        }
    }
    else {
        return @{
            ExitCode = $retc;
            Output   = $stdout;
            Error    = $stderr;
        }
    }
}

function Invoke-ChronicCommand {
    [CmdletBinding()]
    param(
        # Description for the command
        [Parameter(Mandatory)]
        [string]
        $Description,
        # The command to run
        [Parameter(ValueFromRemainingArguments, Mandatory)]
        [string[]]
        $_Command_
    )

    $msg = "==> $Description"
    Write-Host $msg
    Write-Host "About to execute $_Command_"
    $closure = @{}
    $measurement = Measure-Command {
        $result = Invoke-ExternalCommand -PassThruExitCode @_Command_
        $closure.Result = $result
    }
    $result = $closure.Result
    if ($result.ExitCode -ne 0) {
        Write-Host "$msg - Failed with status $($result.ExitCode)"
        Write-Host $result.Output
        Write-Host -ForegroundColor Red $($result.Error)
        throw "Subcommand failed!"
        return
    }

    Write-Host "$msg - Success [$([math]::round($measurement.TotalSeconds, 1)) seconds]"
}

function Invoke-TestPreparation {
    param(
        # Path to CMake to use
        [string]
        $CMakePath = "cmake"
    )
    $ErrorActionPreference = "Stop"

    $repo_dir = Split-Path $PSScriptRoot -Parent
    $fakebin_src = Join-Path $repo_dir "test/fakeOutputGenerator"
    $fakebin_build = Join-Path $fakebin_src "build"
    if (Test-Path $fakebin_build) {
        Write-Verbose "Removing fakeOutputGenerator build dir: $fakebin_build"
        Remove-Item $fakebin_build -Recurse
    }

    Invoke-ChronicCommand "Configuring test utilities" $CMakePath "-H$fakebin_src" "-B$fakebin_build"
    Invoke-ChronicCommand "Building test utilities" $CMakePath --build $fakebin_build

    $fakebin_dest = Join-Path $repo_dir "test/fakebin"
    if (Test-Path $fakebin_dest) {
        Write-Verbose "Removing fakebin executable directory: $fakebin_dest"
        Remove-Item $fakebin_dest -Recurse
    }
    New-Item $fakebin_dest -ItemType Directory -Force | Out-Null

    $ext = if ($PSVersionTable.Platform -eq "Unix") { "" } else { ".exe" }
    $in_binary = (Get-ChildItem $fakebin_build -Recurse -Filter "FakeOutputGenerator$ext").FullName

    $cfg_dir = Join-Path -Path $fakebin_src -ChildPath "configfiles"
    $targets = Get-ChildItem -Path $cfg_dir -File | ForEach-Object { $_.BaseName }

    foreach ($target in $targets) {
        Copy-Item $in_binary "$fakebin_dest/$target$ext"
    }

    Copy-Item $cfg_dir/* -Destination $fakebin_dest -Recurse

}

function Invoke-VSCodeTest {
    [CmdletBinding(PositionalBinding = $false)]
    param(
        # Description for the test
        [Parameter(Position = 0, Mandatory)]
        [string]
        $Description,
        # Directory holding the test runner
        [Parameter(Mandatory)]
        [string]
        $TestsPath,
        # Directory to use as the workspace
        [Parameter(Mandatory)]
        [string]
        $Workspace
    )
    $ErrorActionPreference = "Stop"
    $node = Find-Program node
    if (! $node) {
        throw "Cannot run tests: no 'node' command found"
    }
    $repo_dir = Split-Path $PSScriptRoot -Parent
    $test_bin = Join-Path $repo_dir "/node_modules/vscode/bin/test"
    $env:CMT_TESTING = 1
    $env:CMT_QUIET_CONSOLE = 1
    $env:CODE_TESTS_PATH = $TestsPath
    $env:CODE_TESTS_WORKSPACE = $Workspace
    Invoke-ChronicCommand "Executing VSCode test: $Description" $node $test_bin
}

function Invoke-SmokeTests {
    $repo_dir = Split-Path $PSScriptRoot -Parent
    $env:CMT_SMOKE_DIR = "$repo_dir/test/smoke"
    Invoke-VSCodeTest "Smoke tests" `
        -TestsPath "$repo_dir/out/test/smoke" `
        -Workspace "$repo_dir/test/smoke/_project-dir"
}

function Invoke-MochaTest {
    [CmdletBinding(PositionalBinding = $false)]
    param(
        # Description for the test
        [Parameter(Position = 0, Mandatory)]
        [string]
        $Description
    )
    $ErrorActionPreference = "Stop"
    $repo_dir = Split-Path $PSScriptRoot -Parent
    $test_bin = Join-Path $repo_dir "/node_modules/mocha/bin/_mocha"
    $test_runner_args = @(
        "node";
        $test_bin;
        "--ui"; "tdd";
        "-r"; "ts-node/register";
        "${repo_dir}/test/backend-unit-tests/**/*.test.ts")

    $test_runner_all_args = $test_runner_args -join ' '
    Invoke-ChronicCommand "Executing VSCode test: $Description" @test_runner_args
}

