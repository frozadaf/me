@echo off
setlocal EnableExtensions DisableDelayedExpansion
title OpenCode System Prompt Manager

rem This file is a batch/PowerShell hybrid.  The batch section launches the
rem PowerShell payload stored after the marker at the bottom of this file.
set "OCSPM_SELF=%~f0"
set "OCSPM_ARG1=%~1"
set "OCSPM_ARG2=%~2"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$source = [IO.File]::ReadAllText($env:OCSPM_SELF); $marker = '# === POWERSHELL PAYLOAD ==='; $offset = $source.LastIndexOf($marker, [StringComparison]::Ordinal); if ($offset -lt 0) { throw 'PowerShell payload marker was not found.' }; & ([ScriptBlock]::Create($source.Substring($offset + $marker.Length)))"
set "OCSPM_EXIT=%ERRORLEVEL%"
endlocal & exit /b %OCSPM_EXIT%

# === POWERSHELL PAYLOAD ===

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ManagerName = 'OpenCode System Prompt Manager'
$OwnershipMarker = '// Managed by OpenCode-System-Prompt-Manager.bat; do not rename this marker.'
$PluginName = 'zzzz-opencode-raw-system-prompt-manager.js'
$StateName = 'zzzz-opencode-raw-system-prompt-manager.state.json'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Resolve-AbsolutePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded.StartsWith('~')) {
        $suffix = $expanded.Substring(1).TrimStart([char[]]'\/')
        $expanded = if ($suffix) { Join-Path $HOME $suffix } else { $HOME }
    }
    return [IO.Path]::GetFullPath($expanded)
}

function Get-OpenCodeConfigDirectory {
    if (-not [string]::IsNullOrWhiteSpace($env:OPENCODE_CONFIG_DIR)) {
        return Resolve-AbsolutePath $env:OPENCODE_CONFIG_DIR
    }
    if (-not [string]::IsNullOrWhiteSpace($env:XDG_CONFIG_HOME)) {
        return Resolve-AbsolutePath (Join-Path $env:XDG_CONFIG_HOME 'opencode')
    }
    return Resolve-AbsolutePath (Join-Path $HOME '.config\opencode')
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Write-Utf8FileAtomically {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $parent = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.tmp-' + $PID + '-' + [Guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($temporary, $Content, $Utf8NoBom)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-OwnedPlugin {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    try {
        return [IO.File]::ReadAllText($Path).StartsWith($OwnershipMarker, [StringComparison]::Ordinal)
    }
    catch {
        return $false
    }
}

function Select-PromptFile {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Select the custom OpenCode system prompt'
        $dialog.Filter = 'Prompt files (*.txt;*.md)|*.txt;*.md|Text files (*.txt)|*.txt|Markdown files (*.md)|*.md'
        $dialog.Multiselect = $false
        $dialog.CheckFileExists = $true
        $dialog.CheckPathExists = $true
        $dialog.RestoreDirectory = $true
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.FileName
        }
        return $null
    }
    catch {
        Write-Host ''
        Write-Warning 'The graphical file picker is unavailable. Enter a path instead.'
        $typed = Read-Host 'TXT or MD file path (leave blank to cancel)'
        if ([string]::IsNullOrWhiteSpace($typed)) {
            return $null
        }
        return $typed.Trim().Trim('"')
    }
}

function New-PluginSource {
    param(
        [Parameter(Mandatory = $true)][string]$PromptBase64,
        [Parameter(Mandatory = $true)][string]$PromptHash
    )

    return @"
$OwnershipMarker
"use strict";

// SHA-256 of the selected prompt: $PromptHash
const customSystemPrompt = Buffer.from("$PromptBase64", "base64").toString("utf8");

module.exports = async function openCodeRawSystemPromptManager() {
  return {
    "experimental.chat.system.transform": async function (_input, output) {
      // Replace the complete final system array immediately before the model request.
      output.system.splice(0, output.system.length, customSystemPrompt);
    },
  };
};
"@
}

