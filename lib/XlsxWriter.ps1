# Minimal multi-sheet .xlsx writer (Office Open XML). No Excel / Python required.

function ConvertTo-XlsxCellRef {
    param([int]$Col, [int]$Row)
    $n = $Col
    $name = ""
    while ($n -gt 0) {
        $n--
        $name = [char](65 + ($n % 26)) + $name
        $n = [math]::Floor($n / 26)
    }
    return "$name$Row"
}

function Escape-XmlText([string]$Text) {
    if ($null -eq $Text) { return "" }
    return ($Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
}

function Write-Utf8File {
    param([string]$LiteralPath, [string]$Content)
    $dir = Split-Path -Parent $LiteralPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($LiteralPath, $Content, $utf8NoBom)
}

# Theme -> style index for data cells (header uses theme+1)
# 0=default, 1=header bold, 2=cpu, 3=cpuHdr, 4=gpu, 5=gpuHdr, 6=mem, 7=memHdr, 8=disk, 9=diskHdr
function Get-ThemeStyleIds {
    param([string]$Theme)
    switch ($Theme) {
        "cpu"  { return @{ Data = 2; Header = 3 } }
        "gpu"  { return @{ Data = 4; Header = 5 } }
        "mem"  { return @{ Data = 6; Header = 7 } }
        "disk" { return @{ Data = 8; Header = 9 } }
        default { return @{ Data = 0; Header = 1 } }
    }
}

function New-XlsxSheetXml {
    param(
        [string[][]]$Rows,
        [string]$Theme = ""
    )
    $ids = Get-ThemeStyleIds -Theme $Theme
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$sb.Append('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">')
    [void]$sb.Append('<sheetData>')
    $rowList = @($Rows)
    for ($r = 0; $r -lt $rowList.Count; $r++) {
        $rowNum = $r + 1
        $row = @($rowList[$r])
        $styleId = if ($r -eq 0) { $ids.Header } else { $ids.Data }
        [void]$sb.Append("<row r=`"$rowNum`">")
        for ($c = 0; $c -lt $row.Count; $c++) {
            $ref = ConvertTo-XlsxCellRef -Col ($c + 1) -Row $rowNum
            $val = if ($null -eq $row[$c]) { "" } else { [string]$row[$c] }
            [void]$sb.Append("<c r=`"$ref`" t=`"inlineStr`" s=`"$styleId`"><is><t>")
            [void]$sb.Append((Escape-XmlText $val))
            [void]$sb.Append('</t></is></c>')
        }
        [void]$sb.Append('</row>')
    }
    [void]$sb.Append('</sheetData></worksheet>')
    return $sb.ToString()
}

function Export-XlsxWorkbook {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        # OrderedDictionary: SheetName -> either string[][] rows, or @{ Rows=...; Theme='cpu'|'gpu'|'mem'|'disk' }
        [Parameter(Mandatory = $true)]
        $Sheets
    )

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("xlsx_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $tmp "_rels") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $tmp "xl") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $tmp "xl\_rels") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $tmp "xl\worksheets") | Out-Null

    $contentTypes = New-Object System.Text.StringBuilder
    [void]$contentTypes.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$contentTypes.Append('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">')
    [void]$contentTypes.Append('<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>')
    [void]$contentTypes.Append('<Default Extension="xml" ContentType="application/xml"/>')
    [void]$contentTypes.Append('<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>')
    [void]$contentTypes.Append('<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>')

    $wb = New-Object System.Text.StringBuilder
    [void]$wb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$wb.Append('<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">')
    [void]$wb.Append('<sheets>')

    $rels = New-Object System.Text.StringBuilder
    [void]$rels.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$rels.Append('<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">')

    $i = 1
    foreach ($name in $Sheets.Keys) {
        $rawName = [string]$name
        $safeName = ($rawName -replace '[\\/*?:\[\]]', '_')
        if ($safeName.Length -gt 31) { $safeName = $safeName.Substring(0, 31) }
        $sheetFile = "sheet$i.xml"
        $entry = $Sheets[$name]
        $theme = ""
        $rows = $entry
        if ($entry -is [hashtable] -or $entry -is [System.Collections.Specialized.OrderedDictionary]) {
            if ($entry.Contains("Rows")) {
                $rows = $entry.Rows
                if ($entry.Contains("Theme")) { $theme = [string]$entry.Theme }
            }
        }
        $xml = New-XlsxSheetXml -Rows $rows -Theme $theme
        Write-Utf8File -LiteralPath (Join-Path $tmp "xl\worksheets\$sheetFile") -Content $xml
        [void]$contentTypes.Append("<Override PartName=`"/xl/worksheets/$sheetFile`" ContentType=`"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml`"/>")
        [void]$wb.Append("<sheet name=`"$(Escape-XmlText $safeName)`" sheetId=`"$i`" r:id=`"rId$i`"/>")
        [void]$rels.Append("<Relationship Id=`"rId$i`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet`" Target=`"worksheets/$sheetFile`"/>")
        $i++
    }
    [void]$rels.Append("<Relationship Id=`"rId$i`" Type=`"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles`" Target=`"styles.xml`"/>")
    [void]$rels.Append('</Relationships>')
    [void]$wb.Append('</sheets></workbook>')
    [void]$contentTypes.Append('</Types>')

    # fills: 0 none, 1 gray125 (required), 2 cpu, 3 cpuHdr, 4 gpu, 5 gpuHdr, 6 mem, 7 memHdr, 8 disk, 9 diskHdr
    $styles = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <fonts count="3">
    <font><sz val="11"/><color rgb="FF000000"/><name val="Microsoft YaHei"/><family val="2"/></font>
    <font><b/><sz val="11"/><color rgb="FF000000"/><name val="Microsoft YaHei"/><family val="2"/></font>
    <font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Microsoft YaHei"/><family val="2"/></font>
  </fonts>
  <fills count="10">
    <fill><patternFill patternType="none"/></fill>
    <fill><patternFill patternType="gray125"/></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFDDEBF7"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FF5B9BD5"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFE2EFDA"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FF70AD47"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFFCE4D6"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFED7D31"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFFFF2CC"/><bgColor indexed="64"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFFFC000"/><bgColor indexed="64"/></patternFill></fill>
  </fills>
  <borders count="1"><border/></borders>
  <cellStyleXfs count="1"><xf/></cellStyleXfs>
  <cellXfs count="10">
    <xf xfId="0" fontId="0" fillId="0" applyFont="1"/>
    <xf xfId="0" fontId="1" fillId="0" applyFont="1"/>
    <xf xfId="0" fontId="0" fillId="2" applyFont="1" applyFill="1"/>
    <xf xfId="0" fontId="2" fillId="3" applyFont="1" applyFill="1"/>
    <xf xfId="0" fontId="0" fillId="4" applyFont="1" applyFill="1"/>
    <xf xfId="0" fontId="2" fillId="5" applyFont="1" applyFill="1"/>
    <xf xfId="0" fontId="0" fillId="6" applyFont="1" applyFill="1"/>
    <xf xfId="0" fontId="2" fillId="7" applyFont="1" applyFill="1"/>
    <xf xfId="0" fontId="0" fillId="8" applyFont="1" applyFill="1"/>
    <xf xfId="0" fontId="2" fillId="9" applyFont="1" applyFill="1"/>
  </cellXfs>
</styleSheet>
'@

    $rootRels = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>
'@

    Write-Utf8File -LiteralPath (Join-Path $tmp "[Content_Types].xml") -Content $contentTypes.ToString()
    Write-Utf8File -LiteralPath (Join-Path $tmp "_rels\.rels") -Content $rootRels
    Write-Utf8File -LiteralPath (Join-Path $tmp "xl\workbook.xml") -Content $wb.ToString()
    Write-Utf8File -LiteralPath (Join-Path $tmp "xl\_rels\workbook.xml.rels") -Content $rels.ToString()
    Write-Utf8File -LiteralPath (Join-Path $tmp "xl\styles.xml") -Content $styles

    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($tmp, $Path, [System.IO.Compression.CompressionLevel]::Optimal, $false)
    Remove-Item -LiteralPath $tmp -Recurse -Force
}
