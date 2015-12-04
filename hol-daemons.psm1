# Version 1.6.0 - 4 December 2015

$holSettingsFile = 'E:\scripts\hol_cmdlets_settings.xml'

if( Test-Path $holSettingsFile ) {
	[xml]$SettingsFile = Get-Content $holSettingsFile
	#No need to validate that the proper locations exist.. return ''
	$DEFAULT_CATALOGHOST = $SettingsFile.Settings.Defaults.CatalogHost
	$DEFAULT_REMOTELIB = $SettingsFile.Settings.Defaults.RemoteLib
	$DEFAULT_LOCALSEED = $SettingsFile.Settings.Defaults.LocalSeed
	$DEFAULT_LOCALLIB = $SettingsFile.Settings.Defaults.LocalLib
	$DEFAULT_SSHUSER = $SettingsFile.Settings.Defaults.SSHuser
	$DEFAULT_MAPOUTPUTPATH = $SettingsFile.Settings.Defaults.MapOutputPath
	$DEFAULT_WORKINGDIR = $SettingsFile.Settings.Defaults.MailboxPath
	$DEFAULT_SOURCECLOUDKEY = $SettingsFile.Settings.Defaults.SourceCloudKey
	$DEFAULT_SOURCECLOUDCATALOG = $SettingsFile.Settings.Defaults.SourceCloudCatalog
	$DEFAULT_TARGETCLOUDCATALOG = $SettingsFile.Settings.Defaults.TargetCloudCatalog
	$DEFAULT_REMOTEMAILBOXPATH = $SettingsFile.Settings.Defaults.RemoteMailboxPath
	$DEFAULT_SMTPSERVER = $SettingsFile.Settings.Defaults.SmtpServer
	$DEFAULT_EMAILSENDER = $SettingsFile.Settings.Defaults.EmailSender
	$DEFAULT_SLEEPSECONDS = $SettingsFile.Settings.Defaults.SleepSeconds
	$DEFAULT_CATALOGFREESPACE = $SettingsFile.Settings.Defaults.MinCatalogSpaceGb
	$DEFAULT_OVFTOOLPATH = $SettingsFile.Settings.Defaults.OvfToolPath
	$DEFAULT_HOLCMDLETSPATH = $SettingsFile.Settings.Defaults.HolCmdletsPath
	
	#Credential Management
	$DEFAULT_CLOUDUSER = $SettingsFile.Settings.Defaults.CloudUser
	$DEFAULT_CLOUDPASSWORD = $SettingsFile.Settings.Defaults.CloudPassword
	$DEFAULT_CLOUDCREDENTIAL = $SettingsFile.Settings.Defaults.CloudCredential
	if( ($DEFAULT_CLOUDPASSWORD -eq '') -and (Test-Path $DEFAULT_CLOUDCREDENTIAL) ) {
		$cred = New-Object System.Management.Automation.PsCredential $DEFAULT_CLOUDUSER , $(Get-Content $DEFAULT_CLOUDCREDENTIAL | ConvertTo-SecureString)
		$DEFAULT_CLOUDPASSWORD = ($cred.GetNetworkCredential()).Password
	}
} else {
	Write-Host "Unable to find $holSettingsFile - no default values configured"
}

<#
	Send a notification Email from an HOL Daemon
	Basically, an email with some standardized subject and body text to facilitate filtering
#>
Function Send-HolDaemonEmail {

	PARAM(
		$To = $(throw "need -To address"),
		$Site = "UNKNOWN",
		$Subject = "",
		$Body = ""
	)

	PROCESS {
		$emailSubject = "HOL vPod Daemon: $Subject"
		$emailBody = "vPod processing by an HOL Daemon at $Site :`r`n $Body"

		#Send-Email -SmtpServer $DEFAULT_SMTPSERVER -From $DEFAULT_EMAILSENDER -To $To -Subject $emailSubject -Body $emailBody
		Write-Host -ForegroundColor Yellow "NOTE: Email currently disabled until workaround is implemented."
	}
} #Send-HolDaemonEmail


