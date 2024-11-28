#############################################################################################

# Define Variables
param (
    [string]$workspacename,
    [string]$filepath,
    [string]$reportName,
    [string]$clientId,
    [string]$clientSecret,
    [string]$SQLserver,
    [string]$SQLdb,
    [string]$tenantId
)

# Import Module
Install-Module -Name MicrosoftPowerBIMgmt -Force
Import-Module -Name MicrosoftPowerBIMgmt -Force


#############################################################################################

# Connect to Power BI Service using the service principal
$secureClientSecret = ConvertTo-SecureString -String $clientSecret -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential ($clientId, $secureClientSecret)

Connect-PowerBIServiceAccount -Tenant $tenantId -ServicePrincipal -Credential $credential -Verbose


# Get workspaceId (currently without error exclusion) could also be called group id
$workspaces = Invoke-PowerBIRestMethod -Url "groups" -Method Get | ConvertFrom-Json
$workspace = $workspaces.value | Where-Object { $_.name -eq $workspacename }
if ($null -eq $workspace) {
    throw "Report $workspacename not found."
}
$workspaceId = $workspace.id


# Publish the PowerBI Report
if (Test-Path -Path $filePath) {
    New-PowerBIReport -Path $filePath -WorkspaceId $workspaceId -ConflictAction 'CreateOrOverwrite'
} else {
    Write-Host "The specified .pbix file was not found: $filePath"
}


# Get Dataset ID from report name (only if one dataset per report) no case for more than 1 dataset
$reports = Invoke-PowerBIRestMethod -Url "groups/$workspaceId/reports" -Method Get | ConvertFrom-Json
$report = $reports.value | Where-Object { $_.name -eq $reportName}
if ($null -eq $report) {
    throw "Report $reportName not found."
}
$datasetId = $report.datasetId


# Take ownership of the dataset
Invoke-PowerBIRestMethod -Method POST -Url "groups/$workspaceId/datasets/$datasetId/Default.TakeOver" -Body "{}" # empty body so I get no alert


#############################################################################################

# Define Login credentials
$body = @{
    grant_type    = "client_credentials"
    client_id     = $clientId
    client_secret = $clientSecret
    scope         = "https://analysis.windows.net/powerbi/api/.default"
}

# Get Access token
$token = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -ContentType "application/x-www-form-urlencoded" -Body $body -Method Post
$accessToken = $token.access_token 


# Get gatewayId
$datasources = Invoke-PowerBIRestMethod -Url "groups/$workspaceId/datasets/$datasetId/datasources" -Method Get | ConvertFrom-Json
$datasource = $datasources.value

$datasourceId = $datasource.datasourceId
$gatewayId = $datasource.gatewayId


#############################################################################################

# Body for parameter update
$params = @{
    updateDetails = @(
        @{
            name = "SQL_Server"
            newValue = $SQLserver
        },
        @{
            name = "SQL_DB"
            newValue = $SQLdb
        }
    )
} | ConvertTo-Json -Compress


# Body for Credential Update
$credentialsSP = "`"{\`"credentialData\`":[{\`"name\`":\`"tenantId\`",\`"value\`":\`"$TenantId\`"},{\`"name\`":\`"servicePrincipalClientId\`",\`"value\`":\`"$clientId\`"},{\`"name\`":\`"servicePrincipalSecret\`",\`"value\`":\`"$clientSecret\`"}]}`""
$bodySP = @"
      {
          "credentialDetails": {
              "credentialType": "ServicePrincipal",
              "credentials": $credentialsSP,
              "encryptedConnection": "Encrypted",
              "encryptionAlgorithm": "None",
              "privacyLevel": "Organizational"
          }
      }
"@

# Body for refresh schedule
$refreshSchedule = @{
    value = @{
        enabled = "true"
        days = @("Sunday", "Tuesday", "Friday", "Saturday")
        times = @("07:00", "09:30", "11:30", "16:00", "23:30")
        localTimeZoneId = "UTC"
        notifyOption = "NoNotification"
    }
} | ConvertTo-Json -Compress


#############################################################################################

# Update Parameters
Invoke-RestMethod -Method POST -Uri "https://api.powerbi.com/v1.0/myorg/groups/$workspaceId/datasets/$datasetId/Default.UpdateParameters" -Headers @{Authorization = "Bearer $accessToken"} -Body $params -ContentType "application/json" -Verbose


# Update Credentials
Invoke-PowerBIRestMethod -Url "gateways/$gatewayId/datasources/$datasourceId" -Method "Patch" -Body $bodySP -Verbose


# Set refresh schedule
Invoke-PowerBIRestMethod -url "https://api.powerbi.com/v1.0/myorg/groups/$workspaceId/datasets/$datasetId/refreshSchedule" -Method Patch -Body $refreshSchedule -Verbose


# Disconnect from the Power BI account
Disconnect-PowerBIServiceAccount