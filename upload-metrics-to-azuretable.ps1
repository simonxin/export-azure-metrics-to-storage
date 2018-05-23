# Usage sample: get performance metricx from all azure resources under one resource group
# give a valid resource group name
# Usage sample: get performance metricx from all azure resources with a specific resoruce type under one resource group
# give a valid resource group name and resource type name
# Usage sample: get performance metricx from a specific resource
# give a valid resource group name, resource type name and resource name

# parameters:
# -ResourceGroupName: resource group name
# -ResourceType: Resource Type Name
# -ResourceName: Resource Name
# -storageaccountresourcegroup: storage account resource group
# -storageaccount: storage account name
# -tablename: table name in the target storage account

# This Workflow requieres the following powershell modules: AzureRM.Profile, AzureRM.insights, AzureRmStorageTable

# author: SimonXin@Microsoft.com
# verison: 0.1
# time: 2018-5-23

Param
    (
        [Parameter(Mandatory = $true)]
        [String]$ResourceGroupName,

        [Parameter(Mandatory = $false)]
        [String]$ResourceType,

        [Parameter(Mandatory = $false)]
        [String]$Resourcename,

        [Parameter(Mandatory = $true)]
        [String]$storageaccountresourcegroup,

        [Parameter(Mandatory = $true)]
        [String]$storageaccount,

        [Parameter(Mandatory = $true)]
        [String]$tablename

    )

    # define a function to convert hash table from JSON

function ConvertTo-Hashtable {
    [CmdletBinding()]
    [OutputType('hashtable')]
    param (
        [Parameter(ValueFromPipeline)]
        $InputObject
    )

    process {
        ## Return null if the input is null. This can happen when calling the function
        ## recursively and a property is null
        if ($null -eq $InputObject) {
            return $null
        }

        ## Check if the input is an array or collection. If so, we also need to convert
        ## those types into hash tables as well. This function will convert all child
        ## objects into hash tables (if applicable)
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            $collection = @(
                foreach ($object in $InputObject) {
                    ConvertTo-Hashtable -InputObject $object
                }
            )

            ## Return the array but don't enumerate it because the object may be pretty complex
            Write-Output -NoEnumerate $collection
        } elseif ($InputObject -is [psobject]) { ## If the object has properties that need enumeration
            ## Convert it to its own hash table and return it
            $hash = @{}
            foreach ($property in $InputObject.PSObject.Properties) {
                $hash[$property.Name] = ConvertTo-Hashtable -InputObject $property.Value
            }
            $hash
        } else {
            ## If the object isn't an array, collection, or other object, it's already a hash table
            ## So just return it.
            $InputObject
        }
    }
}



    $automationConnectionName = "AzureRunAsConnection"

    $StartTime = [dateTime]::Now.Subtract([TimeSpan]::FromMinutes(60))

    # Get the connection by name (i.e. AzureRunAsConnection)
    $servicePrincipalConnection = Get-AutomationConnection -Name $automationConnectionName

    Write-Output "Logging in to Azure..."

    Add-AzureRmAccount `
        -ServicePrincipal `
        -TenantId $servicePrincipalConnection.TenantId `
        -ApplicationId $servicePrincipalConnection.ApplicationId `
        -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint `
        -EnvironmentName AzureChinaCloud

    # if no resouce name defined, check all resource types

    If (($ResourceGroupname -eq "") -and ($ResourceType -eq "") -and ($Resourcename -eq "")) {
       $MyResources = Get-AzureRmResource -WarningAction silentlyContinue
    } Elseif (($ResourceGroupname -ne "") -and ($ResourceType -eq "") -and ($Resourcename -eq "")) {
       $MyResources = Get-AzureRmResource | where {$_.resourcegroupname -eq $ResourceGroupName }
    } Elseif (($ResourceGroupname -ne "") -and ($ResourceType -ne "") -and ($Resourcename -eq "")) {
       $MyResources = Get-AzureRmResource -ResourceType $ResourceType -ResourceGroupName $ResourceGroupName -WarningAction silentlyContinue
    } Elseif (($ResourceGroupname -ne "") -and ($ResourceType -ne "") -and ($Resourcename -ne "")) {
       $MyResources = Get-AzureRmResource -ResourceType $ResourceType -ResourceGroupName $ResourceGroupName -name $Resourcename -WarningAction silentlyContinue
    }

# This Workflow requieres the following powershell modules: AzureRM.Profile, AzureRM.insights, AzureRmStorageTable
import-module AzureRmStorageTable

# load storage table
$storageAccountName = $storageaccount
$storageAccountGroupName = $storageaccountresourcegroup
$tablename = $tablename

$targetstorage = get-AzureRmStorageAccount -ResourceGroupName $storageAccountGroupName -Name $storageAccountName
$ctx = $targetstorage.Context
$storageTable = Get-AzureStorageTable –Name $tableName –Context $ctx


   foreach ($MyResource in $MyResources ) {
        $MetricsNames = Get-AzureRmMetricDefinition -ResourceId $MyResource.ResourceId -WarningAction silentlyContinue -ErrorAction silentlyContinue
        $table = @()

        foreach($MetricsName in $MetricsNames) {

            $CounterName = $MetricsName.Name.Value
            $CounterNameLocalized = $MetricsName.Name.LocalizedValue
            $CounterUnit = $MetricsName.Unit

            # set the performance metrics into a 5 minutes bin
            $Metric = Get-AzureRmMetric -ResourceId $MyResource.ResourceId -TimeGrain ([TimeSpan]::FromMinutes(5)) -StartTime $StartTime -MetricName $CounterName -WarningAction silentlyContinue
            # Format metrics into a table, we will always choice 1 line

            $MetricObjects = $Metric.Data

            foreach ($MetricObject in $MetricObjects)  {
                $countertimestamp = $MetricObject.Timestamp.ToUniversalTime().ToString("yyyyMMddHHmmss")

           # set the table partition as resourcegroupname plus resourcename plus counter name
           # set the table rowkey as formated time string
                $partitionKey =  $MyResource.ResourceGroupName+$MyResource.Name+"$CounterName"
                $rowKey = $countertimestamp.tostring()

                $sx = @{
                    "MetricName" = $CounterName;
                    "MetricDisplayName" = $CounterNameLocalized;
                    "MetricUnit" = $CounterUnit.tostring();
                    "Total" = $MetricObject.Total;
                    "Count" = $MetricObject.Count;
                    "Average" = $MetricObject.Average;
                    "Maximum" = $MetricObject.Maximum;
                    "Minimum" = $MetricObject.Minimum;
                    "SubscriptionID" = $servicePrincipalConnection.SubscriptionID;
                    "Sampletime" = $MetricObject.Timestamp.ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss");
                    "ResourceGroup" = $MyResource.ResourceGroupName;
                    "ResourceType" = $ResourceType;
                    "ResourceName" = $MyResource.Name
                   }

                $jsontable = ConvertTo-Json -InputObject $sx
                $jsonTable  = $jsonTable.Replace("null", 0)
                $perfobj = $jsontable | ConvertFrom-Json | ConvertTo-HashTable

               #SubscriptionID = $servicePrincipalConnection.SubscriptionID;
               Add-StorageTableRow -table $storageTable -partitionKey $partitionKey -rowKey $rowKey -property $perfobj  -UpdateExisting

            }

        }

    }
