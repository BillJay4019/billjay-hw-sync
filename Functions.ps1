function MyTrim
{
    Param(
        [string] $myString
    )
    if ( ($myString -eq $null) -or ($myString -eq "") )
    {
        return ""
    }
    return $myString.Trim()
}

function MyEmptyString
{
    Param(
        [string] $myString
    )
    if ( ($myString -eq $null) -or ($myString -eq "") )
    {
        return $true
    }
    return $false
}

function MyContainerName
{
    Param(
        [string] $containerName
    )
    $containerName = MyTrim($containerName)
    if (MyEmptyString($containerName))
    {
        $containerName = ""
    }
    else
    {
        $containerName = $containerName.Replace("_","-").Replace(".","-").Replace(" ","-")
    }
    return $containerName
}

function MyContainerId
{
    Param(
        [string] $containerName
    )
    $containerName = MyContainerName($containerName)
    if (MyEmptyString($containerName))
    {
        return ""
    }
    return (docker ps --filter name=$containerName -a -q).ToString().Trim()
}

function Sign-PclAssembly
{
    Param
    (
        [string]       $appFile     = "",
        [string]       $pfxFile     = $PgsCertFile,
        [SecureString] $pfxPassword = $PgsCertPass,
        [boolean]      $reinstall   = $false
    )

    $localSignTemp      = $env:Temp
    $localSignWinKitBin = (Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin")
    $localSignWinKitExe = (Join-Path $localSignWinKitBin "*\x64\SignTool.exe")
    $localSignToolExe   = ""
    $localSignCopied    = $false

    if ($pfxFile.ToLower().StartsWith("http://") -or $pfxFile.ToLower().StartsWith("https://")) {
        $pfxUrl  = $pfxFile
        $pfxFile = Join-Path $localSignTemp ([System.Uri]::UnescapeDataString([System.IO.Path]::GetFileName($pfxUrl).split("?")[0]))
        (New-Object System.Net.WebClient).DownloadFile($pfxUrl, $pfxFile)
        $localSignCopied = $true
    }

    if (Test-Path $localSignWinKitExe)
    {
        $localSignToolExe = (Get-Item $localSignWinKitExe).FullName
        if ($localSignToolExe.Count -gt 1)
        {
            $localSignToolExe = $localSignToolExe[0]
        }

        Write-Host "Found Signing Tool [" + $localSignToolExe + "]"
    }
    else
    {
        $reinstall = $true
    }

    if ($reinstall -eq $true)
    {
        Write-Host "Downloading Signing Tools"

        $localSignSdkSetupExe = (Join-Path $localSignTemp "winsdksetup.exe")
        $localSignSdkSetupUrl = "https://go.microsoft.com/fwlink/p/?LinkID=2023014"
        (New-Object System.Net.WebClient).DownloadFile($localSignSdkSetupUrl, $localSignSdkSetupExe)

        Write-Host "Installing Signing Tools"

        Start-Process $localSignSdkSetupExe -ArgumentList "/features OptionId.SigningTools /q" -Wait
        if (!(Test-Path $localSignWinKitExe))
        {
            throw "Cannot locate " + $localSignWinKitExe + " after installation"
        }

        $localSignToolExe = (Get-Item $localSignWinKitExe).FullName
    }

    $appFile = MyTrim($appFile)
    if ($appFile -eq "")
    {
        Write-Host "WARNING: appFile is blank"
    }
    else
    {
        Write-Host "Signing $appFile"

        $localSignTimestampServer  = $bcContainerHelperConfig.timeStampServer # "http://timestamp.verisign.com/scripts/timestamp.dll"
        $localSignUnsecurePassword = ([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pfxPassword)))
        & "$localSignToolExe" @("sign", "/f", "$pfxFile", "/p","$localSignUnsecurePassword", "/t", $localSignTimestampServer, "$appFile") | Write-Host

        if ($localSignCopied)
        { 
            if (Test-Path $pfxFile)
            {
                Remove-Item $pfxFile -Force
            }
        }
    }

    Remove-Variable localSign*
}

function Sync-ThisNavApp
{
    Param(
        [Parameter(Mandatory=$true)]
        [string] $containerName = $CommonContainerName,
        [string] $tenant        = "Default"
    )

    $localSyncContainer   = MyContainerName($containerName)
    $localSyncContainerId = MyContainerId($localSyncContainer)
    $localSyncTenant      = $tenant
    $localSyncScriptBlock = 
        {Param($localSyncTenant)
        $localSyncInstance = (Get-NAVServerInstance).ServerInstance.Replace("MicrosoftDynamicsNavServer$","")

        Write-Output ("ServerInstance " + $localSyncInstance + ", is synchronizing")

        Sync-NAVTenant -ServerInstance "$localSyncInstance" -Tenant $localSyncTenant -Mode CheckOnly
        Sync-NAVTenant -ServerInstance "$localSyncInstance" -Tenant $localSyncTenant -Mode Sync -Force

        Start-Sleep 1
        Stop-NavServerInstance  -ServerInstance "$localSyncInstance"
        Start-Sleep 1
        Start-NavServerInstance -ServerInstance "$localSyncInstance"
        Start-Sleep 1

        $localSyncCountMax = 10
        for ($localSyncCount = 0; $localSyncCount -le $localSyncCountMax; $localSyncCount++)
        {
            if ((Get-NavServerInstance).State.ToString().ToLower() -eq "running")
            {
                $localSyncCount = ($localSyncCountMax + 1)
                break
            }
            else
            {
                Start-NavServerInstance -ServerInstance "$localSyncInstance"
                Start-Sleep 1
            }
        }
    }

    if (!(MyEmptyString($localSyncContainerId)))
    {
        $localSyncSession = $null
        try   { $localSyncSession = Get-NavContainerSession -containerName $localSyncContainer -silent }
        catch { $localSyncSession = $null }

        if ($localSyncSession -ne $null)
        {
            Invoke-Command -ScriptBlock $localSyncScriptBlock -ArgumentList $localSyncTenant -Session $localSyncSession
        }
    }

    Remove-Variable localSync*
}