function Install-CustomPrompt {
    param(
        [Parameter(Mandatory = $true)][string]$PluginPath,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [string]$SelectedPath
    )

    $selected = if ([string]::IsNullOrWhiteSpace($SelectedPath)) { Select-PromptFile } else { $SelectedPath }
    if ([string]::IsNullOrWhiteSpace($selected)) {
        Write-Host ''
        Write-Host 'Selection cancelled; no files were changed.' -ForegroundColor Yellow
        return
    }

    $selected = Resolve-AbsolutePath $selected
    if (-not (Test-Path -LiteralPath $selected -PathType Leaf)) {
        throw "The selected file does not exist: $selected"
    }

    $extension = [IO.Path]::GetExtension($selected).ToLowerInvariant()
    if ($extension -notin @('.txt', '.md')) {
        throw 'Only .txt and .md prompt files are accepted.'
    }

    $prompt = [IO.File]::ReadAllText($selected)
    if ([string]::IsNullOrWhiteSpace($prompt)) {
        throw 'The selected prompt is empty or contains only whitespace.'
    }

    $promptBytes = [Text.Encoding]::UTF8.GetBytes($prompt)
    if ($promptBytes.LongLength -gt 1MB) {
        Write-Host ''
        Write-Warning ('The prompt is {0:N0} bytes. Very large system prompts consume model context and may be rejected.' -f $promptBytes.LongLength)
        $confirmation = Read-Host 'Type INSTALL to continue'
        if ($confirmation -cne 'INSTALL') {
            Write-Host 'Installation cancelled; no files were changed.' -ForegroundColor Yellow
            return
        }
    }

    if ((Test-Path -LiteralPath $PluginPath -PathType Leaf) -and -not (Test-OwnedPlugin $PluginPath)) {
        throw "Refusing to overwrite a plugin not owned by this manager: $PluginPath"
    }

    $hash = Get-Sha256Hex $promptBytes
    $base64 = [Convert]::ToBase64String($promptBytes)
    $pluginSource = New-PluginSource -PromptBase64 $base64 -PromptHash $hash

    Write-Utf8FileAtomically -Path $PluginPath -Content $pluginSource

    $state = [ordered]@{
        manager = $ManagerName
        version = 1
        installedAtUtc = [DateTime]::UtcNow.ToString('o')
        sourceFile = $selected
        promptBytes = $promptBytes.LongLength
        sha256 = $hash
        pluginFile = $PluginPath
    } | ConvertTo-Json -Depth 3
    Write-Utf8FileAtomically -Path $StatePath -Content $state

    Write-Host ''
    Write-Host 'Custom raw system prompt installed.' -ForegroundColor Green
    Write-Host "Source : $selected"
    Write-Host "Plugin : $PluginPath"
    Write-Host "SHA-256: $hash"
    Write-Host ''
    Write-Warning 'Fully exit and reopen OpenCode. The custom prompt applies to new model requests after restart.'
}

function Restore-DefaultPrompt {
    param(
        [Parameter(Mandatory = $true)][string]$PluginPath,
        [Parameter(Mandatory = $true)][string]$StatePath
    )

    if (-not (Test-Path -LiteralPath $PluginPath -PathType Leaf)) {
        if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
            Remove-Item -LiteralPath $StatePath -Force
        }
        Write-Host ''
        Write-Host 'The default OpenCode system prompt is already active.' -ForegroundColor Green
        return
    }

    if (-not (Test-OwnedPlugin $PluginPath)) {
        throw "Refusing to remove a plugin not owned by this manager: $PluginPath"
    }

    Remove-Item -LiteralPath $PluginPath -Force
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        Remove-Item -LiteralPath $StatePath -Force
    }

    Write-Host ''
    Write-Host 'Default OpenCode system prompt restored.' -ForegroundColor Green
    Write-Host "Removed: $PluginPath"
    Write-Host ''
    Write-Warning 'Fully exit and reopen OpenCode so the default prompt is loaded.'
}