Function Rename-HolWorkingFile {
<#
	Simple function to rename the 'working file' -- a rudimentary semaphore and message passing system
#>
	PARAM ($podName, $currentFile, $status)
	PROCESS {
		$newName = ($podName + '_' + $status)
		Rename-Item -Path $currentFile.FullName -NewName $newName
		Return Get-Item $(($currentFile.FullName).Replace($currentFile.Name,$newName))
	}
} #Rename-HolWorkingFile


Function Start-HolVpodExportDaemon {
<#
	Watch the specified working directory (Mailbox) for work to be done
	Look for files named with the vPOD name + '_READY' and begins processing
	Sends emails with status updates (Start/Finish Export, Begin/End Import, Begin/End Shadow)
#>
	PARAM(
		$WorkingDir = $(throw "need -WorkingDir to watch"),
		$Site = 'MASTER',
		$SourceCloudKey = $DEFAULT_SOURCECLOUDKEY,
		$SourceCloudCatalog = $DEFAULT_SOURCECLOUDCATALOG,
		$TargetCloudKeys = $(),
		$TargetCloudCatalog = $DEFAULT_TARGETCLOUDCATALOG,
		$RemoteCatalogs = $(),
		$CloudUser = $DEFAULT_CLOUDUSER,
		$CloudPassword = $DEFAULT_CLOUDPASSWORD,
		$LibPath = $DEFAULT_LOCALLIB,
		$OvdcFilter = '*',
		$SshUser = $DEFAULT_SSHUSER,
		$RemoteMailboxPath = $DEFAULT_REMOTEMAILBOXPATH,
		$Filter = '*',
		$Email = $DEFAULT_EMAILSENDER,
		[Switch]$SeedOnly,
		[Switch]$ShadowCodeWorks
	)
	
	PROCESS {
		#Set Global Defaults
		$SleepSeconds = $DEFAULT_SLEEPSECONDS
		$minCatalogSpaceGb = $DEFAULT_CATALOGFREESPACE
		$maxImportJobs = 2
		$importJobs = @()
		$ovfToolPath = $DEFAULT_OVFTOOLPATH
		
		# Load Required Modules
		# need hol-cmdlets
		$holCmdletsPath = $DEFAULT_HOLCMDLETSPATH
		if ( !(Get-Module -Name hol-cmdlets -ErrorAction SilentlyContinue) ) {
			if( Test-Path $holCmdletsPath ) { Import-Module $holCmdletsPath }
			else { 
				Write-Host -ForegroundColor Red "FAIL: $holCmdletsPath not found." 
				Return
			}
		}
		# need PowerCLI for shadowing -- only in the spawned sessions
<#
		if ( !(Get-Module -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue) ) {
			try {
				. 'C:\Program Files (x86)\VMware\Infrastructure\vSphere PowerCLI\Scripts\Initialize-PowerCLIEnvironment.ps1'
			}
			catch {
				$NoPowerCLI = $true
			}
		}
#>
		# Ensure parameter sanity
		try { 
			Get-Item $WorkingDir -ErrorAction "Stop" | out-Null
		}
		catch {
			Write-Host -Fore Red "FAIL: $WorkingDir does not exist."
			Return $false
		}
		
		try { 
			$Lib = Get-Item $LibPath -ErrorAction "Stop"
		}
		catch {
			Write-Host -ForegroundColor Red "FAIL: $LibPath does not exist."
			Return
		}
		

		#preserve the current window title and set a new one
		$oldWindowTitle = $host.ui.RawUI.WindowTitle
		$host.ui.RawUI.WindowTitle = "Exporting $SourceCloudCatalog in $SourceCloudKey to $LibPath"

		# Start the main loop
		while ($true) {

			# Read contents of $WorkingDir, get names of pods to process 
			#  "jobs" are specified by files ending with '_READY' and beginning with $Filter
			$contents = Get-ChildItem -Path $WorkingDir -Filter ($Filter + '_READY') -File

			#If there is work do to, do it
			$currentFile = $contents | Select-Object -First 1
			if( $currentFile ) {
				$podName = ( $currentFile.Name -Split '_READY' )[0]
				Write-Host "$(Get-Date) VpodExportDaemon - Found pod to process: $podName"

				### Check LibPath for adequate free space ###
				$libRoot = $Lib.Root
				$libDrive = ($libroot.name).Substring(0,2)
				#$space = gwmi win32_volume -Filter 'drivetype = 3' | where { $_.driveletter -like $libDrive } | select driveletter, label, @{LABEL='GBfreespace';EXPRESSION={ ($_.freespace/1GB)} }
				$space = gwmi win32_logicaldisk | where { $_.DeviceID -like $libDrive } | select DeviceID, @{LABEL='GBfreespace';EXPRESSION={ ($_.freespace/1GB)} }
				
				if( $space.GBfreespace -lt $minCatalogSpaceGb ) { 
					Write-Host -Fore Red "$(Get-Date) Suspending exports: < $minCatalogSpaceGb GB free space remaining in library"
					#future option: find current/old version of pod, remove it prior to exporting
					#for now, just fail and return
					Return
				}
				
				### Free Space check passed ###

				$currentFile = Rename-HolWorkingFile $podName $currentFile 'WORKING'

				# Send 'Request Received' email
				Write-Host -Fore Green "$(Get-Date) $podName - request received"
				Send-HolDaemonEmail -To $Email -Site $Site -Subject $podName -Body "Received request to process $podName from $SourceCloudKey"

				# Begin processing. Don't try to process a pod twice
				try {
					$ExportExists = Get-Item $(Join-Path $LibPath $podName) -ErrorAction "Stop"
					$msg = "$(Get-Date) Found export on disk for $podName"
					Write-Host $msg
					Out-File -FilePath $currentFile.FullName -InputObject $msg -Append
				}
				catch {
					# Export does not currently exist on disk, begin Export from source cloud
					If( -not $ExportExists ) {
						Export-VPod -k $SourceCloudKey -User $CloudUser -Password $CloudPassword -LibPath $LibPath -Catalog $SourceCloudCatalog -VPodName $podName
						# Send 'Export Finished' email [NOTE: ovftool reports 'all good' even when it fails]
						$msg = "$(Get-Date) $podName - export finished"
						Write-Host -Fore Green $msg
						Out-File -FilePath $currentFile.FullName -InputObject $msg -Append
						Send-HolDaemonEmail -To $Email -Site $Site -Subject $podName -Body "Export of $podName from $SourceCloudKey has completed"
					}
				}

				#Validate the OVF exists and is complete
				$vPodPath = Join-Path $LibPath $podName
				Write-Host -Fore Yellow "$(Get-Date) $podName - testing OVF completeness"
				$ovfPath = (Join-Path $vPodPath $podName) + '.ovf'
				if( -not (Test-Path $ovfPath) ) {
					# fail and report
					$msg = "$(Get-Date) $podName - $ovfPath not found"
					Write-Host -Fore Red $msg
					Out-File -FilePath $currentFile.FullName -InputObject $msg -Append
					$currentFile = Rename-HolWorkingFile $podName $currentFile 'FAILED'
					Return
				}
				
				if( -not (Test-OVF -OVF $ovfPath) ) {
					# fail and report
					$msg = "$(Get-Date) $podName - $ovfPath incomplete"
					Write-Host -Fore Red $msg
					Out-File -FilePath $currentFile.FullName -InputObject $msg -Append
					$currentFile = Rename-HolWorkingFile $podName $currentFile 'FAILED'
					Return
				}

				#Send notification to remote catalog host(s) that OVF is ready
				#ssh to remote catalog and touch "vPodName_READY" in $RemoteMailboxPath
				#script running there will pick it up and handle appropriately
				foreach( $sshComputer in $RemoteCatalogs ) {
					$touchFile = $RemoteMailboxPath + $podName + '_READY'
					$syncCmd = 'ssh ' + $SshUser + '@' + $sshComputer + " touch $touchFile "
					$command = "C:\cygwin64\bin\bash.exe --login -c " + "'" + $syncCmd + "'"
					Write-Host "REPLICATE to $sshComputer : " $command
					Invoke-Expression -command $command
				}


				if( $SeedOnly -ne $True ) {

					# Begin Import(s) -- spawn one new Job for each import
					# No throttle today. Typically only 1-3 'local' clouds. It has handled 8 w/o issue.
					#
					# Handles (allowExtraConfig) for special cases like 1628
					# Postprocessing for metadata (1657/8) is not currently implemented
					#
					foreach( $cloudKey in $TargetCloudKeys ) {
						$msg = "$(Get-Date) $podName - Import to $cloudKey starting..."
						Out-File -FilePath $currentFile.FullName -InputObject $msg -Append
						$mycmd = "Write-Host $msg ; Import-VPod -k $cloudKey -user $CloudUser -password $CloudPassword -VPodName $podName -LibPath $LibPath -Options '--skipManifestCheck --allowExtraConfig' -Catalog $TargetCloudCatalog"
#						$importJobs += Start-Job -Name "$cloudKey $podName IMP" -ScriptBlock { param($mycmd) Invoke-Expression -Command $mycmd } -ArgumentList $mycmd -InitializationScript { New-Alias -Name ovftool -Value 'C:\Program Files\VMware\vmware ovf tool\ovftool.exe' ; Import-Module 'E:\Scripts\hol-cmdlets.psd1' } 
						$importJobs += Start-Job -Name "$cloudKey $podName IMP" -ScriptBlock { param($mycmd) Invoke-Expression -Command $mycmd } -ArgumentList $mycmd -InitializationScript { Import-Module 'E:\Scripts\hol-cmdlets.psd1' } 
	
						Write-Host "Spawning job for $podName into import queue" -ForegroundColor Magenta
						$runningImportJobs = @( $importJobs | ? { ($_.Name -like '*IMP') -and ($_.State -eq 'Running') } )
					}

					# Watch Import jobs here - output is mostly junk, but could be useful
					# They have been known to go infinite sometimes if vCD disconnects.
	
					while( $runningImportJobs.Count -gt 0 ) {
						# check on jobs, write output for monitoring
						foreach( $Job in ($runningImportJobs | where { $_.HasMoreData }) ) {
							Write-Host "BEGIN - $($Job.Name)" -ForegroundColor Black -BackgroundColor Yellow 
							Receive-Job $Job
							Write-Host "END - $($Job.Name)" -ForegroundColor Black -BackgroundColor Yellow 
						}
						
						#wait for finished jobs then go look for more output
						$finishedJobs = Wait-Job -Job $runningImportJobs -Any -Timeout $SleepSeconds
				
						foreach( $finishedJob in $finishedJobs ) {
							# Wait for a finished job to be REALLY finished and remove the Job
							$jobName = $finishedJob.Name
							Write-Host "BEGIN - $jobName" -ForegroundColor Black -BackgroundColor Yellow 
							Receive-Job -Job $finishedJob -Wait
							Write-Host "END - $jobName" -ForegroundColor Black -BackgroundColor Yellow 
							if( $finishedJob.State -ne 'Completed' ) {
								Write-Host "Problem with $jobName - $($finishedJob.State)" -ForegroundColor Red
							} else {
								Write-Host "Dequeueing $jobName - $($finishedJob.State)" -ForegroundColor Magenta
								Remove-Job -Job $finishedJob
							}
						}
						$runningImportJobs = @($importJobs | ? {$_.State -eq 'Running'})
					}
	
					# Send 'Import Successful' email (actually "upload successful")
					$msg = "$(Get-Date) $podName - import successful"
					Write-Host -Fore Green $msg
					Out-File -FilePath $currentFile.FullName -InputObject $msg -Append
					Send-HolDaemonEmail -To $Email -Site $Site -Subject $podName -Body "Local import of $podName has finished."
	
	##################### PARDON OUR DUST #####################
	# Future development: look at decoupling import from shadowing
	# Shadow Waiter can look at mailbox for work: "VPODNAME_IMPORTED" filenames
	# curently, this code may have some issues with PowerCLI v6.0+
	
					# Once imports begin, "shadow waiter" can be kicked off
					$msg = "$(Get-Date) $podName - shadows would be created here"
					Write-Host -Fore Yellow $msg
					Out-File -FilePath $currentFile.FullName -InputObject $msg -Append
					#Spawn jobs with Add-CIVappShadowsWait for each $TargetCloudKeys
					if( $ShadowCodeWorks ) {
						foreach( $cloudKey in $TargetCloudKeys ) {
							($cloudHost, $cloudOrg) = Get-CloudInfoFromKey -Key $cloudKey
							if( $cloudHost -ne '' ) {
								$msg = "$(Get-Date) $podName - Shadowing in $cloudKey"
								Out-File -FilePath $currentFile.FullName -InputObject $msg -Append
								$mycmd = '
		Connect-CiServer -Server ' + $cloudHost + ' -Org ' + $cloudOrg + ' -User ' + $cloudUser + ' -Password ' + $cloudPassword + '
		Try { $orgVdcs = Get-OrgVdc ' + $OvdcFilter + ' } 
		Catch { Write-Host "No matching OrgVdc" ; Return }
		If($orgVdcs) { 
			Try { 
				$vPod = Get-civappTemplate -Catalog ' + $TargetCloudCatalog + ' -Name ' + $podName + '
				Add-CiVappShadowsWait -o $orgVdcs -v $vPod
			} Catch { Write-Host "No matching vPod" ; Return }
		}
		Disconnect-CiServer * -Confirm:$false'
	#For PowerCLI <6.0
	#							Start-Job -Name "Shadow $podName in $cloudKey" -ScriptBlock { param($mycmd) Invoke-Expression -Command $mycmd } -ArgumentList $mycmd -InitializationScript { Import-Module VMware.VimAutomation.Cloud ; Import-Module E:\Scripts\hol-cmdlets.psm1 } 
	# For PowerCLI 6.0+
								Start-Job -Name "Shadow $podName in $cloudKey" -ScriptBlock { param($mycmd) Invoke-Expression -Command $mycmd } -ArgumentList $mycmd -InitializationScript { Import-Module VMware.VimAutomation.Cloud ; Import-Module E:\Scripts\hol-cmdlets.psm1 } 
							} else {
								Write-Host -Fore Red "ERROR: invalid CloudKey specified: $cloudKey"
							}
						} 
					}
				} 
				# Mark finished and send Email
				$currentFile = Rename-HolWorkingFile $podName $currentFile 'FINISHED'
				# Send the "all clear" email for local work
				Send-HolDaemonEmail -To $Email -Site $Site -Subject $podName -Body "Completed local processing of $podName."
				
			} else {
				#No work to do... go to sleep
				if( $SeedOnly -eq $True ) { $SeedOnlyMsg = "(SEEDING ONLY)" }
				Write-Host "$(Get-Date) No work to do, sleeping $SleepSeconds seconds. $SeedOnlyMsg"
				Start-Sleep -Sec $SleepSeconds
			}
		}
	}
} #Start-HolVpodExportDaemon