function Unpublish-ThisNavApp
{
    Param(
        [Parameter(Mandatory=$true)]
        [string] $containerName = $CommonContainerName,
        [string] $tenant        = "Default",
        [Parameter(Mandatory=$true)]
        [string] $appJson       = ""
    )

    $localUnpublishContainer   = MyContainerName($containerName)
    $localUnpublishContainerId = MyContainerId($localUnpublishContainer)
    $localUnpublishTenant      = $tenant
    $localUnpublishJson        = $appJson
    $localUnpublishScriptBlock = 
    {Param($localUnpublishTenant,$localUnpublishJson)

        $localUnpublishJsonContent = (Get-Content $localUnpublishJson | ConvertFrom-Json)
        $localUnpublishInstance    = (Get-NAVServerInstance).ServerInstance.Replace("MicrosoftDynamicsNavServer$","")

        Write-Output ("AppInfo, Before, ServerInstance " + $localUnpublishInstance)
        Get-NAVAppInfo -ServerInstance "$localUnpublishInstance" -Tenant $localUnpublishTenant -TenantSpecificProperties | Where-Object {($_.Publisher -ne "Microsoft")} | Sort-Object -Property "Name" | Format-Table -Property "Scope","Version","ExtensionDataVersion","SyncState","IsPublished","IsInstalled","Publisher","Name"

        foreach ($localUnpublishCurrent in $localUnpublishJsonContent)
        {
            $localUnpublishName      = $localUnpublishCurrent.Name
            $localUnpublishPublisher = $localUnpublishCurrent.Publisher
            $localUnpublishAppInfo   = (Get-NavAppInfo -ServerInstance "$localUnpublishInstance" -Tenant $localUnpublishTenant -TenantSpecificProperties -Name "$localUnpublishName" -Publisher "$localUnpublishPublisher")
            if ($localUnpublishAppInfo -ne $null)
            {
                Write-Output "$localUnpublishName, Found"
                if ($localUnpublishAppInfo.IsInstalled -eq $true)
                {
                    Write-Output "$localUnpublishName, Uninstalling"
                    Uninstall-NAVApp -ServerInstance "$localUnpublishInstance" -Tenant $localUnpublishTenant -Name $localUnpublishName -Publisher $localUnpublishPublisher
                    $localUnpublishAppInfo = (Get-NavAppInfo -ServerInstance "$localUnpublishInstance" -Tenant $localUnpublishTenant -TenantSpecificProperties -Name "$localUnpublishName" -Publisher "$localUnpublishPublisher")
                }
                if ($localUnpublishAppInfo.IsPublished -eq $true)
                {
                    Write-Output "$localUnpublishName, Unpublishing"
                    if ($localUnpublishAppInfo.Scope.ToString().Trim().ToLower() -eq "global")
                    {
                        Unpublish-NAVApp -ServerInstance "$localUnpublishInstance"                               -Name $localUnpublishName -Publisher $localUnpublishPublisher
                    }
                    else
                    {
                        Unpublish-NAVApp -ServerInstance "$localUnpublishInstance" -Tenant $localUnpublishTenant -Name $localUnpublishName -Publisher $localUnpublishPublisher
                    }

                    $localUnpublishAppInfo = (Get-NavAppInfo -ServerInstance "$localUnpublishInstance" -Tenant $localUnpublishTenant -TenantSpecificProperties -Name "$localUnpublishName" -Publisher "$localUnpublishPublisher")
                }
                $localUnpublishSync = $true
            }
        }
    }

    if (!(MyEmptyString($localUnpublishContainerId)))
    {
        $localUnpublishSession = $null
        try   { $localUnpublishSession = Get-NavContainerSession -containerName $localUnpublishContainer -silent }
        catch { $localUnpublishSession = $null }

        if ($localUnpublishSession -ne $null)
        {
            Invoke-Command -ScriptBlock $localUnpublishScriptBlock -ArgumentList $localUnpublishTenant,$localUnpublishJson -Session $localUnpublishSession
        }
    }

    Remove-Variable localUnpublish*
}

