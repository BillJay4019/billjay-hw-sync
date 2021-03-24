Param(
    [string]       $containerName = $CommonContainerName, # $(DockerName)
    [string]       $appObjects    = $PSScriptRoot,
    [string]       $appArtifacts  = "",                   # $(System.ArtifactsDirectory)
    [string]       $userName      = $PgsNavUser,          # $(PgsUsername)
    [string]       $userPass      = $PgsNavPass,          # $(PgsPassword)
    [string]       $pfxFile       = $PgsCertFile,         # look for pfx file if blank
    [SecureString] $pfxPassSecure = $PgsCertPass,
    [string]       $pfxPass       = ""                    # $(PgsCertPassword)
)

. (Join-Path $PSScriptRoot "Functions.ps1")

Deploy-ThisNavApp `
 -containerName $containerName `
 -appObjects    $appObjects `
 -appArtifacts  $appArtifacts `
 -userName      $userName `
 -userPass      $userPass `
 -pfxFile       $pfxFile `
 -pfxPassSecure $pfxPassSecure `
 -pfxPass       $pfxPass