Function Start-HolVpodImportDaemon {
<#
	Watch the specified working directory (Mailbox) for work to be done
	Look for files named with the vPOD name and begins processing
	Sends emails with status updates (Start/Finish Replication, Begin/End Import, Begin/End Shadow)
	
	Runs on the child catalog hosts to pull from parent
	
#>
	PARAM(
		$WorkingDir = $(throw "need -WorkingDir to watch"),
		$Site = 'UNKNOWN',
		$SourceCatalogHost = $DEFAULT_CATALOGHOST,
		$TargetCloudKeys = $(),
		$TargetCloudCatalog = $DEFAULT_TARGETCLOUDCATALOG,
		$CloudUser = $DEFAULT_CLOUDUSER,
		$CloudPassword = $DEFAULT_CLOUDPASSWORD,
		$OvdcFilter = '*',
		$SshUser = $DEFAULT_SSHUSER,
		$LibPath = $DEFAULT_LOCALLIB,
		$SeedPath = $DEFAULT_LOCALSEED,
		$RemoteMailboxPath = $DEFAULT_REMOTEMAILBOXPATH,
		$VpodFilter = '*',
		$Email = $DEFAULT_EMAILSENDER,
		[Switch]$SeedOnly,
		[Switch]$ShadowCodeWorks
	)
	PROCESS {
		#need ovftool for importing
		$ovfToolPath = $DEFAULT_OVFTOOLPATH
		
		# Load Required Modules
		# need hol-cmdlets
		$holCmdletsPath = $DEFAULT_HOLCMDLETSPATH
		if ( !(Get-Module -Name hol-cmdlets -ErrorAction SilentlyContinue) ) {
			if( Test-Path $holCmdletsPath ) { Import-Module $holCmdletsPath }
			else { 
				Write-Host -ForegroundColor Red "FAIL: $holCmdletsPath not found." 
				Return
			}
		}
		
		# Ensure parameter sanity
		Try { 
			Get-Item $WorkingDir -ErrorAction "Stop" | out-Null
		}
		Catch {
			Write-Host -Fore Red "FAIL: $WorkingDir does not exist."
			Return $false
		}
		
		Try { 
			$Lib = Get-Item $LibPath -ErrorAction "Stop"
		}
		Catch {
			Write-Host -Fore Red "FAIL: $LibPath does not exist."
			Return
		}
		
		#Sleep between loops
		$SleepSeconds = $DEFAULT_SLEEPSECONDS

		#preserve the current window title and set a new one
		$oldWindowTitle = $host.ui.RawUI.WindowTitle
		$host.ui.RawUI.WindowTitle = "Importing from $LibPath to $TargetCloudCatalog"

		# Start the main loop
		While ($true) {
			
			# Read contents of $WorkingDir, get names of pods to process 
			#  "jobs" specified by files ending with _READY and beginning with $Filter
			$contents = Get-ChildItem -Path $WorkingDir -Filter ($VpodFilter + '_READY') -File

			#If there is work do to, do it
			$currentFile = $contents | Select-Object -First 1
			If ( $currentFile ) {
				$podName = ( $currentFile.Name -Split '_READY' )[0]
				Write-Host "$(Get-Date) VpodImportDaemon - Found pod to process: $podName"

				### Check LibPath for adequate free space ###
				$minCatalogSpaceGb = $DEFAULT_CATALOGFREESPACE
				$libRoot = $Lib.Root
				$libDrive = ($libroot.name).Substring(0,2)
				#$space = gwmi win32_volume -Filter 'drivetype = 3' | where { $_.driveletter -like $libDrive } | select driveletter, label, @{LABEL='GBfreespace';EXPRESSION={ ($_.freespace/1GB)} }
				$space = gwmi win32_logicaldisk | where { $_.DeviceID -like $libDrive } | select DeviceID, @{LABEL='GBfreespace';EXPRESSION={ ($_.freespace/1GB)} }
				
				If( $space.GBfreespace -lt $minCatalogSpaceGb ) { 
					Write-Host -Fore Red "$(Get-Date) Suspending replication: < $minCatalogSpaceGb GB free space remaining in library"
					Return
				}
				### Free Space check passed ###

				$currentFile = Rename-HolWorkingFile $podName $currentFile 'WORKING'

				# Send 'Request Received' email
				Write-Host -Fore Green "$(Get-Date) $podName - request received"
				Send-HolDaemonEmail -To $Email -Site $Site -Subject $podName -Body "Received request to process $podName from $SourceCatalogHost"

				# Begin processing
				Try {
					$ExportExists = Get-Item $(Join-Path $LibPath $podName) -ErrorAction "Stop"
					$msg = "$(Get-Date) Found export on disk for $podName"
					Write-Host $msg
					Out-File -FilePath $currentFile.FullName -InputObject $msg -Append
				}
				Catch {
					# Export does not currently exist, begin replication from source catalog
					If( -not $ExportExists ) {
						#locate the current version of the pod in $LibPath
						# Eventually, might need a better way to match
						$podRoot = $podName.Substring(0,12)
						Try {
							$oldPod = Get-Item $((Join-Path $LibPath $podRoot) + '*') -ErrorAction "Stop"
							$oldPodName = $oldPod.Name #Assumes only one pod in Libary with this root
							Write-Host "$(Get-Date) Found old pod on disk: $oldPodName"
							#Move old pod to Seeds
							Move-Item $oldPod.FullName -Destination $SeedPath
						}
						Catch {
							$oldPodName = 'NONE'
							Write-Host -fore Yellow "$(Get-Date) old pod not found on disk, using 'NONE'"
						}
						Write-Host "Pulling new version:" $command
						Start-OvfTemplatePull -oldName $oldPodName -newName $podName -LocalLib $LibPath -LocalSeed $SeedPath -CatalogHost $SourceCatalogHost

						# Send 'Replication Complete' email
						$msg = "$(Get-Date) $podName - replication successful"
						Write-Host -Fore Green $msg
						Out-File -FilePath $currentFile.FullName -InputObject $msg -Append
						Send-HolDaemonEmail -To $Email -Site $Site -Subject $podName -Body "Replication of $podName to $Site has completed"
					}
				}

				### Here, we should have a valid pod on disk
				$vPodPath = Join-Path $LibPath $podName

				#Validate the OVF is complete
				Write-Host -Fore Yellow "$(Get-Date) $podName - testing OVF completeness"
				$ovfPath = (Join-Path $vPodPath $podName) + '.ovf'
				If( -not (Test-Path $ovfPath) ) {
					# fail and report
					$msg = "$(Get-Date) $podName - $ovfPath not found"
					Write-Host -Fore Red $msg
					Out-File -FilePath $currentFile.FullName -InputObject $msg -Append
					$currentFile = Rename-HolWorkingFile $podName $currentFile 'FAILED'
					Return
				}
				
				If( -not (Test-OVF -OVF $ovfPath) ) {
					# fail and report
					$msg = "$(Get-Date) $podName - $ovfPath incomplete"
					Write-Host -Fore Red $msg
					Out-File -FilePath $currentFile.FullName -InputObject $msg -Append
					$currentFile = Rename-HolWorkingFile $podName $currentFile 'FAILED'
					Return
				}

				If( $SeedOnly -ne $True ) {

					# Begin Import(s) -- spawn one new process ("job") for each import
					#
					# Handles special case like 1428 (allowExtraConfig) 
					# Still need to handle postprocessing like 1457 (metadata)
					#
					Foreach( $cloudKey in $TargetCloudKeys ) {
						$msg = "$(Get-Date) $podName - Import to $cloudKey starting..."
						Out-File -FilePath $currentFile.FullName -InputObject $msg -Append
						$mycmd = "Write-Host $msg ; Import-VPod -k $cloudKey -user $CloudUser -password $CloudPassword -VPodName $podName -LibPath $LibPath -Options '--skipManifestCheck --allowExtraConfig' -Catalog $TargetCloudCatalog"
#						Start-Job -Name "$cloudKey $podName IMP" -ScriptBlock { param($mycmd) Invoke-Expression -Command $mycmd } -ArgumentList $mycmd -InitializationScript { New-Alias -Name ovftool -Value 'C:\Program Files\VMware\vmware ovf tool\ovftool.exe' ; Import-Module 'E:\Scripts\hol-cmdlets.psd1' } 
						Start-Job -Name "$cloudKey $podName IMP" -ScriptBlock { param($mycmd) Invoke-Expression -Command $mycmd } -ArgumentList $mycmd -InitializationScript { Import-Module 'E:\Scripts\hol-cmdlets.psd1' } 
					}
	
					# Monitor local import(s)for completion. This section needs to be reworked a bit.
					# Wait for imports to complete, or just put the job onto the queue and check later?
					Try {
						$runningJobs = Get-Job -Name "* $podName IMP" -State Running -ErrorAction "Stop"
					}
					Catch {
						# No running jobs
					}
					While ($runningJobs) {
						$stillRunning = ''
						Foreach ($rj in $runningJobs) { 
							$stillRunning += $rj.Name
							$stillRunning += ' '
						}
						Write-Host -Fore Yellow "...waiting for import completion: $stillRunning"
						Start-Sleep -sec $SleepSeconds
					}
					
					# Send 'Import Successful' email
					$msg = "$(Get-Date) $podName - import successful"
					Write-Host -Fore Green $msg
					Out-File -FilePath $currentFile.FullName -InputObject $msg -Append
					Send-HolDaemonEmail -To $Email -Site $Site -Subject $podName -Body "Local import of $podName has finished."
	
					# Once imports begin, "shadow waiter" can be kicked off
					$msg = "$(Get-Date) $podName - shadows would be created here"
					Write-Host -Fore Yellow $msg
					Out-File -FilePath $currentFile.FullName -InputObject $msg -Append
					#Spawn jobs with Add-CIVappShadowsWait for each $TargetCloudKeys
					If( $ShadowCodeWorks ) {
						Foreach( $cloudKey in $TargetCloudKeys ) {
							($cloudHost, $cloudOrg) = Get-CloudInfoFromKey -Key $cloudKey
							If( $cloudHost -ne '' ) {
								$msg = "$(Get-Date) $podName - Shadowing in $cloudKey"
								Out-File -FilePath $currentFile.FullName -InputObject $msg -Append
								$mycmd = '
		Connect-CiServer -Server ' + $cloudHost + ' -Org ' + $cloudOrg + ' -User ' + $cloudUser + ' -Password ' + $cloudPassword + '
		Try { $orgVdcs = Get-OrgVdc ' + $OvdcFilter + ' } 
		Catch { Write-Host "No matching OrgVdc" ; Return }
		If($orgVdcs) { 
			Try { 
				$vPod = Get-civappTemplate -Catalog ' + $TargetCloudCatalog + ' -Name ' + $podName + '
				Add-CiVappShadowsWait -o $orgVdcs -v $vPod
			} Catch { Write-Host "No matching vPod" ; Return }
		}
		Disconnect-CiServer * -Confirm:$false'
	# This works for PowerCLI <6.0 (Add-PSSnapin)	
	#							Start-Job -Name "Shadow $podName in $cloudKey" -ScriptBlock { param($mycmd) Invoke-Expression -Command $mycmd } -ArgumentList $mycmd -InitializationScript { Add-PSSnapin VMware.VimAutomation.Cloud ; Import-Module E:\Scripts\hol-cmdlets.psm1 } 
	# For PowerCLI 6.0+
								Start-Job -Name "Shadow $podName in $cloudKey" -ScriptBlock { param($mycmd) Invoke-Expression -Command $mycmd } -ArgumentList $mycmd -InitializationScript { Import-Module VMware.VimAutomation.Cloud ; Import-Module E:\Scripts\hol-cmdlets.psd1 } 
							} Else {
								Write-Host -Fore Red "ERROR: invalid CloudKey specified: $cloudKey"
							}
						}
					}
				}

				# REMOTE: Send notification *back* to main catalog host
				#ssh to parent catalog and touch vPodName_$Site_FINISHED in /cygdrive/e/Mailbox/
				$touchFile = $RemoteMailboxPath + "$podName" + '_' + $Site + '_FINISHED'
				$syncCmd = 'ssh ' + $SshUser + '@' + $SourceCatalogHost + " touch $touchFile "
				$command = "C:\cygwin64\bin\bash.exe --login -c " + "'" + $syncCmd + "'"
				Write-Host -Fore Green "REPORTING OK:" $command
				Invoke-Expression -command $command

				# Mark finished and send Email
				$currentFile = Rename-HolWorkingFile $podName $currentFile 'FINISHED'
				Send-HolDaemonEmail -To $Email -Site $Site -Subject $podName -Body "Completed local processing of $podName."

			} Else {
				#No work to do... go to sleep
				If( $SeedOnly -eq $True ) { $SeedOnlyMsg = "(SEEDING ONLY)" }
				Write-Host "$(Get-Date) No work to do, sleeping $SleepSeconds seconds. $SeedOnlyMsg"
				Start-Sleep -Sec $SleepSeconds
			}
		}
	}
} #Start-HolVpodImportDaemon