function Compile-ThisNavApp
{
    Param(
        [Parameter(Mandatory=$true)]
        [string]       $containerName    = $CommonContainerName,
        [Parameter(Mandatory=$true)]
        [string]       $appFolderObjects = $PSScriptRoot,
        [Parameter(Mandatory=$true)]
        [string]       $userName         = $PgsNavUser,
        [string]       $userPass         = $PgsNavPass,
        [string]       $pfxFile          = $PgsCertFile,
        [SecureString] $pfxPassSecure    = $PgsCertPass,
        [string]       $pfxPass          = "",
        [string]       $language         = "en-US"
    )

    $localCompileContainer    = MyContainerName($containerName)
    $localCompileObjects      = $appFolderObjects
    $localCompileLanguage     = $language
    $localCompileArtifacts    = $localCompileObjects
    $localCompilePackages     = (Join-Path -Path $localCompileObjects -ChildPath ".alpackages")
    $localCompileTranslations = (Join-Path -Path $localCompileObjects -ChildPath "Translations")
    $localCompileAppJson      = (Join-Path -Path $localCompileObjects -ChildPath "app.json")
    $localCompileCredential   = [PSCredential]::new($userName, (ConvertTo-SecureString -String $userPass -AsPlainText -Force))
    $localCompileCertFile     = $pfxFile
    if (MyEmptyString($localCompileCertFile))
    {
    $localCompileCertFile     = (Join-Path $PSScriptRoot "*.pfx")
    }
    $localCompileCertFile     = (Get-Item $localCompileCertFile).FullName
    $localCompileCertPass     = $pfxPassSecure
    if ($localCompileCertPass -eq $null)
    {
    $localCompileCertPass     = (ConvertTo-SecureString "$pfxPass" -AsPlainText -Force)
    }

    if ((Test-Path -Path $localCompileAppJson) -eq $true)
    {
        $localCompileAppContent           = (Get-Content $localCompileAppJson | ConvertFrom-Json)
        $localCompileAppFile              = (Join-Path -Path $localCompileObjects -ChildPath ($localCompileAppContent.Publisher + "_" + $localCompileAppContent.Name + "_" + $localCompileAppContent.Version + ".app"))
        $localCompileAppSource            = (Join-Path -Path $localCompileTranslations -ChildPath ($localCompileAppContent.Name + "." + "g"                   + ".xlf" ) )
        $localCompileAppDestin            = (Join-Path -Path $localCompileTranslations -ChildPath ($localCompileAppContent.Name + "." + $localCompileLanguage + ".xlf" ) )
        $localCompileAppDestinTextMatch   = ("(<source>([^<]*)</source>)")
        $localCompileAppDestinTextReplace = ("`$1`r`n          <target>`$2</target>")

        if ( ($localCompileContainer -ne "") -and ($localCompileObjects -ne "") -and ($localCompileArtifacts -ne "") )
        {
            if ((Test-Path -Path $localCompileArtifacts) -eq $false)
            {
                New-Item -ItemType Directory -Force -Path "$localCompileArtifacts"
            }
            if ((Test-Path -Path $localCompilePackages) -eq $true)
            {
                Remove-Item ("$localCompilePackages\*.app") -Force
            }
            if ((Test-Path -Path $localCompileObjects) -eq $true)
            {
                [string] $localCompileAppSourceTextCompileBefore = [System.IO.File]::ReadAllText($localCompileAppSource)

                # Compile before to regenerate the *.g.xlf translation file
                Compile-AppInNavContainer -containerName $localCompileContainer -credential $localCompileCredential -appProjectFolder $localCompileObjects -appOutputFolder $localCompileArtifacts -UpdateSymbols

                [string] $localCompileAppSourceTextCompileAfter = [System.IO.File]::ReadAllText($localCompileAppSource)

                if (Test-Path $localCompileAppSource)
                {
                    Copy-Item -Path $localCompileAppSource -Destination $localCompileAppDestin -Force

                    if (Test-Path $localCompileAppDestin)
                    {
                        [string] $localCompileAppDestinTextBefore = [System.IO.File]::ReadAllText($localCompileAppDestin)
                        [string] $localCompileAppDestinTextAfter  = [regex]::Replace($localCompileAppDestinTextBefore, $localCompileAppDestinTextMatch, $localCompileAppDestinTextReplace, "Singleline")

                        if ($localCompileAppDestinTextBefore -ne $localCompileAppDestinTextAfter)
                        {
                            [System.IO.File]::WriteAllText($localCompileAppDestin, ($localCompileAppDestinTextAfter))
                        }
                    }
                }

                # Re-compile after any translation files have been updated
                if ( ($localCompileAppSourceTextCompileBefore -ne $localCompileAppSourceTextCompileAfter) -or ($localCompileAppDestinTextBefore -ne $localCompileAppDestinTextAfter) )
                {
                    Compile-AppInNavContainer -containerName $localCompileContainer -credential $localCompileCredential -appProjectFolder $localCompileObjects -appOutputFolder $localCompileArtifacts
                }
            }

            if ((Test-Path -Path $localCompileAppFile) -eq $true)
            {
                if ( ($localCompileCertPass -ne $null) -and ($localCompileCertFile -ne $null) -and ($localCompileCertFile -ne "") )
                {
                    if ((Test-Path -Path $localCompileCertFile) -eq $true)
                    {
                       #Sign-NavContainerApp -containerName $localCompileContainer -appFile "$localCompileAppFile" -pfxFile $localCompileCertFile -pfxPassword $localCompileCertPass
                        Sign-PclAssembly     -appFile "$localCompileAppFile" -pfxFile $localCompileCertFile -pfxPassword $localCompileCertPass
                    }
                    else
                    {
                        Write-Output ("WARNING: Missing certificate file " + $localCompileCertFile)
                    }
                }
                else
                {
                    Write-Output ("WARNING: Missing certificate information")
                }
            }
            else
            {
                Write-Output ("WARNING: Missing " + $localCompileAppFile)
            }
        }
    }
    else
    {
        Write-Output ("WARNING: Missing " + $localCompileAppJson)
    }

    Remove-Variable localCompile*
}

