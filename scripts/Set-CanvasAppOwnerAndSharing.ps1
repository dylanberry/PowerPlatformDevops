param(  
  [Parameter(Mandatory=$true)]
  [string]$EnvironmentName,
  
  [Parameter(Mandatory=$true)]
  [string]$OwnerAccountEmail,
  
  [Parameter]
  [string]$ViewerGroup
)

If(-not(Get-InstalledModule Microsoft.PowerApps.Administration.PowerShell -ErrorAction silentlycontinue)) {
  Set-PSRepository PSGallery -InstallationPolicy Trusted
  Install-Module Microsoft.PowerApps.Administration.PowerShell -Confirm:$False -Force -AllowClobber -MaximumVersion 2.0.102
}
Import-Module Microsoft.PowerApps.Administration.PowerShell

Add-PowerAppsAccount

$environment = Get-AdminPowerAppEnvironment | ? {$_.DisplayName -like "$EnvironmentName*"}

$canvasApps = Get-AdminPowerApp -EnvironmentName $environment.EnvironmentName | ? {$_.Owner | Select | ? type -eq "ServicePrincipal"} | Select *
$ownerAccount = Get-UsersOrGroupsFromGraph -SearchString $OwnerAccountEmail | ? {$_.UserPrincipalName -eq $OwnerAccountEmail}

if ($ViewerGroup) {
  $groupAccount = Get-UsersOrGroupsFromGraph -SearchString $ViewerGroup | ? {$_.DisplayName -eq $ViewerGroup}
}

Foreach ($canvasApp in $canvasApps) {
    Set-AdminPowerAppOwner -AppName $canvasApp.AppName -EnvironmentName $environment.EnvironmentName -AppOwner $ownerAccount.ObjectId
    Set-AdminPowerAppRoleAssignment -AppName $canvasApp.AppName -EnvironmentName $environment.EnvironmentName -RoleName "CanEdit" -PrincipalType "User" -PrincipalObjectId $ownerAccount.ObjectId -Verbose
    
    if ($ViewerGroup) {
      Set-AdminPowerAppRoleAssignment -AppName $canvasApp.AppName -EnvironmentName $environment.EnvironmentName -RoleName "CanView" -PrincipalType "Group" -PrincipalObjectId $groupAccount.Objectd -Verbose
    }
}