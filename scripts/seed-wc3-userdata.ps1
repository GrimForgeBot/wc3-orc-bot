$wc3 = "$env:USERPROFILE\Documents\Warcraft III"
$subdirs = @(
    "Maps\Download"
    "Maps\Test"
    "CustomMapData"
    "Replays"
    "Screenshots"
    "CustomCampaigns"
)
foreach ($d in $subdirs) {
    New-Item -ItemType Directory -Path "$wc3\$d" -Force | Out-Null
}
"" | Out-File "$wc3\Variables.txt" -Encoding ASCII
Get-ChildItem $wc3 -Recurse | Select-Object FullName
