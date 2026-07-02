[CmdletBinding()]
param(
    [ValidateSet('unit', 'official-smoke', 'official-i', 'official-m',
                 'official-csr', 'official', 'all')]
    [string]$Mode = 'unit',
    [int]$MaxCycles = 100000,
    [switch]$ContinueOnFailure,
    [switch]$Trace,
    [string]$QuestaBin = 'F:\questasim64_2024.1\win64'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ResultRoot = Join-Path $RepoRoot 'results'
$RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$RunDir = Join-Path $ResultRoot "$RunStamp-$Mode"
$RtlDir = Join-Path $RepoRoot 'rtl\core'
$TestDir = Join-Path $RepoRoot 'test'
$HexDir = Join-Path $RepoRoot 'hex\riscv-tests'
$WorkDir = Join-Path $RepoRoot 'work'
$Vlib = Join-Path $QuestaBin 'vlib.exe'
$Vlog = Join-Path $QuestaBin 'vlog.exe'
$Vsim = Join-Path $QuestaBin 'vsim.exe'

$UnitTests = @(
    'tb_rename_state', 'tb_rename_stage', 'tb_rob', 'tb_dispatch',
    'tb_id_decode_m', 'tb_physical_regfile', 'tb_issue_queue', 'tb_lsq',
    'tb_execute_stage', 'tb_lsu_four_cycle', 'tb_csr_file',
    'tb_writeback_commit_stage', 'tb_backend_datapath', 'tb_backend_control',
    'tb_core_single_instruction', 'tb_core_branch_instructions',
    'tb_core_alu_instructions', 'tb_core_subword_memory',
    'tb_core_rv32m_instructions', 'tb_core_csr_system_instructions',
    'tb_core_exception_fence', 'tb_core_combo_dual_issue',
    'tb_core_combo_long_div', 'tb_core_combo_memory',
    'tb_core_combo_branch_recovery', 'tb_core_combo_trap_interrupt',
    'tb_core_combo_fence_i_smc'
)

$RtlSources = @(
    'core_port_pkg.sv', 'backend_top.sv', 'core_top.sv', 'dispatch.sv',
    'id_decode_pkg.sv', 'if_stage.sv', 'id_stage.sv', 'issue_queue.sv',
    'issue_queue_pair.sv', 'lsq.sv', 'issue1_arbiter.sv',
    'operand_read_stage.sv', 'alu_unit.sv', 'bru_unit.sv', 'csr_unit.sv',
    'lsu_unit.sv', 'mlu_unit.sv', 'execute_stage.sv', 'writeback_stage.sv',
    'csr_commit_buffer.sv', 'csr_file.sv', 'commit_controller.sv',
    'writeback_commit_stage.sv', 'free_list.sv', 'rat_rrat.sv',
    'busy_table.sv', 'rename_stage.sv', 'physical_regfile.sv', 'rob.sv'
) | ForEach-Object { Join-Path $RtlDir $_ }

function Invoke-NativeLogged {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$LogPath
    )
    & $Executable @Arguments 2>&1 |
        Tee-Object -FilePath $LogPath |
        ForEach-Object { Write-Host $_ }
    $nativeExitCode = $LASTEXITCODE
    return $nativeExitCode
}

function Assert-Toolchain {
    foreach ($tool in @($Vlib, $Vlog, $Vsim)) {
        if (!(Test-Path -LiteralPath $tool)) {
            throw "QuestaSim executable not found: $tool"
        }
    }
}

function Assert-HexIndexIntegrity {
    $indexPath = Join-Path $HexDir 'index.csv'
    $rows = @(Import-Csv -LiteralPath $indexPath)
    $indexedFiles = @{}
    foreach ($row in $rows) {
        $path = Join-Path $HexDir $row.merged_hex_file
        if (!(Test-Path -LiteralPath $path)) {
            throw "Indexed HEX is missing: $path"
        }
        $indexedFiles[$row.merged_hex_file.ToLowerInvariant()] = $true
    }
    foreach ($file in Get-ChildItem -LiteralPath $HexDir -Filter '*.hex' -File) {
        if (!$indexedFiles.ContainsKey($file.Name.ToLowerInvariant())) {
            throw "HEX exists but is absent from index.csv: $($file.FullName)"
        }
    }
    return $rows
}

function Compile-Regression {
    if (!(Test-Path -LiteralPath $WorkDir)) {
        $code = Invoke-NativeLogged $Vlib @($WorkDir) (Join-Path $RunDir 'vlib.log')
        if ($code -ne 0) { throw "vlib failed with exit code $code" }
    }

    $testSources = @(Get-ChildItem -LiteralPath $TestDir -Filter '*.sv' -File |
                     Sort-Object Name | ForEach-Object { $_.FullName })
    $args = @('-sv', '-work', $WorkDir, "+incdir+$RtlDir") +
            $RtlSources + $testSources
    $compileLog = Join-Path $RunDir 'compile.log'
    $code = Invoke-NativeLogged $Vlog $args $compileLog
    if ($code -ne 0) { throw "vlog failed with exit code $code" }
    $compileText = Get-Content -LiteralPath $compileLog -Raw
    if ($compileText -notmatch '(?m)Errors:\s+0,\s+Warnings:\s+0') {
        throw 'Compilation did not report 0 Errors, 0 Warnings; see compile.log'
    }
}

