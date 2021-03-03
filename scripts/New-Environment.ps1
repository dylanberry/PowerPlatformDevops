param(  
  [Parameter(Mandatory=$true)]
  [string]$AzureDevOpsOrganization,
  
  [Parameter(Mandatory=$true)]
  [string]$AzureDevOpsProject,
  
  [Parameter(Mandatory=$true)]
  [string]$AzureDevOpsPipelineId,
  
  [Parameter(Mandatory=$true)]
  [string]$SolutionSourceBranch,
  
  [Parameter(Mandatory=$true)]
  [string]$VariableGroupName,
  
  [Parameter(Mandatory=$true)]
  [string]$DeploymentPipelineId,
  
  [Parameter()]
  [string]$TenantId,
  
  [Parameter()]
  [string]$ClientId,
  
  [Parameter()]
  [string]$ClientSecret,

  [Parameter()]
  [System.Management.Automation.PSCredential]$AzureDevOpsCredentials,

  [Parameter()]
  [System.Management.Automation.PSCredential]$PowerPlatformCredentials,
  
  [Parameter()]
  [string]$PowerPlatformEnvironmentName,
  
  [Parameter()]
  [string]$PowerPlatformEnvironmentDomain,

  [Parameter()]
  [string]$LocationName,

  [Parameter()]
  [string]$EnvironmentSku,

  [Parameter()]
  [string[]]$Templates
)

# Prerequisites
# Install az cli
#Invoke-WebRequest -Uri https://aka.ms/installazurecliwindows -OutFile .\AzureCLI.msi; Start-Process msiexec.exe -Wait -ArgumentList '/I AzureCLI.msi /quiet'
az extension add --name azure-devops

If(-not(Get-InstalledModule Microsoft.Xrm.OnlineManagementAPI -ErrorAction silentlycontinue)) {
    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module Microsoft.Xrm.OnlineManagementAPI -Confirm:$False -Force -AllowClobber
}
Import-Module Microsoft.Xrm.OnlineManagementAPI


# Login user
if ($PowerPlatformCredentials) {
    Add-PowerAppsAccount -Username $PowerPlatformCredentials.UserName -Password $PowerPlatformCredentials.Password
} else {
    Read-Host "Press enter to login with your Power Platform credentials"
    Add-PowerAppsAccount
}

if ($AzureDevOpsCredentials) {
    az login --allow-no-subscriptions -u $AzureDevOpsCredentials.UserName -p $AzureDevOpsCredentials.Password
} else {
    Read-Host "Press enter to login with your Azure DevOps credentials"
    az login --allow-no-subscriptions
}

# Determine environment name from user name and date
$azureDevOpsUserDetails = az ad signed-in-user show | ConvertFrom-Json
$userName = $azureDevOpsUserDetails.DisplayName.ToLower().Replace(' ', '')

$generatedEnvironmentName = $userName + "-" + ([DateTime]::Now).ToString("yyyy-MM-dd-hh-mm")

if (-not $PowerPlatformEnvironmentName) {
    $PowerPlatformEnvironmentName = $generatedEnvironmentName
}

if (-not $PowerPlatformEnvironmentDomain) {
    $PowerPlatformEnvironmentDomain = $generatedEnvironmentName
}


# Create environment
Write-Host "Creating environment $PowerPlatformEnvironmentName"
$newEnvironmentResult = New-AdminPowerAppEnvironment -DisplayName $PowerPlatformEnvironmentName `
    -LocationName $LocationName `
    -EnvironmentSku $EnvironmentSku `
    -ProvisionDatabase `
    -Templates $Templates `
    -DomainName $PowerPlatformEnvironmentDomain `
    -WaitUntilFinished $true

$newEnvironmentUrl = $newEnvironmentResult.Internal.properties.linkedEnvironmentMetadata.instanceUrl
Write-Host "Created environment $newEnvironmentUrl"


