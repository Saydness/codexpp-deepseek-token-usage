<#
 * DeepSeek balance key store.
 *
 * The key is encrypted with Windows DPAPI in the CurrentUser scope, so only
 * this Windows account on this machine can read it back. The file holds the
 * encrypted blob, never the plaintext key.
 *
 * usage:
 *   powershell -NoProfile -ExecutionPolicy Bypass -File helper\set_balance_key.ps1
 *     -> asks for the key with a masked prompt and saves it
 *   "sk-..." | powershell -NoProfile -ExecutionPolicy Bypass -File helper\set_balance_key.ps1
 *     -> saves a piped key (this is what the local helper does, so the key
 *        never shows up in a command line or in a process list)
 *   ... -File helper\set_balance_key.ps1 -Status   -> prints present / absent
 *   ... -File helper\set_balance_key.ps1 -Print    -> prints the key, no newline
 *   ... -File helper\set_balance_key.ps1 -Clear    -> deletes the saved key
 *
 * DSTU_KEY_STORE overrides the file location (used by the tests).
#>
[CmdletBinding()]
param(
  [switch]$Clear,
  [switch]$Status,
  [switch]$Print
)

$ErrorActionPreference = 'Stop'

function Get-StorePath {
  if (-not [string]::IsNullOrWhiteSpace($env:DSTU_KEY_STORE)) {
    return $env:DSTU_KEY_STORE
  }
  $base = $env:LOCALAPPDATA
  if ([string]::IsNullOrWhiteSpace($base)) {
    $base = Join-Path $env:USERPROFILE 'AppData\Local'
  }
  return (Join-Path $base 'Codex++\deepseek-balance.key')
}

function Unprotect-Key([string]$cipher) {
  $secure = ConvertTo-SecureString -String $cipher.Trim()
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

function Read-KeyFromInput {
  $raw = $null
  if ([Console]::IsInputRedirected) {
    $raw = [Console]::In.ReadToEnd()
  }
  if (-not [string]::IsNullOrWhiteSpace($raw)) {
    return $raw.Trim()
  }
  $secure = Read-Host -AsSecureString -Prompt 'DeepSeek API Key'
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try {
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

$store = Get-StorePath

if ($Clear) {
  if ([System.IO.File]::Exists($store)) {
    [System.IO.File]::Delete($store)
  }
  [Console]::Out.WriteLine('cleared')
  exit 0
}

if ($Status) {
  if ([System.IO.File]::Exists($store)) {
    [Console]::Out.WriteLine('present')
  } else {
    [Console]::Out.WriteLine('absent')
  }
  exit 0
}

if ($Print) {
  if (-not [System.IO.File]::Exists($store)) {
    exit 3
  }
  $key = Unprotect-Key ([System.IO.File]::ReadAllText($store))
  [Console]::Out.Write($key)
  exit 0
}

$key = Read-KeyFromInput
if ([string]::IsNullOrWhiteSpace($key)) {
  [Console]::Error.WriteLine('no key given')
  exit 2
}
if ($key.Length -lt 8) {
  [Console]::Error.WriteLine('key looks too short')
  exit 2
}

$secure = ConvertTo-SecureString -String $key -AsPlainText -Force
$cipher = ConvertFrom-SecureString -SecureString $secure
$dir = Split-Path -Parent $store
if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
}
[System.IO.File]::WriteAllText($store, $cipher, [System.Text.Encoding]::ASCII)

[Console]::Out.WriteLine('saved (DPAPI, current user only)')
exit 0