function New-OfficialSelection {
    param([object[]]$Rows)
    $allowed = @($Rows | Where-Object {
        (($_.test -like 'rv32ui-p-*') -and ($_.test -ne 'rv32ui-p-ma_data')) -or
        ($_.test -like 'rv32um-p-*') -or ($_.test -eq 'rv32mi-p-csr')
    })
    switch ($Mode) {
        'official-smoke' {
            $smoke = @()
            foreach ($name in @('rv32ui-p-simple', 'rv32ui-p-add', 'rv32ui-p-addi')) {
                $smoke += @($allowed | Where-Object { $_.test -eq $name })
            }
            return $smoke
        }
        'official-i'   { return @($allowed | Where-Object { $_.test -like 'rv32ui-p-*' }) }
        'official-m'   { return @($allowed | Where-Object { $_.test -like 'rv32um-p-*' }) }
        'official-csr' { return @($allowed | Where-Object { $_.test -eq 'rv32mi-p-csr' }) }
        default        { return $allowed }
    }
}

function Get-SkipReason {
    param([string]$Name)
    if ($Name -eq 'rv32ui-p-ma_data') { return 'misaligned data unsupported' }
    if ($Name -eq 'rv32mi-p-mcsr') { return 'extended machine CSR coverage deferred' }
    if ($Name -like 'rv32uf-p-*') { return 'RV32F not implemented' }
    if ($Name -like 'rv32uzba-p-*') { return 'Zba not implemented' }
    return 'outside current official allowlist'
}

function Invoke-Simulation {
    param(
        [string]$Name,
        [string]$Top,
        [string[]]$PlusArgs = @()
    )
    $safeName = $Name -replace '[^A-Za-z0-9_.-]', '_'
    $logPath = Join-Path $RunDir "$safeName.log"
    $wavePath = Join-Path $RunDir "$safeName.wlf"
    $do = "log -r /$Top/*; run -all; quit -f"
    $args = @('-c', '-voptargs=+acc', '-onfinish', 'exit', '-wlf', $wavePath,
              '-do', $do, "work.$Top") + $PlusArgs
    $code = Invoke-NativeLogged $Vsim $args $logPath
    $text = Get-Content -LiteralPath $logPath -Raw
    $cycles = ''
    if ($text -match 'REGRESSION_RESULT\s+(?:PASS|FAIL|TIMEOUT).*?cycles=(\d+)') {
        $cycles = $Matches[1]
    }

    $status = 'FAIL'
    if ($text -match 'REGRESSION_RESULT\s+TIMEOUT') {
        $status = 'TIMEOUT'
    } elseif (($Top -eq 'tb_official_hex_regression') -and
              ($text -match 'REGRESSION_RESULT\s+PASS') -and ($code -eq 0)) {
        $status = 'PASS'
    } elseif (($Top -ne 'tb_official_hex_regression') -and
              ($text -match '(?m)^#?\s*PASS:') -and ($code -eq 0)) {
        $status = 'PASS'
    }
    return [pscustomobject]@{
        Test = $Name; Status = $status; Cycles = $cycles
        ExitCode = $code; Log = $logPath; Wave = $wavePath; Reason = ''
    }
}

Assert-Toolchain
New-Item -ItemType Directory -Path $RunDir -Force | Out-Null
Push-Location $RepoRoot
try {
    Compile-Regression
    $results = @()

    if ($Mode -in @('unit', 'all')) {
        foreach ($top in $UnitTests) {
            Write-Host "[RUN ] $top"
            $result = Invoke-Simulation $top $top
            $results += $result
            Write-Host ("[{0}] {1}" -f $result.Status.PadRight(4), $top)
            if (($result.Status -ne 'PASS') -and !$ContinueOnFailure) { break }
        }
    }

    $unitFailed = @($results | Where-Object { $_.Status -ne 'PASS' }).Count -gt 0
    if (($Mode -ne 'unit') -and (!$unitFailed -or $ContinueOnFailure)) {
        $rows = @(Assert-HexIndexIntegrity)
        $selected = @(New-OfficialSelection $rows)
        foreach ($row in $selected) {
            $hexPath = (Resolve-Path (Join-Path $HexDir $row.merged_hex_file)).Path
            $plusArgs = @("+HEX=$hexPath", "+TEST=$($row.test)",
                          "+MAX_CYCLES=$MaxCycles")
            if ($Trace) { $plusArgs += '+TRACE' }
            Write-Host "[RUN ] $($row.test)"
            $result = Invoke-Simulation $row.test 'tb_official_hex_regression' $plusArgs
            $results += $result
            Write-Host ("[{0}] {1} cycles={2}" -f
                        $result.Status.PadRight(7), $row.test, $result.Cycles)
            if (($result.Status -ne 'PASS') -and !$ContinueOnFailure) { break }
        }

        if ($Mode -in @('official', 'all')) {
            $selectedNames = @($selected | ForEach-Object { $_.test })
            foreach ($row in $rows | Where-Object { $_.test -notin $selectedNames }) {
                $results += [pscustomobject]@{
                    Test = $row.test; Status = 'SKIP'; Cycles = ''; ExitCode = 0
                    Log = ''; Wave = ''; Reason = (Get-SkipReason $row.test)
                }
            }
        }
    }

    $summaryPath = Join-Path $RunDir 'summary.csv'
    $results | Export-Csv -LiteralPath $summaryPath -NoTypeInformation -Encoding UTF8
    $counts = $results | Group-Object Status | Sort-Object Name
    Write-Host ''
    Write-Host "Regression mode: $Mode"
    foreach ($count in $counts) { Write-Host "$($count.Name): $($count.Count)" }
    Write-Host "Summary: $summaryPath"

    if (@($results | Where-Object { $_.Status -in @('FAIL', 'TIMEOUT') }).Count -gt 0) {
        exit 1
    }
    exit 0
} finally {
    Pop-Location
}
