##############################################################################################################################
# Name: Citrix XenApp Server Reboot
# Author: Miguel Contreras
# Version: 3.0
# Last Modified By: Miguel Contreras
# Last Modified On: 6/8/2017 (see bottom for change details)
#
# Purpose: This script will reboot the servers in a specified delivery group based on the specified parity.
#
# Parameters: deliveryGroup - Specifies the name of the Delivery Group the target machines are members of.
#             parity - Specifies the parity of the machine names to be rebooted.
#             drainTimer - Amount of minutes to allow sessions to drain before sending reboot alerts to users.
#             cloud - OPTIONAL. Defines whether it is necessary to log in to Citrix Cloud. If using Citrix Cloud, please make
#                     sure to update the customer ID, Secure Client ID, and Secure Client Key below.
#
# To run the script:
# 1) Open Powershell prompt
# 2) Run the following command:
#    powershell.exe -ExecutionPolicy Bypass -File "Path to script" -deliveryGroup "Name of Delivery Group" -parity "Even/Odd" -drainTimer <Number of minutes> [-cloud]
#    
#    On-premises XenApp example:   
#    powershell.exe -ExecutionPolicy Bypass -File "\\share\scripts\reboot.ps1" -deliveryGroup "XenApp 2012R2" -parity "even" -drainTimer 240
#
#	 Citrix Cloud example:   
#    powershell.exe -ExecutionPolicy Bypass -File "\\share\scripts\reboot.ps1" -deliveryGroup "XenApp 2012R2" -parity "even" -drainTimer 240 -cloud
#
##############################################################################################################################

# Read the parameters passed from command line
Param([string]$deliveryGroup, [string]$parity, [Int32]$drainTimer, [switch]$cloud)	


# Check for administrator rights
if ( -NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator") ) {
    Write-Host "You must run this script as an administrator."ù -BackgroundColor Black -ForegroundColor Red
    Exit
}


# Initialize Event Log source
$logSource = "Citrix XenApp Reboot Script"
try{
    $check = ([System.Diagnostics.EventLog]::SourceExists($logSource))
    if (!$check){
        New-EventLog -LogName Application -Source $logSource
    }
    $msg = "Citrix XenApp Reboot Script Initialized."
    Write-EventLog -LogName Application -Source $logSource -EventId 1 -EntryType Information -Message $msg -Category 0
}
catch{
    Write-Host $_.Exception.GetType().FullName -BackgroundColor Black -ForegroundColor Red
}


# General Trap for unhandled errors
trap {
    Write-Host "GENERAL ERROR, SEE EVENT LOG"ù -BackgroundColor Black -ForegroundColor Red
    $msg = "GENERAL ERROR: " + $_.Exception
    Write-EventLog -LogName Application -Source $logSource -EventId 0 -EntryType Error -Message $msg -Category 0
}


# Load the Citrix PowerShell snap-ins
try {
    Asnp Citrix*
}
catch {
    $msg = "Failed to load Citrix snap-ins.`n" + $_.Exception
    Write-EventLog -LogName Application -Source $logSource -EventId 13 -EntryType Error -Message $msg -Category 0
}


###########################################################################################################
############################################ Citrix Cloud Login ###########################################
###########################################################################################################

if ($cloud) {
    Set-XDCredentials -ProfileType CloudApi -CustomerId "customer id" -APIKey Secure Client ID -SecretKey Secure Client Key

    try {
        Get-XDAuthentication
    }
    catch {
        $msg = "Failed to authenticate with Citrix Cloud.`n" + $_.Exception
        Write-EventLog -LogName Application -Source $logSource -EventId 2 -EntryType Error -Message $msg -Category 0
    }
}

###########################################################################################################
###########################################################################################################
###########################################################################################################    


