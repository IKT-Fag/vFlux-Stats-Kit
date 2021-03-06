﻿
<#	
    .NOTES
	=========================================================================================================
        Filename:	vFlux-Compute.ps1
        Version:	0.2 
        Created:	12/21/2015
	Updated:	12-December-2016
	Requires:       PowerShell 3.0 or later.
	Requires:       InfluxDB 0.9.4 or later.  The latest 0.10.x is preferred.
        Requires:       Grafana 2.5 or later.  The latest 2.6 is preferred.
	Prior Art:      Based on the get-stat technique often illustrated by Luc Dekens
        Prior Art:      Uses MattHodge's InfluxDB write protocol syntax 
	Author:         Mike Nisk (a.k.a. 'grasshopper')
	Twitter:	@vmkdaily
    =========================================================================================================
    Based on a fork from github.com/Here-Be-Dragons
	=========================================================================================================
	
    .SYNOPSIS
	Gathers VMware vSphere 'Compute' performance stats and writes them to InfluxDB.
        Use this to get CPU, Memory and Network stats for VMs or ESXi hosts.
        Note:  For disk performance metrics, see my vFlux-IOPS script.

    .DESCRIPTION
        This PowerCLI script supports InfluxDB 0.9.4 and later (including the latest 0.10.x).
        The InfluxDB write syntax is based on naf_perfmon_to_influxdb.ps1 by D'Haese Willem,
        which itself is based on MattHodge's Graphite-PowerShell-Functions.
    
    .PARAMETER vCenter
        The name or IP address of the vCenter Server to connect to
    
    .PARAMETER ReportVMs
        Get realtime stats for VMs and write them to InfluxDB
    
    .PARAMETER ReportVMHosts
        Get realtime stats for ESXi hosts and write them to InfluxDB
    
    .PARAMETER ShowStats
        Optionally show some debug info on the writes to InfluxDB

    .EXAMPLE
    	Start-GatherVMWareStats -vcenter <ip> -Credential (Get-Credential) -ReportVMs
    	
    .EXAMPLE
    	Start-GatherVMWareStats -vcenter <ip> -Credential (Get-Credential) -ReportVMHosts

#>

