# Mede o Cawde num Windows de verdade (CI): memória e CPU só com o ícone, com o popover aberto e depois de fechá-lo.
# Conta o processo do Cawde e todos os filhos (inclusive o WebView2). Escreve no resumo do GitHub Actions e
# tira um print da tela com o popover aberto.
param([string]$Exe = "target/release/cawde.exe", [int]$IdleBudgetMB = 60, [double]$IdleCpuBudget = 1.0)
$ErrorActionPreference = "Stop"

function Tree($root) {
    $all = Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name, WorkingSetSize, PrivatePageCount
    $ids = @($root); $found = $true
    while ($found) {
        $found = $false
        foreach ($p in $all) { if ($ids -contains $p.ParentProcessId -and -not ($ids -contains $p.ProcessId)) { $ids += $p.ProcessId; $found = $true } }
    }
    $all | Where-Object { $ids -contains $_.ProcessId }
}
function Measure-Tree($root, $label) {
    $procs = Tree $root
    $mb = [math]::Round((($procs | Measure-Object WorkingSetSize -Sum).Sum) / 1MB, 1)
    $private = [math]::Round((($procs | Measure-Object PrivatePageCount -Sum).Sum) / 1MB, 1)
    $names = ($procs | Group-Object Name | ForEach-Object { "$($_.Name)×$($_.Count)" }) -join ", "
    "| $label | $private MB | $mb MB | $($procs.Count) | $names |"
    return $private
}
function Cpu-Percent($proc, $seconds) {
    $proc.Refresh(); $a = $proc.TotalProcessorTime.TotalSeconds
    Start-Sleep $seconds
    $proc.Refresh(); $b = $proc.TotalProcessorTime.TotalSeconds
    [math]::Round(($b - $a) / $seconds * 100, 2)
}
function Screenshot($path) {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bmp = New-Object Drawing.Bitmap $b.Width, $b.Height
        [Drawing.Graphics]::FromImage($bmp).CopyFromScreen($b.Location, [Drawing.Point]::Empty, $b.Size)
        $bmp.Save($path)
    } catch { Write-Host "print indisponível: $_" }
}

$cawde = Start-Process $Exe -PassThru
Start-Sleep 20
$rows = @("| Momento | Memória privada | Working set (soma) | Processos | Quais |", "|---|---|---|---|---|")
$r = Measure-Tree $cawde.Id "Só o ícone (20 s após abrir)"; $rows += $r[0]; $idle = $r[1]
$idleCpu = Cpu-Percent $cawde 20
& $Exe --popover; Start-Sleep 10
$r = Measure-Tree $cawde.Id "Popover aberto"; $rows += $r[0]
$webviews = @(Tree $cawde.Id | Where-Object { $_.Name -like "msedgewebview2*" }).Count
Screenshot "popover.png"
& $Exe --close-popover; Start-Sleep 10
$r = Measure-Tree $cawde.Id "Popover fechado de novo"; $rows += $r[0]
# O painel com uma conversa de exemplo (sem Claude no CI): mede e fotografa.
& $Exe --demo --panel; Start-Sleep 12
$r = Measure-Tree $cawde.Id "Painel aberto (conversa de exemplo)"; $rows += $r[0]
$panelViews = @(Tree $cawde.Id | Where-Object { $_.Name -like "msedgewebview2*" }).Count
Screenshot "panel.png"
& $Exe --close-panel; Start-Sleep 10
$r = Measure-Tree $cawde.Id "Painel fechado de novo"; $rows += $r[0]
Stop-Process -Id $cawde.Id -Force -ErrorAction SilentlyContinue

$summary = @("## Leveza do Cawde no Windows", "", $rows, "", "CPU parado (só o ícone, 20 s): **$idleCpu%** de um núcleo", "",
             "Orçamento: até $IdleBudgetMB MB e $IdleCpuBudget% de CPU só com o ícone.") | ForEach-Object { $_ }
$summary -join "`n" | Out-File -Append -Encoding utf8 $env:GITHUB_STEP_SUMMARY
$summary -join "`n" | Write-Host
if ($panelViews -eq 0) { Write-Host "::error::O painel não abriu (nenhum processo do WebView2 com ele aberto)"; exit 1 }
if ($webviews -eq 0) { Write-Host "::error::O popover não abriu (nenhum processo do WebView2 com ele aberto)"; exit 1 }
if ($idle -gt $IdleBudgetMB) { Write-Host "::error::Só com o ícone o Cawde usa $idle MB (orçamento: $IdleBudgetMB MB)"; exit 1 }
if ($idleCpu -gt $IdleCpuBudget) { Write-Host "::error::Parado, o Cawde usa $idleCpu% de CPU (orçamento: $IdleCpuBudget%)"; exit 1 }