# Function to retrieve machines to be rebooted
function Retrieve-Machines($deliveryGroup, $parity, $logSource, $targetServers) {
    $retrieveMsg = ""

    $msg = "Starting machine retrieval."
    Write-EventLog -LogName Application -Source $logSource -EventId 3 -EntryType Information -Message $msg -Category 0

    try {
        $serverArray = Get-BrokerMachine -DesktopGroupName $deliveryGroup -InMaintenanceMode $False -PowerState On -MaxRecordCount 5000

        $parity = $parity.ToUpper()

        foreach($vm in $serverArray)
        {
	        $vmName = $vm.HostedMachineName
	        # Get last digit of the name to determine parity
	        $vmNumber = $vmName.substring(($vmName.length - 1), 1) -as [int]

	        if ((($vmNumber%2) -eq 0) -and ($parity -eq "EVEN"))
	        {
		        $targetServers.Add($vm)
	        }
	        elseif ((($vmNumber%2) -ne 0) -and ($parity -eq "ODD"))
	        {
		        $targetServers.Add($vm)
	        }
        }

        $retrieveMsg = "Machine retrieval successful."
        Write-EventLog -LogName Application -Source $logSource -EventId 4 -EntryType Information -Message $retrieveMsg -Category 0
    }
    catch {
        $retrieveMsg = "Machine retrieval failed."
        Write-EventLog -LogName Application -Source $logSource -EventId 5 -EntryType Error -Message $retrieveMsg -Category 0
    }
}


# Function to enable maintenance mode on machines to be rebooted
function Enable-MaintenanceMode($targetServers, $logSource) {
    $maintMsg = ""

    $msg = "Starting to enable maintenance mode."
    Write-EventLog -LogName Application -Source $logSource -EventId 6 -EntryType Information -Message $msg -Category 0

    try {
        foreach($vm in $targetServers)
        {
	        Get-BrokerMachine -HostedMachineName $vm.HostedMachineName | Set-BrokerMachine -InMaintenanceMode 1
        }

        $maintMsg = "Machines set to maintenance mode successfully."
        Write-EventLog -LogName Application -Source $logSource -EventId 7 -EntryType Information -Message $maintMsg -Category 0
    }
    catch {
        $maintMsg = "Failed to enable maintenance mode."
        Write-EventLog -LogName Application -Source $logSource -EventId 8 -EntryType Error -Message $maintMsg -Category 0
    }
}


# Function to reboot the machines
function Reboot-Machines($targetServers, $logSource) {
    $rebootMsg = ""
    $timer = 1800    # Maximum time in minutes before all target machines are rebooted once reboots start
    $tempArray = New-Object System.Collections.ArrayList
    
    $msg = "Starting server reboot."
    Write-EventLog -LogName Application -Source $logSource -EventId 9 -EntryType Information -Message $msg -Category 0

    try {
        # Loop through all machines to be rebooted, check whether there are sessions on them, and reboot those without sessions
        # Users are alerted of the reboot every 5 minutes
        # After the timer specified above has elapsed, all pending servers are rebooted

        while($True) {
	        if($targetServers.count -ne 0) {
		        foreach($target in $targetServers) {
			        # Retrieve the machine to obtain current properties and not the ones stored initially
			        $vm = Get-BrokerMachine -HostedMachineName $target.HostedMachineName
			
			        if($timer -gt 0) {	
				        if ($vm.SessionCount -eq 0) {
					        Get-BrokerMachine -HostedMachineName $vm.HostedMachineName | New-BrokerHostingPowerAction -Action 'Restart'
					        Get-BrokerMachine -HostedMachineName $vm.HostedMachineName | Set-BrokerMachine -InMaintenanceMode 0
					        $tempArray.Add($target)
				        }
				        else {
					        $counter = $timer/60
					        $msg = "Server will be rebooted in " + $counter.ToString() + " minutes. Please save your work, log off, and launch a new session."
					        $sessions = Get-BrokerSession -DNSName $vm.DNSName
					
					        Send-BrokerSessionMessage $sessions -MessageStyle Information -Title "Reboot Warning" -Text $msg				
				        }
			        }
			        else {
				        Get-BrokerMachine -HostedMachineName $vm.HostedMachineName | New-BrokerHostingPowerAction -Action 'Restart'
				        Get-BrokerMachine -HostedMachineName $vm.HostedMachineName | Set-BrokerMachine -InMaintenanceMode 0
			        }
		        }
		
		        if($timer -gt 0) {
			        foreach($vm in $tempArray) {
				        $targetServers.RemoveAt($targetServers.IndexOf($vm))
			        }
			
			        $tempArray.Clear()	
			
			        if($targetServers.count -ne 0) {
				        $timer -= 300
				        Start-Sleep 300
			        }
		        }
		        else {	
			        Break
		        }
	        }
	        else {
		        Break
	        }
        }

        $rebootMsg = "Machine reboot finished."
        Write-EventLog -LogName Application -Source $logSource -EventId 10 -EntryType Information -Message $rebootMsg -Category 0
    }
    catch {
        $rebootMsg = "Machine reboot failed."
        Write-EventLog -LogName Application -Source $logSource -EventId 11 -EntryType Error -Message $rebootMsg -Category 0
    }

    return $rebootMsg
}


