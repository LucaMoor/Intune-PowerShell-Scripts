##########################################
##
## ---===Get-AllIntuneAssignmentsFromGroups===---
##
## Description:
##    Gets all Intune Assignments from Groups you can specify and Exports it as a CSV
##
## Written by:
##   Luca Moor
##
## Written for:
##   Community
##
## Credits to:
##   Jannik Reinhard (https://jannikreinhard.com/2023/08/13/new-version-of-the-intune-group-assignment-script/)
##   Original Idea and some Parts of the Script are from him :)
##   I rewrote it to my needs and added Support for configurationPolicies and multiple Groups Input
##
## Version: 1.0
##
## Initial creation date: 23.08.2024
##
## Last change date: 23.10.2024
##########################################

<# VARIABLES #>

$Scopes = "DeviceManagementConfiguration.Read.All, DeviceManagementApps.ReadWrite.All"

<# Functions #>

#Initialisation
function Start-Initialisation {

    # Configure console output encoding
    $OutputEncoding = [System.Text.Encoding]::UTF8
    
    # Set ErrorActionPreference to "Stop" to terminate the Script on Error
    $ErrorActionPreference = "Stop"

    if (Get-Module -ListAvailable -Name Microsoft.Graph) {
        # Graph already installed, nothing to do
        Write-Host "Microsoft Graph is already installed" -ForegroundColor Green
    } else {
        try {
            # Graph is not installed, installing it in User Context to not request Admin Permissions
            Write-Host "Microsoft Graph needs to be installed, this will take some time..."
            Install-Module -Name Microsoft.Graph -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
        } catch {
            Write-Host -ForegroundColor Red "Encountered Error: $($_.Exception.Message)"
        }
    }

    # Connecting with Microsoft Graph with the needed Scope Permissions
    Connect-MgGraph -Scopes $Scopes -NoWelcome
    $groups = $null

    while ($null -eq $groups) {
        $aadGroupNames = Read-Host "Enter the name of the AAD Groups: "
        $groups = Get-GroupsByName -groupName $aadGroupNames
        if($null -eq $groups) {Write-Host "Groups not found. Try again" -ForegroundColor Red}
    }

    Write-Host "------------------------------"
    Write-Host "Groups Info" -ForegroundColor Yellow

    ForEach ($group in $groups) {
        Write-Host "------------------------------"
        Write-Host "Group Name: $($group.displayName)" -ForegroundColor Yellow
        Write-Host "Group Id: $($group.id)"
        Write-Host "Created Date Time: $($group.createdDateTime)"
    }

    # Add Properties to the Groups Object, to store the Configurations Profile Names
    $groupsProperties = @("configurationPolicies", "deviceConfigurations", "groupPolicyConfigurations", 
    "deviceCompliancePolicies", "mobileApps", "deviceManagementScripts" ,"deviceHealthScripts", 
    "windowsAutopilotDeploymentProfiles", "deviceEnrollmentConfigurations", "intents")

    ForEach ($property in $groupsProperties) {
        $groups | Add-Member -MemberType NoteProperty -Name $property -Value $null
    }

    Write-Host "Gathering all Configurations and Assignments. This may take a while." -ForegroundColor Yellow
    return $groups
}

function Get-GraphCallCustom {
    param(
        [Parameter(Mandatory)]$endpoint,
        [Parameter()]$headers,
        $value=$true
    )
    $uri = "https://graph.microsoft.com/beta/$endpoint"
    if($value -eq $true){
        return (Invoke-MgGraphRequest -Uri $uri -Headers $headers -Method Get -OutputType PSObject).Value
    }else{
        return Invoke-MgGraphRequest -Uri $uri -Headers $headers -Method Get -OutputType PSObject
    }
}

function Get-GroupsByName{
    param(
        [Parameter(Mandatory)]$groupName
    )
    if($groupName -eq "All users"){
        return [PSCustomObject]@{
            id               = 'acacacac-9df4-4c7d-9d50-4ef0226f57a9'
            createdDateTime  = '00/00/0000'
            displayName      = 'All users (System group)'
        }
    }
    if($groupName -eq "All devices"){
        return [PSCustomObject]@{
            id               = 'adadadad-808e-44e2-905a-0b7873a8a531'
            createdDateTime  = '00/00/0000'
            displayName      = 'All devices (System group)'
        }
    }

    return Get-GraphCallCustom -endpoint ('groups?$search="displayName:' + $groupName + '"&$select=id,displayName,createdDateTime') -headers @{ConsistencyLevel = "eventual"}
}