function Show-Status {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigDirectory,
        [Parameter(Mandatory = $true)][string]$PluginPath,
        [Parameter(Mandatory = $true)][string]$StatePath
    )

    Write-Host ''
    Write-Host "Config directory: $ConfigDirectory"
    if (Test-OwnedPlugin $PluginPath) {
        Write-Host 'Prompt status   : CUSTOM (manager plugin is active)' -ForegroundColor Yellow
        if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
            try {
                $state = [IO.File]::ReadAllText($StatePath) | ConvertFrom-Json
                if ($state.sourceFile) { Write-Host "Source file     : $($state.sourceFile)" }
                if ($state.sha256) { Write-Host "SHA-256        : $($state.sha256)" }
                if ($state.installedAtUtc) { Write-Host "Installed UTC  : $($state.installedAtUtc)" }
            }
            catch {
                Write-Warning 'The optional state file could not be read.'
            }
        }
    }
    elseif (Test-Path -LiteralPath $PluginPath -PathType Leaf) {
        Write-Host 'Prompt status   : UNKNOWN (a same-named, unmanaged plugin exists)' -ForegroundColor Red
    }
    else {
        Write-Host 'Prompt status   : DEFAULT' -ForegroundColor Green
    }

    $running = @(Get-Process -Name 'OpenCode' -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Write-Host ('OpenCode process : RUNNING ({0} process(es)); restart after making a change' -f $running.Count) -ForegroundColor Yellow
    }
    else {
        Write-Host 'OpenCode process : not running'
    }
}

function Wait-ForMenu {
    Write-Host ''
    [void](Read-Host 'Press Enter to return to the menu')
}

$configDirectory = Get-OpenCodeConfigDirectory
$pluginDirectory = Join-Path $configDirectory 'plugins'
$pluginPath = Join-Path $pluginDirectory $PluginName
$statePath = Join-Path $configDirectory $StateName

# Optional non-interactive forms are useful for automation and drag-and-drop:
#   Manager.bat /install "C:\path\prompt.md"
#   Manager.bat /restore
#   Manager.bat /status
#   Manager.bat "C:\path\prompt.txt"
if (-not [string]::IsNullOrWhiteSpace($env:OCSPM_ARG1)) {
    try {
        switch ($env:OCSPM_ARG1.ToLowerInvariant()) {
            '/install' {
                if ([string]::IsNullOrWhiteSpace($env:OCSPM_ARG2)) {
                    throw 'Usage: OpenCode-System-Prompt-Manager.bat /install "C:\path\prompt.txt"'
                }
                Install-CustomPrompt -PluginPath $pluginPath -StatePath $statePath -SelectedPath $env:OCSPM_ARG2
            }
            '/restore' {
                Restore-DefaultPrompt -PluginPath $pluginPath -StatePath $statePath
            }
            '/status' {
                Show-Status -ConfigDirectory $configDirectory -PluginPath $pluginPath -StatePath $statePath
            }
            default {
                Install-CustomPrompt -PluginPath $pluginPath -StatePath $statePath -SelectedPath $env:OCSPM_ARG1
            }
        }
        exit 0
    }
    catch {
        Write-Host 'Operation failed:' -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        exit 1
    }
}

while ($true) {
    Clear-Host
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '             OpenCode System Prompt Manager by outcome' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'This uses OpenCode''s system-transform plugin hook, so it does'
    Write-Host 'not edit app.asar and remains easy to undo after app updates.'
    Show-Status -ConfigDirectory $configDirectory -PluginPath $pluginPath -StatePath $statePath
    Write-Host ''
    Write-Host '[1] Select a TXT/MD file and use it as the raw system prompt'
    Write-Host '[2] Restore the default OpenCode system prompt'
    Write-Host '[3] Refresh status'
    Write-Host '[4] Exit'
    Write-Host ''

    $choice = Read-Host 'Choose 1-4'
    try {
        switch ($choice.Trim()) {
            '1' {
                Install-CustomPrompt -PluginPath $pluginPath -StatePath $statePath
                Wait-ForMenu
            }
            '2' {
                Restore-DefaultPrompt -PluginPath $pluginPath -StatePath $statePath
                Wait-ForMenu
            }
            '3' { }
            '4' { exit 0 }
            default {
                Write-Host ''
                Write-Warning 'Invalid choice. Enter 1, 2, 3, or 4.'
                Start-Sleep -Seconds 1
            }
        }
    }
    catch {
        Write-Host ''
        Write-Host 'Operation failed:' -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        Wait-ForMenu
    }
}