function Publish-ThisNavApp
{
    Param(
        [Parameter(Mandatory=$true)]
        [string]  $containerName        = $CommonContainerName,
        [Parameter(Mandatory=$true)]
        [string]  $appFolderObjects     = "",
        [string]  $buildFolderArtifacts = "",
        [boolean] $appVerify            = $true
    )

    $localPublishAppContainer    = MyContainerName($containerName)
    $localPublishAppFolder       = $appFolderObjects
    $localPublishAppArtifacts    = $buildFolderArtifacts
    if (MyEmptyString($localPublishAppArtifacts))
    {
        $localPublishAppArtifacts = $localPublishAppFolder
    }

    $localPublishAppScriptBlock  = 
    {   Param($localPublishAppArtifacts,$localPublishAppName,$localPublishAppPublisher,$localPublishAppVersion,$appVerify)

        $localPublishAppInstance = (Get-NAVServerInstance).ServerInstance.Replace("MicrosoftDynamicsNavServer$","")
        $localPublishAppFile     = ($localPublishAppArtifacts + "\" + $localPublishAppPublisher + "_" + $localPublishAppName + "_" + $localPublishAppVersion + ".app")
        if ( (Test-Path -LiteralPath "$localPublishAppFile" -PathType Leaf) -eq $false)
        {
            Write-Output ("Skipping...: " + $localPublishAppFile + " was NOT found.")
        }
        else
        {
            Write-Output ("Processing.: " + $localPublishAppFile)
            $localPublishAppNavApp = (Get-NAVAppInfo -ServerInstance "$localPublishAppInstance" -Tenant Default -TenantSpecificProperties -Name "$localPublishAppName" -Publisher "$localPublishAppPublisher")
            if ( !($localPublishAppNavApp) )
            {
                if ($appVerify -eq $true)
                { Publish-NAVApp -ServerInstance "$localPublishAppInstance" -Path "$localPublishAppFile" }
                else
                { Publish-NAVApp -ServerInstance "$localPublishAppInstance" -Path "$localPublishAppFile" -SkipVerification }
                $localPublishAppNavApp = (Get-NAVAppInfo -ServerInstance "$localPublishAppInstance" -Tenant Default -TenantSpecificProperties -Name "$localPublishAppName" -Publisher "$localPublishAppPublisher")
            }
            if ($localPublishAppNavApp)
            {
                if ($localPublishAppNavApp.SyncState.ToString() -ne "Synced")
                {
                    Sync-NAVApp -ServerInstance "$localPublishAppInstance" -Tenant Default -Name "$localPublishAppName" -Publisher "$localPublishAppPublisher"
                    $localPublishAppNavApp = (Get-NAVAppInfo -ServerInstance "$localPublishAppInstance" -Tenant Default -TenantSpecificProperties -Name "$localPublishAppName" -Publisher "$localPublishAppPublisher")
                }
                if ($localPublishAppNavApp.SyncState.ToString() -eq "Synced")
                {
                    if ( ($localPublishAppNavApp.ExtensionDataVersion -ne $null) -and ($localPublishAppNavApp.ExtensionDataVersion -ne "") )
                    {
                        if ($localPublishAppNavApp.Version -ne $localPublishAppNavApp.ExtensionDataVersion)
                        {
                            Start-NAVAppDataUpgrade -ServerInstance "$localPublishAppInstance" -Tenant Default -Name "$localPublishAppName" -Publisher "$localPublishAppPublisher"
                            $localPublishAppNavApp = (Get-NAVAppInfo -ServerInstance "$localPublishAppInstance" -Tenant Default -TenantSpecificProperties -Name "$localPublishAppName" -Publisher "$localPublishAppPublisher")
                        }
                    }
                }
                if ($localPublishAppNavApp.IsInstalled -ne $true)
                {
                    Install-NAVApp -ServerInstance "$localPublishAppInstance" -Tenant Default -Name "$localPublishAppName" -Publisher "$localPublishAppPublisher"
                    $localPublishAppNavApp = (Get-NAVAppInfo -ServerInstance "$localPublishAppInstance" -Tenant Default -TenantSpecificProperties -Name "$localPublishAppName" -Publisher "$localPublishAppPublisher")
                }
            }
        }
        Get-NAVAppInfo -ServerInstance "$localPublishAppInstance" -Tenant Default -TenantSpecificProperties -Publisher "$localPublishAppPublisher" | Sort-Object -Property "Name" | Format-Table -Property "Scope","Version","ExtensionDataVersion","SyncState","IsPublished","IsInstalled","Publisher","Name"
    }

    if ( ($localPublishAppContainer -ne "") -and ($localPublishAppFolder -ne "") )
    {
        if ((Test-Path -Path $localPublishAppFolder) -eq $true)
        {
            $localPublishAppJson = (Join-Path $localPublishAppFolder "app.json")

            if ((Test-Path -Path $localPublishAppJson) -eq $true)
            {
                $localPublishAppJsonContent  = (Get-Content $localPublishAppJson | ConvertFrom-Json)
                if ($localPublishAppJsonContent)
                {
                    $localPublishAppName      = $localPublishAppJsonContent.Name
                    $localPublishAppPublisher = $localPublishAppJsonContent.Publisher
                    $localPublishAppVersion   = $localPublishAppJsonContent.Version
                    $localPublishAppSession   = $null

                    try
                    { $localPublishAppSession = Get-NavContainerSession -containerName $localPublishAppContainer -silent }
                    catch
                    { $localPublishAppSession = $null }

                    if ($localPublishAppSession -ne $null)
                    {
                        Invoke-Command -ScriptBlock $localPublishAppScriptBlock -ArgumentList $localPublishAppArtifacts,$localPublishAppName,$localPublishAppPublisher,$localPublishAppVersion,$appVerify -Session $localPublishAppSession
                    }
                }
            }
        }
    }

    Remove-Variable localPublishApp*
}

function Runtime-ThisNavApp
{
    Param(
        [Parameter(Mandatory=$true)]
        [string]       $containerName = $CommonContainerName, # $(DockerName)
        [Parameter(Mandatory=$true)]
        [string]       $appJson       = "",
        [string]       $pfxFile       = $PgsCertFile,
        [SecureString] $pfxPassSecure = $PgsCertPass,
        [string]       $pfxPass       = ""
    )

    $localRuntimeContainer   = MyContainerName($containerName)
    $localRuntimeContainerId = MyContainerId($localRuntimeContainer)
    $localRuntimeJson        = $appJson
    $localRuntimeCertFile    = $pfxFile
    if (MyEmptyString($localRuntimeCertFile))
    {
    $localRuntimeCertFile    = (Join-Path $PSScriptRoot "*.pfx")
    }
    $localRuntimeCertFile    = (Get-Item $localRuntimeCertFile).FullName
    $localRuntimeCertPass    = $pfxPassSecure
    if ($localRuntimeCertPass -eq $null)
    {
    $localRuntimeCertPass    = (ConvertTo-SecureString "$pfxPass" -AsPlainText -Force)
    }
    $localRuntimeScriptBlock = 
    {Param($localRuntimeName,$localRuntimeVersion,$localRuntimeOutput)
        $localRuntimeInstance  = (Get-NAVServerInstance).ServerInstance.Replace("MicrosoftDynamicsNavServer$","")

        Write-Output "Generating runtime, $localRuntimeOutput"

        Get-NAVAppRuntimePackage -ServerInstance "$localRuntimeInstance" -AppName "$localRuntimeName" -Version "$localRuntimeVersion" -ExtensionPath "$localRuntimeOutput"
    }

    if (!(MyEmptyString($localRuntimeContainerId)))
    {
        $localRuntimeSession = $null
        try   { $localRuntimeSession = Get-NavContainerSession -containerName $localRuntimeContainer -silent }
        catch { $localRuntimeSession = $null }

        if ($localRuntimeSession -ne $null)
        {
            $localRuntimeFolder    = (Get-Item $localRuntimeJson).DirectoryName
            $localRuntimeContent   = (Get-Content $localRuntimeJson | ConvertFrom-Json)
            $localRuntimeName      = $localRuntimeContent.Name
            $localRuntimePublisher = $localRuntimeContent.Publisher.ToString()
            $localRuntimeVersion   = $localRuntimeContent.Version.ToString()
            $localRuntimeOutput    = (Join-Path $localRuntimeFolder ($localRuntimePublisher + '_' + $localRuntimeName + '_' + "$localRuntimeVersion" + '_runtime.app'))
            $localRuntimeAppInfo   = (Get-NavContainerAppInfo -containerName "$localRuntimeContainer" -tenantSpecificProperties | Where-Object {$_.Name -eq "$localRuntimeName"})
            if ($localRuntimeAppInfo -ne $null)
            {
                Invoke-Command -ScriptBlock $localRuntimeScriptBlock -ArgumentList $localRuntimeName,$localRuntimeVersion,$localRuntimeOutput -Session $localRuntimeSession

                if ((Test-Path -Path $localRuntimeOutput) -eq $true)
                {
                    if ( ($localRuntimeCertPass -ne $null) -and ($localRuntimeCertFile -ne $null) -and ($localRuntimeCertPass -ne "") -and ($localRuntimeCertFile -ne "") )
                    {
                        if ((Test-Path -Path $localRuntimeCertFile) -eq $true)
                        {
                            Write-Output "Signing    runtime, $localRuntimeOutput"
                           #Sign-NavContainerApp -containerName $localRuntimeContainer -appFile "$localRuntimeOutput" -pfxFile $localRuntimeCertFile -pfxPassword $localRuntimeCertPass
                            Sign-PclAssembly     -appFile "$localRuntimeOutput" -pfxFile $localRuntimeCertFile -pfxPassword $localRuntimeCertPass
                        }
                        else
                        {
                            Write-Output "WARNING: Missing certificate file $localRuntimeCertFile"
                        }
                    }
                    else
                    {
                        Write-Output "WARNING: Missing certificate information for $localRuntimeOutput"
                    }
                }
                else
                {
                    Write-Output "Missing    runtime, $localRuntimeOutput"
                }
            }
        }
    }

    Remove-Variable localRuntime*
}

function Check-ThisNavAppDependencies
{
    Param(
        [string] $containerName    = $CommonContainerName,
        [string] $appFolderObjects = ""
    )

    $localCheckContainer = MyContainerName($containerName)
    $localCheckAppFolder = $appFolderObjects

    if (Test-Path $localCheckAppFolder)
    {
        $localCheckAppJson = (Join-Path $localCheckAppFolder "app.json")
        if (Test-Path $localCheckAppJson)
        {
            $localCheckApps       = (Get-NavContainerAppInfo -containerName $localCheckContainer) | Sort-Object -Property "Name"

            $localCheckAppContent = (Get-Content -Path $localCheckAppJson | ConvertFrom-Json)
            if ($localCheckAppContent)
            {
                $localCheckFindAll = $true
                foreach ($localCheckDependency in $localCheckAppContent.dependencies)
                {
                    Write-Output ("Checking for " + $localCheckDependency.Name) # AppId, Name, Version, Publisher

                    $localCheckFindApp = $false
                    foreach ($localCheckAppInfo in $localCheckApps)
                    {
                        if ( ($localCheckAppInfo.AppId -eq $localCheckDependency.AppId) -or ($localCheckAppInfo.AppId -eq $localCheckDependency.Id) -or ($localCheckAppInfo.Id -eq $localCheckDependency.Id) )
                        {
                            if ($localCheckAppInfo.Name -eq $localCheckDependency.Name)
                            {
                                if ($localCheckAppInfo.Version -ge $localCheckDependency.Version)
                                {
                                    $localCheckFindApp = $true
                                }
                                else
                                {
                                    Write-Output ("Version mismatch " + $localCheckDependency.Name)
                                }
                            }
                        }
                    }
                    if ($localCheckFindApp -eq $true)
                    {
                        Write-Output ("FOUND " + $localCheckDependency.Name)
                    }
                    else
                    {
                        Write-Output ("NOT FOUND " + $localCheckDependency.Name)
                        $localCheckFindAll = $false
                    }
                }
                if ($localCheckFindAll -eq $false)
                {
                    Write-Error ("Missing dependencies.")
                }
            }
        }
    }

    Remove-Variable localCheck*
}

function Analyze-ThisNavApp-AppSourceCop
{
    Param(
        [string]  $containerName    = $CommonContainerName,
        [string]  $containerUser    = $PgsNavUser,
        [string]  $containerPass    = $PgsNavPass,
        [string]  $appFolderObjects = $PSScriptRoot,
        [string]  $appFolderOutput  = $PSScriptRoot,
        [string]  $appResultName    = 'AppSourceCop.txt',
        [boolean] $AzureDevOps      = $false
    )

    [string]       $localAnalyzeContainer  = $containerName
    [string]       $localAnalyzeObjects    = $appFolderObjects
    [string]       $localAnalyzeOutput     = $appFolderOutput
    [PSCredential] $localAnalyzeCredential = [PSCredential]::new("$containerUser", (ConvertTo-SecureString -String "$containerPass" -AsPlainText -Force))
    [string]       $localAnalyzePackages   = (Join-Path $localAnalyzeObjects ".alpackages")
    [string]       $localAnalyzeResultBase = $appResultName
    [string]       $localAnalyzeResultTemp = (Join-Path $env:TEMP           $localAnalyzeResultBase)
    [string]       $localAnalyzeResult     = (Join-Path $localAnalyzeOutput $localAnalyzeResultBase)

    if ( ($localAnalyzeContainer -ne "") -and ($localAnalyzeObjects -ne "") -and ($localAnalyzeOutput -ne "") )
    {
        if ((Test-Path -Path $localAnalyzeObjects) -eq $true)
        {
            if ((Test-Path -Path $localAnalyzeOutput) -eq $false)
            {
                New-Item -ItemType Directory -Force -Path "$localAnalyzeOutput"
            }
            if ((Test-Path -Path $localAnalyzePackages) -eq $true)
            {
                Remove-Item ("$localAnalyzePackages\*.app") -Force
            }
            if ((Test-Path -Path $localAnalyzeResultTemp) -eq $true)
            {
                Remove-Item ("$localAnalyzeResultTemp") -Force
            }
            $localAnalyzeError = $null
            if ($AzureDevOps -eq $true)
            {
                Compile-AppInNavContainer -containerName $localAnalyzeContainer -credential $localAnalyzeCredential -appProjectFolder $localAnalyzeObjects -appOutputFolder $localAnalyzeOutput -UpdateSymbols -EnableAppSourceCop -ErrorAction Continue -ErrorVariable localAnalyzeError -AzureDevOps *>>$localAnalyzeResultTemp
            }
            else
            {
                Compile-AppInNavContainer -containerName $localAnalyzeContainer -credential $localAnalyzeCredential -appProjectFolder $localAnalyzeObjects -appOutputFolder $localAnalyzeOutput -UpdateSymbols -EnableAppSourceCop -ErrorAction Continue -ErrorVariable localAnalyzeError *>>$localAnalyzeResultTemp
            }
            if ((Test-Path -Path $localAnalyzeResultTemp) -eq $true)
            {
                Copy-Item "$localAnalyzeResultTemp" "$localAnalyzeResult" -Force
            }
            if ( ($localAnalyzeError -ne $null) -and ($localAnalyzeError -ne "") )
            {
                Write-Output ("ERROR: The selected CodeAnalyzer has failed; please review the [$localAnalyzeResultBase] file for details.")
            }
        }
    }

    Remove-Variable localAnalyze*
}

function Update-ThisNavApp-Builds
{
    Param(
        [string]  $appFolderObjects = $PSScriptRoot,
        [boolean] $latestOnly       = $true
    )

    $localBuildsObjects    = $appFolderObjects
    $localBuildsLatestOnly = $latestOnly

    if ( ($localBuildsObjects -ne "") -and ($localBuildsObjects -ne $null) )
    {
        $localBuildsContent = (Get-Content (Join-Path $PSScriptRoot "Builds.json") | ConvertFrom-Json)
        $localBuildsCount   = 0

        foreach ($localBuildsCurrent in $localBuildsContent)
        {
            [string] $localBuildsCurrentTag    = $localBuildsCurrent[0].Tag.Trim()
            [string] $localBuildsCurrentBuild  = $localBuildsCurrent[0].Build.Trim()

            Write-Output ("Processing - " + "Count = " + $localBuildsCount.ToString() + ", Tag = " + $localBuildsCurrentTag + ", Build = " + $localBuildsCurrentBuild)

            if ($localBuildsObjects -ne "")
            {
                $localBuildsFiles = Get-ChildItem (Join-Path $localBuildsObjects "*.al") -recurse -force
                ForEach ($localBuildsFile in $localBuildsFiles)
                {
                    if ($localBuildsFile.FullName -like "*.al")
                    {
                        [string] $localBuildsCurrentFile = $localBuildsFile.FullName.Trim()


                        [byte[]] $localBuildsCurrentFileByte = Get-content -Encoding byte -ReadCount 4 -TotalCount 4 -Path $localBuildsCurrentFile

                        if     ($localBuildsCurrentFileByte[0] -eq 0xef -and $localBuildsCurrentFileByte[1] -eq 0xbb -and $localBuildsCurrentFileByte[2] -eq 0xbf)
                            { $localBuildsCurrentEncoding = 'UTF8' }  
                        elseif ($localBuildsCurrentFileByte[0] -eq 0xfe -and $localBuildsCurrentFileByte[1] -eq 0xff)
                            { $localBuildsCurrentEncoding = 'BigEndianUnicode' }
                        elseif ($localBuildsCurrentFileByte[0] -eq 0xff -and $localBuildsCurrentFileByte[1] -eq 0xfe)
                            { $localBuildsCurrentEncoding = 'Unicode' }
                        elseif ($localBuildsCurrentFileByte[0] -eq 0 -and $localBuildsCurrentFileByte[1] -eq 0 -and $localBuildsCurrentFileByte[2] -eq 0xfe -and $localBuildsCurrentFileByte[3] -eq 0xff)
                            { $localBuildsCurrentEncoding = 'UTF32' }
                        elseif ($localBuildsCurrentFileByte[0] -eq 0x2b -and $localBuildsCurrentFileByte[1] -eq 0x2f -and $localBuildsCurrentFileByte[2] -eq 0x76)
                            { $localBuildsCurrentEncoding = 'UTF7'}
                        else
                            { $localBuildsCurrentEncoding = 'ASCII' }

                        [string] $localBuildsCurrentTextStart  = [System.IO.File]::ReadAllText($localBuildsCurrentFile)

                        [string] $localBuildsCurrentTextBefore = $localBuildsCurrentTextStart
                        [string] $localBuildsCurrentSource     = ('(version\s|,)(PJMT' + $localBuildsCurrentTag + ')(,)+PGS([\d]+\.[\d]+\.[\d]+\.[\d]+)')
                        [string] $localBuildsCurrentDestin     = ('$1$2,PGS' + $localBuildsCurrentBuild)
                        [string] $localBuildsCurrentTextAfter  = [regex]::Replace($localBuildsCurrentTextBefore, $localBuildsCurrentSource, $localBuildsCurrentDestin, "Singleline")

                        [string] $localBuildsCurrentTextBefore = $localBuildsCurrentTextAfter
                        [string] $localBuildsCurrentSource     = ('(version\s|,)(PJMT' + $localBuildsCurrentTag + ')(\s)')
                        [string] $localBuildsCurrentDestin     = ('$1$2,PGS' + $localBuildsCurrentBuild + '$3')
                        [string] $localBuildsCurrentTextAfter  = [regex]::Replace($localBuildsCurrentTextBefore, $localBuildsCurrentSource, $localBuildsCurrentDestin, "Singleline")

                        [string] $localBuildsCurrentTextFinish = $localBuildsCurrentTextAfter

                        [string] $localBuildsCurrentMessage    = "Count = " + $localBuildsCount.ToString() + ", Tag = " + $localBuildsCurrentTag + ", Build = " + $localBuildsCurrentBuild + ", Encoding = " + $localBuildsCurrentEncoding + ", File = " + (Split-Path -Path $localBuildsCurrentFile -Leaf)

                        if ($localBuildsCurrentTextStart -ne $localBuildsCurrentTextFinish)
                        {
                            Write-Output ("Processing - " + $localBuildsCurrentMessage)

                            [System.IO.File]::WriteAllText($localBuildsCurrentFile, ($localBuildsCurrentTextFinish))
                        }
                        else
                        {
                            Write-Output ("Skipping   - " + $localBuildsCurrentMessage)
                        }

                        Remove-Variable localBuildsCurrentText*
                    }
                }

            }
            if ($localBuildsLatestOnly -eq $true)
            {
                break
            }
            $localBuildsCount += 1
        }
    }

    Remove-Variable localBuilds*
}

function Deploy-ThisNavApp
{
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

    $localDeployContainer  = MyContainerName($containerName)
    $localDeployOkay      = $true
    $localDeployArtifacts = $appArtifacts
    $localDeployObjects   = $appObjects
    $localDeployAppJson   = (Join-Path -Path $localDeployObjects -ChildPath "app.json")

    if (MyEmptyString($localDeployContainer))
    {
        Throw ("Container name is blank")
    }
    if (!(Test-Path $localDeployObjects))
    {
        Throw ("Missing [" + $localDeployObjects + "]")
    }
    if (!(Test-Path $localDeployAppJson))
    {
        Throw ("Missing [" + $localDeployAppJson + "]")
    }

    $localDeployAppName = (Get-Content $localDeployAppJson | ConvertFrom-Json).Name
    $localDeployAppSync = (Get-NavContainerAppInfo -containerName $localDeployContainer | Where-Object {($_.Name -eq "$localDeployAppName")})

    Unpublish-ThisNavApp -containerName $localDeployContainer -appJson $localDeployAppJson

    if ($localDeployAppSync)
    {
    Sync-ThisNavApp      -containerName $localDeployContainer
    }

    if ($localDeployOkay -eq $true)
    {
    Compile-ThisNavApp   -containerName $localDeployContainer -appFolderObjects $localDeployObjects -userName $userName -userPass $userPass -pfxFile $pfxFile -pfxPassSecure $pfxPassSecure -pfxPass $pfxPass
    Publish-ThisNavApp   -containerName $localDeployContainer -appFolderObjects $localDeployObjects
    Runtime-ThisNavApp   -containerName $localDeployContainer -appJson $localDeployAppJson                                                  -pfxFile $pfxFile -pfxPassSecure $pfxPassSecure -pfxPass $pfxPass
    }

    if ( ($localDeployOkay -eq $true) -and ( ($localDeployArtifacts -ne $null) -and ($localDeployArtifacts -ne "") ) )
    {
        Copy-Item (Join-Path $localDeployObjects "*.app") -Destination $localDeployArtifacts
    }

    Remove-Variable localDeploy*
}

function Run-ThisNavAppTests
{
    Param (
        [string]       $containerName  = $CommonContainerName,
        [string]       $cmdBaseName    = "",
        [string]       $folderApp      = $PSScriptRoot,        # "$(Build.SourcesDirectory)"
        [string]       $folderOut      = $PSScriptRoot,        # "$(System.ArtifactsDirectory)"
        [string]       $userName       = "",                   # "$(PgsUsername)"
        [string]       $userPassword   = "",                   # "$(PgsPassword)"
        [PSCredential] $userCredential = $null,
        [boolean]      $skipTests      = $false
    )

    $lTstContainer   = $containerName.Replace("_","-").Replace(".","-").Replace(" ","-")
    $lTstFolderApp   = $folderApp
    $lTstFolderOut   = $folderOut
    $lTstCmdBaseName = $cmdBaseName
    $lTstResultsName = ($lTstCmdBaseName + ".xml")
    $lTstResultsFile = (Join-Path $lTstFolderOut $lTstResultsName)
    $lTstSuite       = 'Default'
    $lTstCredential  = $userCredential
    if ( ($userCredential -eq $null) -and ($userName -ne "") -and ($userPassword -ne "") )
    {
        $lTstCredential = [PSCredential]::new("$userName", (ConvertTo-SecureString -String "$userPassword" -AsPlainText -Force))
    }

    if ($lTstCredential -ne $null)
    {
        if ( ( (Test-NavContainer -containerName $lTstContainer) -eq $true) )
        {
            if (Test-Path $lTstFolderApp)
            {
                $lTstListName = ($lTstCmdBaseName + ".json")
                $lTstListJson = (Join-Path $folderApp $lTstListName)
                if ( !(Test-Path $lTstListJson) )
                {
                    $lTstListJson = (Join-Path $PSScriptRoot $lTstListName)
                }
                if (Test-Path $lTstListJson)
                {
                    Write-Output ("Using " + $lTstListJson)

                    $lTstAppJson = (Join-Path $lTstFolderApp "app.json")
                    if (Test-Path $lTstAppJson)
                    {
                        $lTstAppContent = (Get-Content -Path $lTstAppJson | ConvertFrom-Json)
                        if ($lTstAppContent)
                        {
                            $lTstResultsTemp = (Join-Path "C:\ProgramData\NavContainerHelper\Extensions\$lTstContainer" $lTstResultsName)
                            $lTstIsFirst     = $true
                            $lTstErrors      = $false
                            $lTstObjects     = Get-TestsFromBCContainer -containerName $lTstContainer -extensionId $lTstAppContent.Id -credential $lTstCredential -testSuite $lTstSuite -ignoreGroups -debugMode

                            if ($lTstObjects -eq $null)
                            {
                                Write-Output ("No tests were returned.")
                            }
                            else
                            {
                                if ($lTstObjects.Count -eq 0)
                                {
                                    Write-Output ("No tests were returned.")
                                }
                                else
                                {
                                    $lTstListContent = (Get-Content -Path $lTstListJson | ConvertFrom-Json)
                                    if ($lTstListContent)
                                    {
                                        $lTstListContent.Tests | ForEach-Object {

                                            $lTstListContentId = $_.Id
                                            $lTstOk2Run        = $false

                                            $lTstObjects | ForEach-Object {
                                                if ([int]$_.Id -eq [int]$lTstListContentId) { $lTstOk2Run = $true }
                                            }
                                            if ($skipTests -eq $true)
                                            {
                                                $lTstOk2Run = $false
                                            }
                                            if ($lTstOk2Run -eq $true)
                                            {
                                                Write-Output ("Running " + $lTstListContentId)

                                                if (!(Run-TestsInBcContainer `
                                                    -containerName $lTstContainer `
                                                    -credential $lTstCredential `
                                                    -extensionId $lTstAppContent.Id `
                                                    -testSuite $lTstSuite `
                                                    -testCodeunit $lTstListContentId `
                                                    -detailed `
                                                    -XUnitResultFileName $lTstResultsTemp `
                                                    -AppendToXUnitResultFile:(!$lTstIsFirst) `
                                                    -returnTrueIfAllPassed `
                                                    -debugMode))
                                                {
                                                    $lTstErrors = $true
                                                }
                                                $lTstIsFirst = $false
                                            }
                                            else
                                            {
                                                Write-Output ("Skipping " + $lTstListContentId)
                                            }
                                        }
                                    }
                                    else
                                    {
                                        Write-Output ("[" + $lTstListJson + "] contains no data.")
                                    }
                                }
                                if (Test-Path $lTstResultsTemp)
                                {
                                    Copy-Item -Path $lTstResultsTemp -Destination $lTstResultsFile -Force
                                }
                            }

                        }
                    }
                }
                else
                {
                    Write-Output ("[" + $lTstListJson + "] is missing.")
                }
            }
        }
    }
    else
    {
        Write-Output ("Credential is null.")
    }

    Remove-Variable lTst*
}