# Lookup ClientId from variable group
if (-not $ClientId) {
    # First see if there is an environment specific client id
    $environmentClientIdVariableName = $PowerPlatformEnvironmentName + '_clientid'
    Write-Host "Looking up variable $environmentClientIdVariableName"
    $vg = az pipelines variable-group list `
        --org "https://dev.azure.com/$AzureDevOpsOrganization" `
        --project $AzureDevOpsProject `
        --group-name $VariableGroupName | ConvertFrom-Json
    $vg
    $ClientId = $vg.variables.psobject.properties | ? Name -like $environmentClientIdVariableName
    
    if (-not $ClientId) {      
        Write-Host "Looking up variable ClientId"
        # if no environment specific client id, get the generic client id
        $ClientId = $vg.variables.psobject.properties | ? Name -eq 'ClientId'
    }
}


# Create application user and grant system administrator
if (-not(Get-InstalledModule Microsoft.Xrm.Data.PowerShell -ErrorAction silentlycontinue)) {
  Set-PSRepository PSGallery -InstallationPolicy Trusted
  Install-Module Microsoft.Xrm.Data.PowerShell -Confirm:$False -Force -AllowClobber
}
Import-Module Microsoft.Xrm.Data.Powershell

if ($PowerPlatformCredentials) {
    Connect-CrmOnline -Credential $PowerPlatformCredentials -ServerUrl $newEnvironmentUrl
} else {
    Connect-CrmOnline -ServerUrl $newEnvironmentUrl
}

Write-Host "Looking up root business unit"
$buLookup = New-Object -TypeName Microsoft.Xrm.Sdk.EntityReference;
$buLookup.LogicalName = "businessunit"
$buLookup.Id = (Get-CrmRecords -EntityLogicalName businessunit -Fields * -FilterAttribute parentbusinessunitid -FilterOperator null).CrmRecords.businessunitid
#NOTE: application user metadata is ignored
Write-Host "Creating application user $ClientId"
$applicationUser = New-CrmRecord -EntityLogicalName systemuser -Fields @{"applicationid"=[System.guid]::New($ClientId) ; "fullname"="";"internalemailaddress"="";"businessunitid"=$buLookup}
$applicationUser

$systemAdminRole = (Get-CrmRecords -EntityLogicalName role -FilterAttribute "name" -FilterOperator eq -FilterValue "System Administrator" -Fields *).CrmRecords
$global:SecurityRoleName = "System Administrator"
Write-Host "Adding System Administrator role to application user"
Add-CrmSecurityRoleToUser -UserId $applicationUser -SecurityRoleId $systemAdminRole.roleid


# Queue new environment pipeline
$azureDevopsResourceId = "499b84ac-1321-427f-aa17-267ca6975798"

$token = az account get-access-token --resource $azureDevopsResourceId | ConvertFrom-Json
$authValue = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(":" + $token.accessToken))

$devopsProjectUrl = "https://dev.azure.com/$AzureDevOpsOrganization/$AzureDevOpsProject"

$headers = @{
    Authorization = "Basic $authValue";
    'X-VSS-ForceMsaPassThrough' = $true
 }

$templateParameters = @{
    EnvironmentUrl = $newEnvironmentUrl;
    EnvironmentName = $PowerPlatformEnvironmentName;
    VariableGroupName = $VariableGroupName;
    TenantId = $TenantId;
    ClientId = $ClientId;
    ClientSecret = $ClientSecret;
    DeploymentPipelineId = $DeploymentPipelineId
}

$body = @{
    templateParameters = $templateParameters;
    resources = @{repositories = @{self = @{refName = "refs/heads/$SolutionSourceBranch"}}}
}
$json = $body | ConvertTo-Json -Depth 32

$pipelineRunUrl = "$devopsProjectUrl/_apis/pipelines/$AzureDevOpsPipelineId/runs?api-version=6.0-preview.1"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host "Starting environment setup pipeline"
$pipelineRunResponse = Invoke-RestMethod -Uri $pipelineRunUrl `
    -Method POST -Headers $headers -ContentType 'application/json' `
    -Body $json -Verbose