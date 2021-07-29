$localFunctionUrl       = "https://progressuspublic.blob.core.windows.net/functions"
$localFunctionFile      = "Functions.ps1"
$localFunctionSourceUrl = $localFunctionUrl + "/" + $localFunctionFile
$localFunctionDestFile  = (Join-Path -Path $ENV:TEMP -ChildPath $localFunctionFile)

Download-File -sourceUrl $localFunctionSourceUrl -destinationFile $localFunctionDestFile

If (Test-Path -Path $localFunctionDestFile)
{
  Write-Output("Running [" + $localFunctionDestFile + "]")
  . ($localFunctionDestFile)
}
else
{
  Write-Error("ERROR: Not found [" + $localFunctionDestFile + "]")
}

Remove-Variable localFunction*