###########################################################################################################
############################################# Begin Execution #############################################
###########################################################################################################


$targetServers = New-Object System.Collections.ArrayList
Retrieve-Machines -deliveryGroup $deliveryGroup -parity $parity -logSource $logSource -targetServers $targetServers

if ($targetServers -like "") {
    $finalMsg = "Unknown error."
	Write-EventLog -LogName Application -Source $logSource -EventId 14 -EntryType Error -Message $finalMsg -Category 0
}
else {
    Enable-MaintenanceMode -targetServers $targetServers -logSource $logSource
    
    # Allow draining sessions for specified time.  Users will not receive reboot alerts until timer is up.
    $drainTimer = $drainTimer * 60
    Start-Sleep $drainTimer

    Reboot-Machines -targetServers $targetServers -logSource $logSource

    $finalMsg = "Citrix XenApp Reboot Script Completed."
	Write-EventLog -LogName Application -Source $logSource -EventId 12 -EntryType Information -Message $finalMsg -Category 0
}


###########################################################################################################
############################################## End Execution ##############################################
###########################################################################################################


###########################################################################################################
# 05/02/14: Version 1.0
# 05/03/17: Version 2.0
#           Created functions and added error handling
# 06/08/17: Version 3.0
#           Changed drain timer to variable
#           Added Citrix Cloud option
#
###########################################################################################################
###########################################################################################################
# 
# *****************************************   LEGAL DISCLAIMER   *****************************************
#
# This software / sample code is provided to you "AS IS"ù with no representations, warranties or conditions 
# of any kind. You may use, modify and distribute it at your own risk. CITRIX DISCLAIMS ALL WARRANTIES 
# WHATSOEVER, EXPRESS, IMPLIED, WRITTEN, ORAL OR STATUTORY, INCLUDING WITHOUT LIMITATION WARRANTIES OF 
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NONINFRINGEMENT. Without limiting the 
# generality of the foregoing, you acknowledge and agree that (a) the software / sample code may exhibit 
# errors, design flaws or other problems, possibly resulting in loss of data or damage to property; 
# (b) it may not be possible to make the software / sample code fully functional; and (c) Citrix may, 
# without notice or liability to you, cease to make available the current version and/or any future 
# versions of the software / sample code. In no event should the software / code be used to support of 
# ultra-hazardous activities, including but not limited to life support or blasting activities. 
# NEITHER CITRIX NOR ITS AFFILIATES OR AGENTS WILL BE LIABLE, UNDER BREACH OF CONTRACT OR ANY OTHER THEORY 
# OF LIABILITY, FOR ANY DAMAGES WHATSOEVER ARISING FROM USE OF THE SOFTWARE / SAMPLE CODE, INCLUDING 
# WITHOUT LIMITATION DIRECT, SPECIAL, INCIDENTAL, PUNITIVE, CONSEQUENTIAL OR OTHER DAMAGES, EVEN IF ADVISED 
# OF THE POSSIBILITY OF SUCH DAMAGES. Although the copyright in the software / code belongs to Citrix, any 
# distribution of the code should include only your own standard copyright attribution, and not that of 
# Citrix. You agree to indemnify and defend Citrix against any and all claims arising from your use, 
# modification or distribution of the code.
###########################################################################################################