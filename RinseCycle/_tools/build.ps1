# Builds RinseCycle.rbxlx (a Roblox place you can open in Studio) and
# sourcemap.json (for the luau-lsp type checker) from the script mirror.
#
# Folder layout mirrors Studio, using Studio Script Sync file names so the
# three folders (Shared, Server, Client) can also be synced live:
#   Name.server.luau  -> Script (RunContext Server)
#   Name.local.luau   -> LocalScript
#   Name.luau         -> ModuleScript
#   any other directory -> Folder
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File _tools\build.ps1
#       add  -MapOnly -MapOut <path>  to write only a sourcemap (used by the type checker)

param([switch]$MapOnly, [string]$MapOut = '')

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$OutPlace = Join-Path $Root 'RinseCycle.rbxlx'
$OutMap = Join-Path $Root '_tools\sourcemap.json'
if ($MapOut -ne '') { $OutMap = $MapOut }

$ServiceNames = @('Workspace', 'ReplicatedStorage', 'ReplicatedFirst', 'ServerScriptService',
    'ServerStorage', 'StarterPlayer', 'StarterGui', 'Lighting', 'SoundService')
$SpecialFolders = @{ 'StarterPlayerScripts' = 'StarterPlayerScripts'; 'StarterCharacterScripts' = 'StarterCharacterScripts' }

$script:ref = 0
function Next-Ref { $script:ref++; return ('RBX{0:X8}' -f $script:ref) }

function Escape-Xml([string]$s) {
    return $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}
function Escape-Source([string]$s) {
    # Entity-escape rather than CDATA: Studio has rejected split CDATA sections,
    # and Luau can legitimately contain "]]>" (e.g. t[a[1]]>0).
    $s = $s.Replace("`r`n", "`n").TrimEnd()
    return $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}
function Json-Str([string]$s) {
    return '"' + $s.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Script-Info([string]$fileName) {
    if ($fileName -like '*.server.luau') { return @('Script', $fileName.Substring(0, $fileName.Length - 12)) }
    if ($fileName -like '*.local.luau') { return @('LocalScript', $fileName.Substring(0, $fileName.Length - 11)) }
    if ($fileName -like '*.client.luau') { throw "$fileName : use .local.luau for LocalScripts (.client.luau is a RunContext=Client Script and runs twice in Starter containers)" }
    if ($fileName -like '*.luau') { return @('ModuleScript', $fileName.Substring(0, $fileName.Length - 5)) }
    return $null
}

# Extra properties written onto specific services in the place file.
$ServiceProps = @{
    'StarterPlayer' = '';
    'Workspace' = '<bool name="StreamingEnabled">false</bool>'
}

$utf8 = New-Object System.Text.UTF8Encoding $false

function Build-Dir([System.IO.DirectoryInfo]$dir, [string]$className, [string]$relPath, [System.Text.StringBuilder]$xml, [System.Text.StringBuilder]$map) {
    [void]$xml.Append("<Item class=`"$className`" referent=`"$(Next-Ref)`"><Properties><string name=`"Name`">$(Escape-Xml $dir.Name)</string>")
    if ($ServiceProps.ContainsKey($className)) { [void]$xml.Append($ServiceProps[$className]) }
    [void]$xml.Append("</Properties>`n")
    [void]$map.Append("{`"name`":$(Json-Str $dir.Name),`"className`":`"$className`",`"children`":[")
    $first = $true

    foreach ($sub in (Get-ChildItem -LiteralPath $dir.FullName -Directory | Sort-Object Name)) {
        if ($sub.Name.StartsWith('_')) { continue }
        $cls = 'Folder'
        if ($SpecialFolders.ContainsKey($sub.Name)) { $cls = $SpecialFolders[$sub.Name] }
        if (-not $first) { [void]$map.Append(',') }; $first = $false
        Build-Dir $sub $cls "$relPath/$($sub.Name)" $xml $map
    }
    foreach ($file in (Get-ChildItem -LiteralPath $dir.FullName -File | Sort-Object Name)) {
        $info = Script-Info $file.Name
        if ($null -eq $info) { continue }
        $src = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
        [void]$xml.Append("<Item class=`"$($info[0])`" referent=`"$(Next-Ref)`"><Properties><string name=`"Name`">$(Escape-Xml $info[1])</string>")
        if ($info[0] -eq 'Script') { [void]$xml.Append('<bool name="Disabled">false</bool><token name="RunContext">1</token>') }
        if ($info[0] -eq 'LocalScript') { [void]$xml.Append('<bool name="Disabled">false</bool>') }
        [void]$xml.Append("<ProtectedString name=`"Source`">$(Escape-Source $src)</ProtectedString></Properties></Item>`n")
        if (-not $first) { [void]$map.Append(',') }; $first = $false
        [void]$map.Append("{`"name`":$(Json-Str $info[1]),`"className`":`"$($info[0])`",`"filePaths`":[$(Json-Str "$relPath/$($file.Name)")]}")
    }
    [void]$xml.Append("</Item>`n")
    [void]$map.Append(']}')
}

$xml = New-Object System.Text.StringBuilder
$map = New-Object System.Text.StringBuilder
[void]$xml.Append('<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">' + "`n")
[void]$map.Append('{"name":"RinseCycle","className":"DataModel","children":[')

$first = $true
$counts = @{}
foreach ($svc in $ServiceNames) {
    $path = Join-Path $Root $svc
    if (-not (Test-Path -LiteralPath $path)) {
        if ($ServiceProps.ContainsKey($svc)) {
            [void]$xml.Append("<Item class=`"$svc`" referent=`"$(Next-Ref)`"><Properties><string name=`"Name`">$svc</string>$($ServiceProps[$svc])</Properties></Item>`n")
        }
        continue
    }
    if (-not $first) { [void]$map.Append(',') }; $first = $false
    Build-Dir (Get-Item -LiteralPath $path) $svc $svc $xml $map
}
[void]$xml.Append('</roblox>' + "`n")
[void]$map.Append(']}')

[System.IO.File]::WriteAllText($OutMap, $map.ToString(), $utf8)
if ($MapOnly) {
    Write-Output "Built $OutMap"
    exit 0
}
[System.IO.File]::WriteAllText($OutPlace, $xml.ToString(), $utf8)

# Sanity check: the place file must be well-formed XML.
$doc = New-Object System.Xml.XmlDocument
$doc.Load($OutPlace)
$scripts = $doc.SelectNodes('//Item[@class="Script" or @class="LocalScript" or @class="ModuleScript"]').Count
Write-Output "Built $OutPlace ($scripts scripts, $([math]::Round((Get-Item $OutPlace).Length / 1KB)) KB)"
Write-Output "Built $OutMap"