Function Start-GatherVMWareStats
{
[cmdletbinding()]
param (
    [Parameter(Mandatory = $True)]
    [String]$vCenter,

    [Parameter(Mandatory = $False)]
    [switch]$ReportVMs,

    [Parameter(Mandatory = $False)]
    [switch]$ReportVMHosts,

    [Parameter(Mandatory = $False)]
    [switch]$ShowStats,

    [Parameter(Mandatory = $True)]
    $InfluxDbServer,

    [Parameter(Mandatory = $True)]
    $InfluxDbPort = 8086,

    [Parameter(Mandatory = $True)]
    $InfluxDbName,

    [Parameter(Mandatory = $True)]
    $InfluxDbUser,

    [Parameter(Mandatory = $True)]
    $InfluxDbPassword,

    [Parameter(Mandatory = $True)]
    $Credential
)

Begin {

    ## User-Defined Influx Setup
    ## TODO: Credential object for Influx
    $InfluxStruct = New-Object -TypeName PSObject -Property @{
        InfluxDbServer = $InfluxDbServer
        InfluxDbPort = $InfluxDbPort
        InfluxDbName = $InfluxDbName
        InfluxDbUser = $InfluxDbUser
        InfluxDbPassword = $InfluxDbPassword
        MetricsString = '' #emtpy string that we populate later.
    }

    ## User-Defined Preferences
    $Logging = 'off'
    $LogDir = 'C:\bin\logs'
    $LogName = 'vFlux-Compute.log'
    $ReadyMaxAllowed = .20  #acceptable %ready time per vCPU.  Typical max is .10 to .20.
    
    #####################################
    ## No need to edit beyond this point
    #####################################
	
    $authheader = "Basic " + ([Convert]::ToBase64String([System.Text.encoding]::ASCII.GetBytes("$($InfluxStruct.InfluxDbUser):$($InfluxStruct.InfluxDbPassword)")))
    $uri = "http://$($InfluxStruct.InfluxDbServer):$($InfluxStruct.InfluxDbPort)/write?db=$($InfluxStruct.InfluxDbName)"

}

    #####################################
    ## No need to edit beyond this point
    #####################################

Process {

    ## Start Logging
    $dt = Get-Date -Format 'ddMMMyyyy_HHmm'
    If (Test-Path -Path C:\temp) { $TempDir = 'C:\temp' } Else { $TempDir = $Env:TEMP }
    If (!(Test-Path -Path $LogDir)) { $LogDir = $TempDir }
    If ($Logging -eq 'On') { Start-Transcript -Append -Path $LogDir\$LogName }

    ## Load the PowerCLI module if needed
    If ((Get-Module -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue) -eq $null)
    {
        Import-Module VMWare.VimAutomation.Core
    }

    ## Connect to vCenter
    Connect-VIServer $vCenter -Credential $Credential | Out-Null
    
    If (!$Global:DefaultVIServer -or ($Global:DefaultVIServer -and !$Global:DefaultVIServer.IsConnected)) {
        Throw "vCenter Connection Required!"
    }

    Get-Datacenter | Out-Null # clear first slow API access
    Write-Output -InputObject "Connected to $Global:DefaultVIServer"
    Write-Output -InputObject "Beginning stat collection.`n"

    If($ReportVMs) {

        ## Desired vSphere metric counters for virtual machine performance reporting
        $VmStatTypes = 'cpu.usagemhz.average','cpu.usage.average','cpu.ready.summation','mem.usage.average','net.usage.average'
    
        ## Start script execution timer
        $vCenterStartDTM = (Get-Date)

        ## Enumerate VM list
        $VMs = Get-VM | Where-Object {$_.PowerState -eq "PoweredOn"} | Sort-Object -Property Name
        
        ## Iterate through VM list
        foreach ($vm in $VMs) {
    
            ## Gather desired stats
            $stats = Get-Stat -Entity $vm -Stat $VMStatTypes -Realtime -MaxSamples 1
            foreach ($stat in $stats) {
            
                ## Create and populate variables for the purpose of writing to InfluxDB Line Protocol
                $measurement = $stat.MetricId
                $value = $stat.Value
                $name = $vm.Name
                $type = 'VM'
                $numcpu = $vm.ExtensionData.Config.Hardware.NumCPU
                $memorygb = $vm.ExtensionData.Config.Hardware.MemoryMB/1KB
                $interval = $stat.IntervalSecs
                If($stat.MetricID -eq 'cpu.ready.summation') {
                    $ready = [math]::Round($(($stat.Value / ($stat.IntervalSecs * 1000)) * 100), 2)
                    $value = $ready
                    $EffectiveReadyMaxAllowed = $numcpu * $ReadyMaxAllowed
                    $rdyhealth = $numcpu * $ReadyMaxAllowed - $value
                    }
                If($stat.Instance) {$instance = $stat.Instance} Else {$instance -eq $null}
                If($stat.Unit) {$unit = $stat.Unit} Else {$unit -eq $null}
                $vc = ($global:DefaultVIServer).Name
                $cluster = $vm.VMHost.Parent
                [int64]$timestamp = (([datetime]::UtcNow)-(Get-Date -Date "1/1/1970")).TotalMilliseconds * 1000000 #nanoseconds since Unix epoch

                ## Add Metrics to string for this VM iteration
                $InfluxStruct.MetricsString += "$measurement,host=$name,type=$type,vc=$vc,cluster=$cluster,instance=$instance,unit=$Unit,interval=$interval,numcpu=$numcpu,memorygb=$memorygb value=$value $timestamp"
                $InfluxStruct.MetricsString += "`n"
                            
                ## If reporting on %ready, add a derived metric that evaluates the ready health
                If($stat.MetricID -eq 'cpu.ready.summation' -and $rdyhealth) {
                    $measurement = 'cpu.ready.health.derived'
                    $value = $rdyhealth
                    $InfluxStruct.MetricsString += "$measurement,host=$name,type=$type,vc=$vc,cluster=$cluster,instance=$instance,unit=$Unit,interval=$interval,numcpu=$numcpu,memorygb=$memorygb value=$value $timestamp"
                    $InfluxStruct.MetricsString += "`n"
                    }
                            
            ## debug console output
            If($ShowStats){
                Write-Output -InputObject "Measurement: $measurement"
                Write-Output -InputObject "Value: $value"
                Write-Output -InputObject "Name: $Name"
                Write-Output -InputObject "Unix Timestamp: $timestamp`n"
                }
           } #end foreach
     } #end reportvm loop

            ## Runtime Summary
                $vCenterEndDTM = (Get-Date)
                $vmCount = ($VMs | Measure-Object).count
                $ElapsedTotal = ($vCenterEndDTM-$vCenterStartDTM).totalseconds

            If($stats -and $ShowStats){
                Write-Output -InputObject "Runtime Summary:"
                Write-Output -InputObject "Elapsed Processing Time: $($ElapsedTotal) seconds"
	            If($vmCount -gt 1) {
	                $TimePerVM = $ElapsedTotal / $vmCount
	                Write-Output -InputObject "Processing Time Per VM: $TimePerVM seconds"
	                }
               }
    }

    If($ReportVMHosts) {

        ## Desired vSphere metric counters for VMHost performance reporting
        $EsxStatTypes = 'cpu.usagemhz.average','mem.usage.average','cpu.usage.average','cpu.ready.summation','disk.usage.average','net.usage.average','power.power.average'

            ## Iterate through ESXi Host list
            foreach ($vmhost in (Get-VMhost | Where-Object {$_.State -eq "Connected"} | Sort-Object -Property Name)) {
    
                ## Gather desired stats
                $stats = Get-Stat -Entity $vmhost -Stat $EsxStatTypes -Realtime -MaxSamples 1
                    foreach ($stat in $stats) {
            
                        ## Create and populate variables for the purpose of writing to InfluxDB Line Protocol
                        $measurement = $stat.MetricId
                        $value = $stat.Value
                        $name = $vmhost.Name
                        $type = 'VMHost'
                        $interval = $stat.IntervalSecs
                        If($stat.MetricID -eq 'cpu.ready.summation') {$ready = [math]::Round($(($stat.Value / ($stat.IntervalSecs * 1000)) * 100), 2); $value = $ready}
                        If($stat.Instance) {$instance = $stat.Instance} Else {$instance -eq $null}
                        if($stat.Unit) {$unit = $stat.Unit} Else {$unit -eq $null}
                        $vc = ($global:DefaultVIServer).Name
                        $cluster = $vmhost.Parent
                        [int64]$timestamp = (([datetime]::UtcNow)-(Get-Date -Date "1/1/1970")).TotalMilliseconds * 1000000 #nanoseconds since Unix epoch

                        ## Add Metrics to string for this VM iteration
                        $InfluxStruct.MetricsString += "$measurement,host=$name,type=$type,vc=$vc,cluster=$cluster,instance='null',unit=$Unit,interval=$interval value=$value $timestamp"
                        $InfluxStruct.MetricsString += "`n"

                ## debug console output
                If($ShowStats) {
                Write-Output -InputObject "Measurement: $measurement"
                Write-Output -InputObject "Value: $value"
                Write-Output -InputObject "Name: $Name"
                Write-Output -InputObject "Unix Timestamp: $timestamp`n"
                }
            }
        }
    }
    ## Fire contents of $InfluxStruct.MetricsString to InfluxDB
    Invoke-RestMethod -Headers @{Authorization=$authheader} -Uri $uri -Method POST -Body $InfluxStruct.MetricsString
    Disconnect-VIServer '*' -Confirm:$false
    Write-Output -InputObject "Script complete.`n"
    If ($Logging -eq 'On') { Stop-Transcript }
}
}


$cred = Get-Credential

while ($True)
{
    Start-GatherVMWareStats `
        -vCenter "192.168.0.9" `
        -ReportVMHosts `
        -InfluxDbServer "192.168.0.30" `
        -InfluxDbName "Cluster" `
        -InfluxDbPort 8086 `
        -InfluxDbUser "root" `
        -InfluxDbPassword "Passord1" `
        -Credential $cred

    Clear-Host
    Start-Sleep -Seconds 30
}
