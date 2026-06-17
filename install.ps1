# install.ps1 — Install wp-optimize skill for Claude Code (Windows)

$skillsDir = "$env:USERPROFILE\.claude\skills"
$skillFile = "wp-optimize.md"

if (-not (Test-Path $skillsDir)) {
    New-Item -ItemType Directory -Path $skillsDir -Force | Out-Null
}

try {
    Copy-Item $skillFile -Destination "$skillsDir\$skillFile" -Force
    Write-Host "Skill installed at $skillsDir\$skillFile"
    Write-Host "Use it in Claude Code with: /wp-optimize"
} catch {
    Write-Host "Failed to copy skill: $_"
    exit 1
}