function Get-IntuneConfigurationAssignments {
    param (
        [Parameter(Mandatory)]$groups,
        [Parameter(Mandatory)]$uri,
        [Parameter(Mandatory)]$uriAssignment,
        [Parameter(Mandatory)]$type
    )

    # Get all Intune Configurations
    $configurations = (Get-GraphCallCustom -endpoint "$uri/$type")

    # Transform $configurations.name to $configurations.displayName because "configurationPolicies" return only .name
    if ($configurations | Where-Object { $_.PSObject.Properties.Name -contains "name" }) {
        $configurations = $configurations | ForEach-Object {
            $_ | Select-Object @{Name="displayName"; Expression={$_.name}}, * -ExcludeProperty name
        }
    }

    ForEach ($configuration in $configurations) {
        # Get all Assignments for each Configuration
        $assignmentsInfo = (Get-GraphCallCustom -endpoint ("$uri/$type/" + $configuration.id + "/$uriAssignment") -Value $False)

        # Transform Data to make it more accessible
        if($uriAssignment -eq "groupAssignments"){$assignments = $assignmentsInfo.value}
        elseif($uriAssignment -eq "assignments"){$assignments = $assignmentsInfo.value.target}

        # Transform $assignments.groupId to $assignments.targetGroupId because "configurationPolicies" return only .groupId
        if ($assignments | Where-Object { $_.PSObject.Properties.Name -contains "groupId" }) {
            $assignments = $assignments | ForEach-Object {
                $_ | Select-Object @{Name="targetGroupId"; Expression={$_.groupId}}, * -ExcludeProperty groupId
            }
        }

        ForEach ($assignment in $assignments) {
            ForEach ($group in $groups) {
                # Check for Includes for each Assignment for Each Group
                if ($uriAssignment -eq "groupAssignments" -And $assignment.targetGroupId -eq $group.Id -And (-Not $assignment.excludeGroup)) {
                    $group.$type += "+ $($configuration.displayName);"
                } elseif ($uriAssignment -eq "assignments" -And $assignment.targetGroupId -eq $group.Id -And $assignment.'@odata.type' -eq '#microsoft.graph.groupAssignmentTarget') {
                    $group.$type += "+ $($configuration.displayName);"
                } 
                # Special Checks for All Users and All Devices Groups
                elseif ($uriAssignment -eq "assignments" -and $group.Id -eq "acacacac-9df4-4c7d-9d50-4ef0226f57a9" -and $assignment.'@odata.type' -eq '#microsoft.graph.allLicensedUsersAssignmentTarget'){
                    $group.$type += "+ $($configuration.displayName);"
                } elseif ($uriAssignment -eq "assignments" -and $group.Id -eq "adadadad-808e-44e2-905a-0b7873a8a531" -and $assignment.'@odata.type' -eq '#microsoft.graph.allDevicesAssignmentTarget'){
                    $group.$type += "+ $($configuration.displayName);"
                }

                # Check for Excludes for each Assignment for Each Group
                if($uriAssignment -eq "groupAssignments" -and $assignment.targetGroupId -eq $group.Id -and $assignment.excludeGroup){
                    $group.$type += "- $($configuration.displayName);"
                } elseif ($uriAssignment -eq "assignments" -and $assignment.targetGroupId -eq $groupId -and $assignment.'@odata.type' -eq '#microsoft.graph.exclusionGroupAssignmentTarget'){
                    $group.$type += "- $($configuration.displayName);"
                }
            }
        }
    }
}

<# MAIN #>

# Start Initialisation Function
$groups = Start-Initialisation

# Start getting all the Intune Configuration Assignments
# Configuration Policies (Settings Catalog)
Write-Host "Working on: Configuration Policies" -ForegroundColor Green
Get-IntuneConfigurationAssignments -groups $groups -uri "deviceManagement" -type "configurationPolicies" -uriAssignment "assignments"

# Device Configuration Policies 
Write-Host "Working on: Device Configuration Policies" -ForegroundColor Green
Get-IntuneConfigurationAssignments -groups $groups -uri "deviceManagement" -type "deviceConfigurations" -uriAssignment "groupAssignments"

# Administrative Templates
Write-Host "Working on: Administrative Templates" -ForegroundColor Green
Get-IntuneConfigurationAssignments -groups $groups -uri "deviceManagement" -type "groupPolicyConfigurations" -uriAssignment "assignments"

# Device Compliance Policies
Write-Host "Working on: Device Compliance Policies" -ForegroundColor Green
Get-IntuneConfigurationAssignments -groups $groups -uri "deviceManagement" -type "deviceCompliancePolicies" -uriAssignment "assignments"

# Apps
Write-Host "Working on: Apps (takes especially longer)" -ForegroundColor Green
Get-IntuneConfigurationAssignments -groups $groups -uri "deviceAppManagement" -type "mobileApps" -uriAssignment "assignments"

# Platform Scripts
Write-Host "Working on: Platform Scripts" -ForegroundColor Green
Get-IntuneConfigurationAssignments -groups $groups -uri "deviceManagement" -type "deviceManagementScripts" -uriAssignment "assignments"

# Remediation Scripts
Write-Host "Working on: Remediation Scripts" -ForegroundColor Green
Get-IntuneConfigurationAssignments -groups $groups -uri "deviceManagement" -type "deviceHealthScripts" -uriAssignment "assignments"

# Autopilot Profile
Write-Host "Working on: Autopilot Profile" -ForegroundColor Green
Get-IntuneConfigurationAssignments -groups $groups -uri "deviceManagement" -type "windowsAutopilotDeploymentProfiles" -uriAssignment "assignments"

# Enrollment Status Page
Write-Host "Working on: Enrollment Status Page" -ForegroundColor Green
Get-IntuneConfigurationAssignments -groups $groups -uri "deviceManagement" -type "deviceEnrollmentConfigurations" -uriAssignment "assignments"

# Security Baselines
Write-Host "Working on: Security Baselines" -ForegroundColor Green
Get-IntuneConfigurationAssignments -groups $groups -uri "deviceManagement" -type "intents" -uriAssignment "assignments"

# Change the Properties order to make it look good in Excel for example
$groupsOutput = $groups | Select-Object displayName,id,createdDateTime,configurationPolicies,deviceConfigurations,
    groupPolicyConfigurations,deviceCompliancePolicies,mobileApps,deviceManagementScripts,deviceHealthScripts, 
    windowsAutopilotDeploymentProfiles,deviceEnrollmentConfigurations,intents
    
# Export as CSV (can be imported in Excel)
$groupsOutput | Export-Csv -Path AllIntuneAssignmentsFromGroups.csv 