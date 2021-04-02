[CmdletBinding(SupportsShouldProcess)]
param(
)
$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSVersion.Major -lt 6) {
    throw "This script requires at least powershell 6"
}

$REPO_DIR = Split-Path $PSScriptRoot -Parent
$Package = Get-Content (Join-Path $REPO_DIR "package.json") | ConvertFrom-Json
$CMakeToolsVersion = $Package.version

# Import the utility modules
Import-Module (Join-Path $PSScriptRoot "cmt.psm1")

# Build the fake compilers
Invoke-TestPreparation

#
# Run tests
#
Invoke-MochaTest "CMake Tools: Backend tests"

Invoke-SmokeTests

Invoke-VSCodeTest "CMake Tools: Unit tests" `
    -TestsPath "$REPO_DIR/out/test/unit-tests" `
    -Workspace "$REPO_DIR/test/unit-tests/test-project-without-cmakelists"

foreach ($name in @("successful-build"; "single-root-UI"; )) {
    Invoke-VSCodeTest "CMake Tools: $name" `
        -TestsPath "$REPO_DIR/out/test/extension-tests/$name" `
        -Workspace "$REPO_DIR/test/extension-tests/$name/project-folder"
}

foreach ($name in @("multi-root-UI"; )) {
    Invoke-VSCodeTest "CMake Tools: $name" `
        -TestsPath "$REPO_DIR/out/test/extension-tests/$name" `
        -Workspace "$REPO_DIR/test/extension-tests/$name/project-workspace.code-workspace"
}
