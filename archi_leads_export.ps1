# =====================================================================
#  Archi CRM (Bitrix24)  ->  "ვერ დავუკავშირდი" leads export
#  Pipelines: 0 (Sale Leads, stage "7")  &  35 (Hot Leads, stage "C35:FINAL_INVOICE")
#  Filters deals by the DATE they MOVED INTO that stage (crm.stagehistory.list).
#  Outputs: client, creation date, last timeline comment, CURRENT stage,
#           + the exact move date that the date-filter is based on.
#  Produces an .xlsx (and a .csv) and prints a validation report.
# =====================================================================
[CmdletBinding()]
param(
  # Default = the previous full day (relative to today). Override if needed.
  [string]$DateFrom = ([DateTime]::Today.AddDays(-1).ToString('yyyy-MM-dd') + 'T00:00:00'),
  [string]$DateTo   = ([DateTime]::Today.AddDays(-1).ToString('yyyy-MM-dd') + 'T23:59:59'),
  [string]$OutDir   = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ---- Webhook endpoints (each token is scoped to user 1, crm permissions) ----
$DEAL = 'https://crm.archi.ge/rest/1/xmbjzulaie03bgxg/'   # deals / stagehistory / contacts / status
$STAT = 'https://crm.archi.ge/rest/1/yp0n11acdy148v1g/'   # crm.status.list
$TL   = 'https://crm.archi.ge/rest/1/nfy7m5s80ado9vi7/'   # crm.timeline.comment.list

# ---- Target pipelines & their "ვერ დავუკავშირდი" stage (main one only) ----
$TARGETS = @(
  [pscustomobject]@{ Type='Sale'; Pipeline='0 (Sale Leads)';  CategoryId='0';  StageId='7';                Entity='DEAL_STAGE'    },
  [pscustomobject]@{ Type='Hot';  Pipeline='35 (Hot Leads)';  CategoryId='35'; StageId='C35:FINAL_INVOICE'; Entity='DEAL_STAGE_35' }
)

# ---------------------------------------------------------------------
#  HTTP helper with retry / throttle
# ---------------------------------------------------------------------
function Invoke-Bx {
  param([string]$Url, [hashtable]$Body)
  for ($try=1; $try -le 5; $try++) {
    try {
      return Invoke-RestMethod -Uri $Url -Method Post -Body $Body -TimeoutSec 90
    } catch {
      if ($try -eq 5) { throw }
      Start-Sleep -Milliseconds (400 * $try)
    }
  }
}

# Paginate any *.list method that uses start/total (with dynamic loading)
function Get-BxAll {
  param([string]$Url, [hashtable]$Body, [string]$Activity='')
  $all = New-Object System.Collections.ArrayList
  $start = 0; $total = 0
  do {
    $Body['start'] = "$start"
    $r = Invoke-Bx -Url $Url -Body $Body
    $items = $r.result
    if ($items) { foreach ($it in $items) { [void]$all.Add($it) } }
    $total = [int]$r.total
    $start += 50
    if ($Activity) {
      $done = [Math]::Min($all.Count, [Math]::Max($total,$all.Count))
      $pct = if ($total -gt 0) { [int](100 * $done / $total) } else { 100 }
      Write-Progress -Activity $Activity -Status ("{0} / {1}" -f $done, $total) -PercentComplete ([Math]::Min($pct,100))
    }
    Start-Sleep -Milliseconds 200
  } while ($start -lt $total)
  if ($Activity) { Write-Progress -Activity $Activity -Completed }
  return ,$all
}

# Bitrix batch (<=50 sub-commands). $cmds = ordered map key -> "method?query"
function Invoke-BxBatch {
  param([string]$BaseUrl, [System.Collections.Specialized.OrderedDictionary]$Cmds)
  $body = @{ halt = '0' }
  foreach ($k in $Cmds.Keys) { $body["cmd[$k]"] = $Cmds[$k] }
  $r = Invoke-Bx -Url ($BaseUrl + 'batch.json') -Body $body
  return $r.result.result
}

function Fmt-Date { param($iso) if (-not $iso) { return '' } try { return ([DateTime]$iso).ToString('yyyy-MM-dd HH:mm') } catch { return "$iso" } }

Write-Host "Range: $DateFrom  ->  $DateTo" -ForegroundColor Cyan

# ---------------------------------------------------------------------
# 1) STATUS MAP  (current-stage name resolver)
# ---------------------------------------------------------------------
$statusRows = Get-BxAll -Url ($STAT + 'crm.status.list.json') -Body @{}
$StageName = @{}   # "ENTITY_ID|STATUS_ID" -> NAME
foreach ($s in $statusRows) { $StageName["$($s.ENTITY_ID)|$($s.STATUS_ID)"] = $s.NAME }
function Resolve-Stage {
  param($categoryId, $stageId)
  $ent = if ("$categoryId" -eq '0') { 'DEAL_STAGE' } else { "DEAL_STAGE_$categoryId" }
  $n = $StageName["$ent|$stageId"]
  if ($n) { return $n } else { return $stageId }
}

# ---------------------------------------------------------------------
# 2) STAGE HISTORY  -> deals that entered the target stage in the range
# ---------------------------------------------------------------------
$moved = @{}   # dealId -> [pscustomobject] Pipeline, MovedTime(latest in range), Hits
foreach ($t in $TARGETS) {
  Write-Host "stagehistory: cat $($t.CategoryId) stage $($t.StageId) ..." -ForegroundColor DarkCyan
  $hist = Get-BxAll -Url ($DEAL + 'crm.stagehistory.list.json') -Activity ("იტვირთება stagehistory — {0}" -f $t.Pipeline) -Body @{
    entityTypeId           = '2'
    'filter[CATEGORY_ID]'  = $t.CategoryId
    'filter[STAGE_ID]'     = $t.StageId
    'filter[>=CREATED_TIME]' = $DateFrom
    'filter[<=CREATED_TIME]' = $DateTo
    'order[CREATED_TIME]'  = 'ASC'
  }
  foreach ($h in $hist) {
    $items = $h.items
    if (-not $items) { $items = @($h) }   # safety (shape can be result.items or result[])
    foreach ($it in $items) {
      $id = "$($it.OWNER_ID)"
      $ct = $it.CREATED_TIME
      if ($moved.ContainsKey($id)) {
        $moved[$id].Hits++
        if ([DateTime]$ct -gt [DateTime]$moved[$id].MovedTime) { $moved[$id].MovedTime = $ct }
      } else {
        $moved[$id] = [pscustomobject]@{ Type=$t.Type; Pipeline=$t.Pipeline; CategoryId=$t.CategoryId; MovedTime=$ct; Hits=1 }
      }
    }
  }
}
$dealIds = @($moved.Keys)
Write-Host ("Unique deals that entered the stage in range: {0}" -f $dealIds.Count) -ForegroundColor Green
if ($dealIds.Count -eq 0) { Write-Host "Nothing to export."; return }

# ---------------------------------------------------------------------
# 3) DEAL DETAILS  (current stage, title, client refs, create date)
# ---------------------------------------------------------------------
$DEAL_SELECT = 'ID','TITLE','CATEGORY_ID','STAGE_ID','DATE_CREATE','CONTACT_ID','COMPANY_ID','ASSIGNED_BY_ID','UF_CRM_1700569256804'
$deals = @{}
for ($i=0; $i -lt $dealIds.Count; $i += 50) {
  $chunk = $dealIds[$i..([Math]::Min($i+49,$dealIds.Count-1))]
  $body = @{ 'order[ID]'='ASC' }
  for ($j=0;$j -lt $chunk.Count;$j++){ $body["filter[ID][$j]"]=$chunk[$j] }
  for ($j=0;$j -lt $DEAL_SELECT.Count;$j++){ $body["select[$j]"]=$DEAL_SELECT[$j] }
  $r = Invoke-Bx -Url ($DEAL + 'crm.deal.list.json') -Body $body
  foreach ($d in $r.result) { $deals["$($d.ID)"] = $d }
  Write-Progress -Activity 'იტვირთება დილების დეტალები' -Status ("{0} / {1}" -f $deals.Count,$dealIds.Count) -PercentComplete ([int](100*$deals.Count/$dealIds.Count))
  Start-Sleep -Milliseconds 200
}
Write-Progress -Activity 'იტვირთება დილების დეტალები' -Completed
Write-Host ("Deals fetched: {0}" -f $deals.Count) -ForegroundColor Green

# ---------------------------------------------------------------------
# 4) CLIENT NAMES  (contacts + companies)
# ---------------------------------------------------------------------
$contactIds = $deals.Values | Where-Object { $_.CONTACT_ID -and "$($_.CONTACT_ID)" -ne '0' } | ForEach-Object { "$($_.CONTACT_ID)" } | Sort-Object -Unique
$companyIds = $deals.Values | Where-Object { $_.COMPANY_ID -and "$($_.COMPANY_ID)" -ne '0' } | ForEach-Object { "$($_.COMPANY_ID)" } | Sort-Object -Unique

$contacts = @{}
for ($i=0; $i -lt $contactIds.Count; $i += 50) {
  $chunk = $contactIds[$i..([Math]::Min($i+49,$contactIds.Count-1))]
  $body = @{}
  for ($j=0;$j -lt $chunk.Count;$j++){ $body["filter[ID][$j]"]=$chunk[$j] }
  'ID','NAME','LAST_NAME','SECOND_NAME','PHONE' | ForEach-Object -Begin {$k=0} -Process { $body["select[$k]"]=$_; $k++ }
  $r = Invoke-Bx -Url ($DEAL + 'crm.contact.list.json') -Body $body
  foreach ($c in $r.result) {
    $name = (@($c.NAME,$c.SECOND_NAME,$c.LAST_NAME) | Where-Object { $_ -and "$_".Trim() } ) -join ' '
    $phone = ''
    if ($c.PHONE) { $phone = ($c.PHONE | ForEach-Object { $_.VALUE }) -join ', ' }
    $contacts["$($c.ID)"] = [pscustomobject]@{ Name=$name.Trim(); Phone=$phone }
  }
  Write-Progress -Activity 'იტვირთება კლიენტები (კონტაქტები)' -Status ("{0} / {1}" -f $contacts.Count,$contactIds.Count) -PercentComplete ([int](100*[Math]::Min($i+50,$contactIds.Count)/[Math]::Max($contactIds.Count,1)))
  Start-Sleep -Milliseconds 200
}
Write-Progress -Activity 'იტვირთება კლიენტები (კონტაქტები)' -Completed

$companies = @{}
if ($companyIds.Count) {
  for ($i=0; $i -lt $companyIds.Count; $i += 50) {
    $chunk = $companyIds[$i..([Math]::Min($i+49,$companyIds.Count-1))]
    $body = @{}
    for ($j=0;$j -lt $chunk.Count;$j++){ $body["filter[ID][$j]"]=$chunk[$j] }
    'ID','TITLE' | ForEach-Object -Begin {$k=0} -Process { $body["select[$k]"]=$_; $k++ }
    $r = Invoke-Bx -Url ($DEAL + 'crm.company.list.json') -Body $body
    foreach ($c in $r.result) { $companies["$($c.ID)"] = $c.TITLE }
    Start-Sleep -Milliseconds 200
  }
}

# ---------------------------------------------------------------------
# 5) LAST TIMELINE COMMENT  (batched, 50 deals / request)
# ---------------------------------------------------------------------
$lastComment = @{}
$ids = @($deals.Keys)
for ($i=0; $i -lt $ids.Count; $i += 50) {
  $chunk = $ids[$i..([Math]::Min($i+49,$ids.Count-1))]
  $cmds = [ordered]@{}
  foreach ($id in $chunk) {
    $cmds["k$id"] = "crm.timeline.comment.list?filter[ENTITY_TYPE]=deal&filter[ENTITY_ID]=$id&order[CREATED]=DESC&select[0]=COMMENT&select[1]=CREATED&select[2]=AUTHOR_ID"
  }
  $res = Invoke-BxBatch -BaseUrl $TL -Cmds $cmds
  foreach ($id in $chunk) {
    $arr = $res."k$id"
    if ($arr -and $arr.Count -gt 0) {
      $c = $arr[0]
      $txt = "$($c.COMMENT)" -replace '<[^>]+>',' ' -replace '\s+',' '
      $lastComment["$id"] = [pscustomobject]@{ Text=$txt.Trim(); When=$c.CREATED }
    }
  }
  $doneTl = [Math]::Min($i+50,$ids.Count)
  Write-Progress -Activity 'იტვირთება ბოლო კომენტარები (timeline)' -Status ("{0} / {1}" -f $doneTl,$ids.Count) -PercentComplete ([int](100*$doneTl/[Math]::Max($ids.Count,1)))
  Start-Sleep -Milliseconds 250
}
Write-Progress -Activity 'იტვირთება ბოლო კომენტარები (timeline)' -Completed

# ---------------------------------------------------------------------
# 6) BUILD ROWS
# ---------------------------------------------------------------------
$rows = foreach ($id in ($deals.Keys | Sort-Object {[int]$_})) {
  $d = $deals[$id]
  $client = ''
  if ($d.CONTACT_ID -and $contacts.ContainsKey("$($d.CONTACT_ID)")) {
    $client = $contacts["$($d.CONTACT_ID)"].Name
    $ph = $contacts["$($d.CONTACT_ID)"].Phone
  } elseif ($d.COMPANY_ID -and $companies.ContainsKey("$($d.COMPANY_ID)")) {
    $client = $companies["$($d.COMPANY_ID)"]; $ph=''
  } else { $ph='' }
  if (-not $client) { $client = $d.TITLE }
  $cm = $lastComment["$id"]
  [pscustomobject]@{
    'Deal ID'              = $id
    'ტიპი (Hot/Sale)'     = $moved[$id].Type
    'კლიენტი'             = $client
    'ტელეფონი'           = $ph
    'FB Name (კამპანია)'  = $d.UF_CRM_1700569256804
    'პაიფლაინი'          = $moved[$id].Pipeline
    'შექმნის თარიღი'      = (Fmt-Date $d.DATE_CREATE)
    'ვერ დავუკავშირდი-ზე გადასვლა' = (Fmt-Date $moved[$id].MovedTime)
    'ამჟამინდელი ეტაპი'   = (Resolve-Stage $d.CATEGORY_ID $d.STAGE_ID)
    'ბოლო კომენტარი'      = $(if ($cm) { $cm.Text } else { '' })
    'კომენტარის თარიღი'   = $(if ($cm) { (Fmt-Date $cm.When) } else { '' })
  }
}

# ---------------------------------------------------------------------
# 7) EXPORT  -> XLSX (inline strings, UTF-8)  +  CSV (UTF-8 BOM)
# ---------------------------------------------------------------------
function ConvertTo-Xlsx {
  param([object[]]$Data, [string]$Path, [string]$SheetName='Leads')
  Add-Type -AssemblyName System.IO.Compression | Out-Null
  Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
  $cols = $Data[0].PSObject.Properties.Name
  function ColLetter([int]$n){ $s=''; $n++; while($n -gt 0){ $m=($n-1)%26; $s=[char](65+$m)+$s; $n=[int][Math]::Floor(($n-1)/26) }; $s }
  function Esc([string]$t){ if($null -eq $t){return ''}; ($t -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]','') -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
  [void]$sb.Append('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>')
  # header
  [void]$sb.Append('<row r="1">')
  for($c=0;$c -lt $cols.Count;$c++){ [void]$sb.Append('<c r="'+(ColLetter $c)+'1" t="inlineStr"><is><t xml:space="preserve">'+(Esc $cols[$c])+'</t></is></c>') }
  [void]$sb.Append('</row>')
  $rIdx=2
  foreach($row in $Data){
    [void]$sb.Append('<row r="'+$rIdx+'">')
    for($c=0;$c -lt $cols.Count;$c++){
      $val = "$($row.($cols[$c]))"
      [void]$sb.Append('<c r="'+(ColLetter $c)+$rIdx+'" t="inlineStr"><is><t xml:space="preserve">'+(Esc $val)+'</t></is></c>')
    }
    [void]$sb.Append('</row>'); $rIdx++
  }
  [void]$sb.Append('</sheetData></worksheet>')
  $sheetXml = $sb.ToString()

  $contentTypes = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>'
  $rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>'
  $workbook = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="'+(Esc $SheetName)+'" sheetId="1" r:id="rId1"/></sheets></workbook>'
  $wbRels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>'

  if (Test-Path $Path) { Remove-Item $Path -Force }
  $fs = [System.IO.File]::Open($Path,[System.IO.FileMode]::CreateNew)
  $zip = New-Object System.IO.Compression.ZipArchive($fs,[System.IO.Compression.ZipArchiveMode]::Create)
  $enc = New-Object System.Text.UTF8Encoding($false)
  function AddEntry($zip,$name,$text,$enc){
    $e=$zip.CreateEntry($name,[System.IO.Compression.CompressionLevel]::Optimal)
    $w=New-Object System.IO.StreamWriter($e.Open(),$enc); $w.Write($text); $w.Flush(); $w.Dispose()
  }
  AddEntry $zip '[Content_Types].xml' $contentTypes $enc
  AddEntry $zip '_rels/.rels' $rels $enc
  AddEntry $zip 'xl/workbook.xml' $workbook $enc
  AddEntry $zip 'xl/_rels/workbook.xml.rels' $wbRels $enc
  AddEntry $zip 'xl/worksheets/sheet1.xml' $sheetXml $enc
  $zip.Dispose(); $fs.Dispose()
}

$stamp = $DateFrom.Substring(0,10)
$xlsx = Join-Path $OutDir "archi_ver_davukavshirdi_$stamp.xlsx"
$csv  = Join-Path $OutDir "archi_ver_davukavshirdi_$stamp.csv"
ConvertTo-Xlsx -Data $rows -Path $xlsx -SheetName 'ვერ დავუკავშირდი'
$rows | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------------------
# 8) VALIDATION REPORT
# ---------------------------------------------------------------------
Write-Host "`n==================== VALIDATION ====================" -ForegroundColor Yellow
Write-Host ("Date range filtered (move into stage): {0}  ->  {1}" -f $DateFrom,$DateTo)
$inRange = $rows | Where-Object { $mt=[DateTime]$moved[$_.'Deal ID'].MovedTime; $mt -ge [DateTime]$DateFrom -and $mt -le [DateTime]$DateTo }
Write-Host ("Rows total: {0}   | rows whose move-time is INSIDE range: {1}" -f $rows.Count,$inRange.Count)
$outRange = $rows.Count - $inRange.Count
Write-Host ("Rows OUTSIDE range (must be 0): {0}" -f $outRange) -ForegroundColor $(if($outRange -eq 0){'Green'}else{'Red'})

Write-Host "`nCurrent-stage distribution (deals may have moved on since):" -ForegroundColor Yellow
$rows | Group-Object 'ამჟამინდელი ეტაპი' | Sort-Object Count -Descending | ForEach-Object { "  {0,-40} {1}" -f $_.Name,$_.Count }

Write-Host "`nPer-pipeline counts:" -ForegroundColor Yellow
$rows | Group-Object 'პაიფლაინი' | ForEach-Object { "  {0,-20} {1}" -f $_.Name,$_.Count }

Write-Host "`nProof sample (full stage history of 3 deals -> shows the 'ვერ დავუკავშირდი' entry lands in range):" -ForegroundColor Yellow
$sample = ($rows | Select-Object -First 3)
foreach ($s in $sample) {
  $id = $s.'Deal ID'
  $h = Invoke-Bx -Url ($DEAL+'crm.stagehistory.list.json') -Body @{ entityTypeId='2'; 'filter[OWNER_ID]'=$id; 'order[CREATED_TIME]'='ASC' }
  Write-Host ("  Deal {0}  ({1})  current='{2}'" -f $id,$s.'კლიენტი',$s.'ამჟამინდელი ეტაპი') -ForegroundColor Cyan
  foreach ($it in $h.result.items) {
    $mark = if ($it.STAGE_ID -in @('7','C35:FINAL_INVOICE')) { '  <== ვერ დავუკავშირდი' } else { '' }
    "      {0}  ->  {1}{2}" -f (Fmt-Date $it.CREATED_TIME), (Resolve-Stage $it.CATEGORY_ID $it.STAGE_ID), $mark
  }
}

Write-Host "`nSaved:" -ForegroundColor Green
Write-Host "  $xlsx"
Write-Host "  $csv"
