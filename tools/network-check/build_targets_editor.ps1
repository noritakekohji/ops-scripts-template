#Requires -Version 5.1
<#
.SYNOPSIS
    Build targets-editor.xlsm from targets-editor.bas via Excel COM.
.DESCRIPTION
    Creates the "Targets" sheet (headers, sample rows, validation, export
    button), imports the VBA module, and saves as .xlsm.
    Requires: Excel installed + "Trust access to the VBA project object model"
    enabled (File > Options > Trust Center > Macro Settings).
.NOTES
    Exit codes: 0=success, 5=build failure, 10=Excel/VBOM not available
#>
[CmdletBinding()]
param(
    [string]$OutputPath = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# NOTE: $PSScriptRoot can be empty during param default evaluation on some
# PS5.1 hosts, so resolve paths here instead of in the param block.
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrEmpty($OutputPath)) {
    $OutputPath = Join-Path $scriptDir 'targets-editor.xlsm'
}
# SaveAs resolves relative paths against EXCEL.EXE's CWD, not ours.
$OutputPath = [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).Path, $OutputPath))

$wb = $null
$basPath = Join-Path $scriptDir 'targets-editor.bas'
if (-not (Test-Path $basPath)) {
    Write-Error "targets-editor.bas not found: $basPath" -ErrorAction Continue
    exit 5
}

try {
    $excel = New-Object -ComObject Excel.Application
} catch {
    Write-Host "[ERROR] Excel COM not available. Install Excel to build the xlsm."
    exit 10
}

$excel.Visible = $false
$excel.DisplayAlerts = $false

try {
    $wb = $excel.Workbooks.Add()
    $ws = $wb.Worksheets.Item(1)
    $ws.Name = 'Targets'

    # --- headers ---
    $headers = @('Enabled', 'Section', 'Host', 'Port', 'Expected', 'Description')
    for ($i = 0; $i -lt $headers.Count; $i++) {
        $cell = $ws.Cells.Item(1, $i + 1)
        $cell.Value2 = $headers[$i]
        $cell.Font.Bold = $true
        $cell.Interior.Color = 0xD9D9D9
    }
    $ws.Columns.Item(1).ColumnWidth = 9    # Enabled
    $ws.Columns.Item(2).ColumnWidth = 18   # Section
    $ws.Columns.Item(3).ColumnWidth = 28   # Host
    $ws.Columns.Item(4).ColumnWidth = 8    # Port
    $ws.Columns.Item(5).ColumnWidth = 10   # Expected
    $ws.Columns.Item(6).ColumnWidth = 44   # Description
    $excel.ActiveWindow.SplitRow = 1
    $excel.ActiveWindow.FreezePanes = $true

    # NOTE: validations must be added BEFORE cells get NumberFormat '@'.
    # Adding a custom-formula validation to text-formatted cells fails with
    # COM error 0x800A03EC; the validation survives a later format change.

    # --- data validation: Enabled = on / off (rows 2..500) ---
    $enabledRange = $ws.Range('A2:A500')
    $enabledRange.Validation.Add(3, 1, 1, 'on,off') | Out-Null   # xlValidateList
    $enabledRange.Validation.IgnoreBlank = $true
    $enabledRange.Validation.InCellDropdown = $true

    # --- data validation: Expected = ok / ng / - (rows 2..500) ---
    $expectedRange = $ws.Range('E2:E500')
    $expectedRange.Validation.Add(3, 1, 1, 'ok,ng,-') | Out-Null   # xlValidateList
    $expectedRange.Validation.IgnoreBlank = $true
    $expectedRange.Validation.InCellDropdown = $true

    # --- data validation: Port = 1-65535 or '-' (custom formula; cells are text) ---
    $portRange = $ws.Range('D2:D500')
    $portFormula = '=OR(D2="-",D2="",AND(ISNUMBER(--D2),--D2>=1,--D2<=65535))'
    $portRange.Validation.Add(7, 1, 1, $portFormula) | Out-Null   # xlValidateCustom
    $portRange.Validation.IgnoreBlank = $true
    $portRange.Validation.ErrorMessage = "Port must be 1-65535 or '-'"

    # --- sample rows (the 3 'on' rows match tests/fixtures/targets_editor_export_sample.lst) ---
    $samples = @(
        @('on',  'Local',    '127.0.0.1', '-',     'ok', 'Localhost ping'),
        @('on',  'Local',    '127.0.0.1', '65535', 'ng', 'Unused high port (should be closed)'),
        @('on',  'No eval',  '127.0.0.1', '-',     '-',  'Localhost (no evaluation)'),
        @('off', 'Disabled', '203.0.113.1', '443', 'ok', 'Example of a disabled row (excluded from export)')
    )
    for ($r = 0; $r -lt $samples.Count; $r++) {
        for ($c = 0; $c -lt 6; $c++) {
            # NumberFormat @ keeps '-' and ports as literal text
            $ws.Cells.Item($r + 2, $c + 1).NumberFormat = '@'
            $ws.Cells.Item($r + 2, $c + 1).Value2 = $samples[$r][$c]
        }
    }

    # --- import VBA module (requires VBOM trust) ---
    try {
        $wb.VBProject.VBComponents.Import($basPath) | Out-Null
    } catch {
        Write-Host "[ERROR] Cannot access VBProject. Enable: File > Options >"
        Write-Host "        Trust Center > Macro Settings > 'Trust access to the"
        Write-Host "        VBA project object model', then re-run."
        exit 10
    }

    # --- export button ---
    $btn = $ws.Buttons().Add(380, 4, 120, 24)
    $btn.Text = 'Export targets.lst'
    $btn.OnAction = 'ExportTargets'

    # --- save as .xlsm (FileFormat 52 = xlOpenXMLWorkbookMacroEnabled) ---
    if (Test-Path $OutputPath) { Remove-Item -Force $OutputPath }
    $wb.SaveAs($OutputPath, 52)
    Write-Host "[OK] Built: $OutputPath"
    exit 0
} catch {
    Write-Host "[ERROR] Build failed: $($_.Exception.Message)"
    Write-Host "[ERROR] At: $($_.InvocationInfo.PositionMessage)"
    exit 5
} finally {
    if ($null -ne $wb)    { $wb.Close($false) }
    $excel.Quit()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($excel)
}
