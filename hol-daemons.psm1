# Version 1.5.5 - 27 October 2015

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

Function Send-Email {
<#
	Send an Email via SMTP
	Note that this may not work with ehnanced SMTP "security" config
	Windows sends the actual name of the host, which Net.Mail.SmtpClient does not allow overriding
#>
	PARAM(
		$SmtpServer = $(throw "need -SmtpServer"),
		$From = $(throw "need -From address"),
		$To = $(throw "need -To address"),
		$Subject = "",
		$Body = ""
	)
	
	PROCESS {
		# Ideally, we should perform some validation of the parameters here, 
		# but we're going quick and dirty: not even a try/catch
		$emailServer = $SmtpServer
		$emailFrom = $From
		$emailTo = $To
		$emailSubject = $Subject
		$emailBody = $Body
		
		$smtp = New-Object Net.Mail.SmtpClient($emailServer)
		$smtp.Send($emailFrom, $emailTo, $emailSubject, $emailBody)

		Return $true
	}
} #Send-Email


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



Function Start-OvfTemplatePull {
<#
.SYNOPSIS
	Efficiently synchronize two OVF exports between sites using specified local data as the seed.

.DESCRIPTION
	Handles preprocessing tasks and calls lftp and/or rsync to perform replication
	
	Requires SSH connectivity to main CATALOG/LIBRARY system to pull latest version.

.PARAMETER
	CATALOGHOST - the name of the CATALOG host containing the new version of the vPod 
		this must be resolvable via DNS or hosts file

.PARAMETER
	REMOTELIB - the path to the new files on the CATALOGHOST, not including NEWNAME

.PARAMETER
	OLDNAME - the name of the local SEED vPod 

.PARAMETER
	NEWNAME - the name of the new vPod (the version in REMOTELIB)

.PARAMETER
	LOCALSEED - the local path to the SEED files, not including OLDNAME

.PARAMETER
	LOCALLIB - the path to the local LIBRARY files, not including NEWNAME

.PARAMETER
	SSHUSER - the user account used for SSH connection to CATALOGHOST

.PARAMETER
	OUTPUTPATH - path to the log file (optional)

.EXAMPLE - using defaults
	Start-OvfTemplatePull -OldName HOL-SDC-1400-v1 -NewName HOL-SDC-1400-v2

.EXAMPLE
	Start-OvfTemplatePull -OldName HOL-SDC-1400-v1 -NewName HOL-SDC-1400-v2 -CatalogHost MAIN-CATALOG -RemoteLib /cygdrive/c/MasterLibrary	-LocalSeed C:\Seeds\ -LocalLib C:\LocalLibrary -SSHuser holuser -OutputPath C:\LabMaps

#>
	PARAM(
		[Parameter(Position=0,Mandatory=$false,HelpMessage="Name of the catalog host",
		ValueFromPipeline=$False)]
		[System.String]$CatalogHost = $DEFAULT_CATALOGHOST,
	
		[Parameter(Position=1,Mandatory=$true,HelpMessage="Seed vApp Name (target)",
		ValueFromPipeline=$False)]
		[System.String]$OldName,
	
		[Parameter(Position=2,Mandatory=$true,HelpMessage="New vApp Name (source)",
		ValueFromPipeline=$False)]
		[System.String]$NewName,
	
		[Parameter(Position=3,Mandatory=$false,HelpMessage="SSH path to the source files (remote)",
		ValueFromPipeline=$False)]
		[System.String]$RemoteLib = $DEFAULT_REMOTELIB,
	
		[Parameter(Position=4,Mandatory=$false,HelpMessage="Path to the seed files (local)",
		ValueFromPipeline=$False)]
		[System.String]$LocalSeed = $DEFAULT_LOCALSEED,
	
		[Parameter(Position=5,Mandatory=$false,HelpMessage="Path to the library files (local)",
		ValueFromPipeline=$False)]
		[System.String]$LocalLib = $DEFAULT_LOCALLIB,
	
		[Parameter(Position=6,Mandatory=$false,HelpMessage="Path to the library files (local)",
		ValueFromPipeline=$False)]
		[System.String]$SSHuser = $DEFAULT_SSHUSER,
	
		[Parameter(Position=7,Mandatory=$false,HelpMessage="Path to output files",
		ValueFromPipeline=$False)]
		[System.String]$OutputPath = $DEFAULT_MAPOUTPUTPATH
	)
	BEGIN {
		Write-Host "=*=*=*=* OvfTemplatePull $NewName Start $(Get-Date) *=*=*=*="

		$debug = $false
		If ($debug) { Write-Host -Fore Yellow " ### DEBUG IS ON ### " }

		try { 
			if( Test-Path $OutputPath ) {
				$createFile = $true
				$fileName = $(Join-Path $OutputPath $($NewName.Replace(" ",""))) + ".txt"
				"#### STARTING $(Get-Date)" | Out-File $fileName -Append
			}
		}
		catch {
			Write-Host -Fore Yellow "Output path does not exist: logging disabled."
			$createFile = $false
		}
		
		### Setup any required SSH options (cygwin)
		$sshComputer = $CatalogHost
		$sshOptions = " "
	
		# prepend "/cygdrive/", lowercase drive letter, flip slashes, escape spaces
		function cygwinPath( $thePath ) {
			$x = $thePath.Split(":")
			Return "/cygdrive/" + ($x[0]).toLower() + $(($x[1]).Replace("\","/").Replace(" ","\ "))
		}
	
		# sometimes, there aren't enough slashes...
		function doubleEscapePathSpaces( $thePath ) {
			Return $thePath.Replace(" ","\\ ")
		}
		
		## cygwin version: generic command execution over SSH
		function exec-ssh( $cmd1 ) {
			$remoteCommand = '"' + $cmd1 + '"'
			$command = "ssh " + $sshOptions + " " + $SSHuser + "@" + $sshComputer + " " + $remoteCommand
			if( $debug ) { Write-Host "EXEC-SSH:" $command }
			if( $createFile ) { 
				$command | Out-File $fileName -Append 
			} else {
				Invoke-Expression -command $command 
			}
		}
	
		function Add-TrailingCharacter( $myPath, $myChar ) {
			if( $myPath[-1] -ne $myChar ) { return $myPath += $myChar }
			else { return $myPath }
		}
	
		# Do any cleanup we need to do before bailing
		function CleanupAndExit {
			Write-Host "Cleaning up and exiting"
			Exit
		}
	
		#cleanup (and validate?) the path inputs
		$LocalSeed = Add-TrailingCharacter $LocalSeed "\"
		$LocalLib = Add-TrailingCharacter $LocalLib "\"
		$RemoteLib = Add-TrailingCharacter $RemoteLib "/"
		
		#generate cygwin versions of the local LIBRARY and SEED paths
		$localLibPathC = cygwinPath $LocalLib
		$localSeedPathC = cygwinPath $LocalSeed
		
		if( -not (Test-Path $LocalSeed) ) {
			Write-Host -Fore Red "Error: path to SEED does not exist. Need working directory for seeds."
			CleanupAndExit
		}
		
		#These are required for the script to work.
		$requiredBinaries = $(
			'C:\cygwin64\bin\bash.exe'
			'C:\cygwin64\bin\rsync.exe'
			'C:\cygwin64\bin\lftp.exe'
			)
	
		#check to make sure required packages are present
		Foreach ( $req in $requiredBinaries ) {
			If (! (Test-Path $req) ) { 
				Write-Host -Fore Red "ERROR: CYGWIN $req not present. Unable to continue"
				CleanupAndExit
			} Else {
				If( $debug ) { Write-Host -fore Yellow "FOUND: CYGWIN $req" }
			}
		}
	}

###############################################################################

	PROCESS {
		
		#Make new local directory to contain new vPod, fail if it already exists
		$newVPodPath = Join-Path $LocalLib $NewName
		If( -not (Test-Path $newVPodPath) ) {
			mkdir $newVPodPath
		} Else {
			Write-Host -Fore Red "Error: Target Path already exists: $newVPodPath"
			If( $createFile ) {
				"Error: Target Path exists: $newVPodPath" | Out-File $fileName -append
			} 
			CleanupAndExit
		}
		
		#Option to handle pods without seeds (full copy to "seeds" directory using lftp)
		If( $OldName -eq 'NONE' ) {
			$lftpSource = "sftp://$sshUser" + ':xxx@' + $sshComputer + ':' + $RemoteLib + $NewName
			$lftpCmd = '/usr/bin/lftp -c \"mirror --only-missing --use-pget-n=5 --parallel=5 -p --verbose ' + "$lftpSource $localSeedPathC"+'\"'
			#run the LFTP in cygwin
			$command = "C:\cygwin64\bin\bash.exe --login -c " + "'" + $lftpCmd + "'"
			If( $createFile ) { $lftpCmd | Out-File $fileName -Append }
			If( $debug ) { Write-Host -fore Yellow "EXEC-LFTP: $command " } 
			Invoke-Expression -command $command
			
			## due to issues with lftp transferring and sometimes corrupting files, 
			##  run rsync after to validate integrity
			$OldName = $NewName
		}
	
		## at this point, there is something to use as a seed, so utilize specified seed

		# obtain the new OVF if not already present
		$newOvfPath = Join-Path $newVPodPath $($NewName + ".ovf")
		
		If( -not (Test-Path $newOvfPath) ) {
			# sanity check: we just created this directory, so OVF should not be here
			## GO GET IT VIA SSH
			$ovfFileRemoteEsc = doubleEscapePathSpaces $($RemoteLib + $NewName + "/" + $NewName + ".ovf")
			$newOvfPathC = cygwinPath $newOvfPath
			$command = "C:\cygwin64\bin\bash.exe --login -c 'scp "+ $sshOptions + $SSHuser + "@" + $sshComputer + ':"' + $ovfFileRemoteEsc + '" "' + $newOvfPathC +'"' +"'"
	
			if( $debug ) { Write-Host $command }
			if( $createFile ) { $command | Out-File $fileName -append } 
	
			Write-Host "Getting new OVF via SCP..."
			Invoke-Expression -command $command 
		}
	
		## second check -- see if we successfully downloaded it
		if( -not (Test-Path $newOvfPath) ) {
			Write-Host -Fore Red "Error: Unable to read new OVF @ $newOvfPath"
			CleanupAndExit
		}
	 
		#here, we have a copy of the new OVF in the new location
		[xml]$new = Get-Content $newOvfPath
		$newfiles = $new.Envelope.References.File
		$newvAppName = $new.Envelope.VirtualSystemCollection.Name 
	
		#Map the filenames to the OVF IDs in a hash table by diskID within the OVF
		$newVmdks = @{}
		foreach ($disk in $new.Envelope.References.File) {
			$diskID = ($disk.ID).Remove(0,5)
			$newVmdks.Add($diskID,$disk.href)
		}
		
		#### Read the SEED OVF
		$oldOvfPath = Join-Path $LocalSeed $(Join-Path $OldName $($OldName + ".ovf"))
	
		#ensure the file exists... 
		if( -not (Test-Path $oldOvfPath) ) {
			Write-Host -Fore Red "Error: unable to read seed OVF"
			CleanupAndExit
		}
		
		[xml]$old = Get-Content $oldOvfPath
		$oldfiles = $old.Envelope.References.File
		
		# For scripting, it is better to use the provided name than the "real" name from within
		#$oldvAppName = $old.Envelope.VirtualSystemCollection.Name
		$oldvAppName = $OldName
		
		#Map the VMDK file names to the OVF IDs in a hash table by diskID within the OVF
		$oldVmdks = @{}
		foreach ($disk in $old.Envelope.References.File) {
			$diskID = ($disk.ID).Remove(0,5)
			$oldVmdks.Add($diskID,$disk.href)
		}
		
		## Match the OLD VMs and their files (uses $oldVmdks to resolve)
		$oldVms = @()
		$oldVms = $old.Envelope.VirtualSystemCollection.VirtualSystem
		$oldDiskMap = @{}
		
		foreach ($vm in $oldVms) {
			#special case for vPOD router VM -- it has a version number and blows up when renamed
			if( $vm.name -like "vpodrouter*" ) {
				$oldDiskMap.Add("vpodrouter",@{})
			} else {
				$oldDiskMap.Add($vm.name,@{})
			}
	
			$disks = ($vm.VirtualHardwareSection.Item | Where {$_.description -like "Hard disk*"} | Sort -Property AddressOnParent)
			$i = 0
			foreach ($disk in $disks) {
				$parentDisks = @($Disks)
				$diskName = $parentDisks[$i].ElementName
				$i++
				$ref = ($disk.HostResource."#text")
				$ref = $ref.Remove(0,$ref.IndexOf("-") + 1)
				if ($vm.name -like "vpodrouter*") {
					($oldDiskMap["vpodrouter"]).Add($diskName,$oldVmdks[$ref])
				} 
				else {
					($oldDiskMap[$vm.name]).Add($diskName,$oldVmdks[$ref])
				}
			}
		}
		
		## Match the NEW VMs and their files (uses $oldVmdks to resolve)
		$newVms = @()
		$newVms = $new.Envelope.VirtualSystemCollection.VirtualSystem
		$newDiskMap = @{}
		
		foreach ($vm in $newVms) {
			#special case for vPOD router VM -- it gets a version number
			if( $vm.name -like "vpodrouter*" ) {
				$newDiskMap.Add("vpodrouter",@{})
			} 
			else {
				$newDiskMap.Add($vm.name,@{})
			}
	
			$disks = ($vm.VirtualHardwareSection.Item | Where {$_.description -like "Hard disk*"} | Sort -Property AddressOnParent)
			$i = 0
			foreach ($disk in $disks) {
				$parentDisks = @($Disks)
				$diskName = $parentDisks[$i].ElementName
				$i++
				$ref = ($disk.HostResource."#text")
				$ref = $ref.Remove(0,$ref.IndexOf("-") + 1)
				if ($vm.name -like "vpodrouter*") {
					($newDiskMap["vpodrouter"]).Add($diskName,$newVmdks[$ref])
				} 
				else {
					($newDiskMap[$vm.name]).Add($diskName,$newVmdks[$ref])
				}
			}
		}
	
	
		# Walk through the NEW disk map, create a hash table of the file mappings 
		# keys are FROM filenames and values are TO filenames
		Write-Host "`n=====>Begin VMDK Map and Move"
		foreach ($key in $newDiskMap.Keys) {
			#look up the NEW host (by name) in $oldDiskMap 
			foreach ($key2 in ($newDiskMap[$key]).Keys) { 
				#enumerate the disks per VM :"Hard disk #"
				#ensure ($oldDiskMap[$key])[$key2] exists prior to continuing
				$oldFileExists = $false
				if( $oldDiskMap.ContainsKey($key) ) {
					if( ($oldDiskMap[$key]).ContainsKey($key2) ) {
						$str1 = "	OLD " + $key2 + "->" + ($oldDiskMap[$key])[$key2]
						$oldFileExists = $true
					} 
					else {
						$str1 = "	NO MATCH for $key2 @ $key : new disk on VM"			
					}
				} 
				else {
					$str1 = "	NO MATCH for $key : net new VM"
				}
				$str2 = "	NEW " + $key2 + "->" + ($newDiskMap[$key])[$key2]
				Write "`n==> HOST: $key"
				Write $str1
				Write $str2
				#Rename the target files (seeds) to match the source's
				# SPACES _SUCK_
				#ssh needs whole command double-quoted and path-spaces double-escaped:
				#	ssh user@target "mv /cygdrive/.../path\\ with\\ spaces /cygdrive/.../path\\ with\\ more\\ spaces"
	
				$newPathEsc = doubleEscapePathSpaces $($localLibPathC + $newvAppName + "/" + ($newDiskMap[$key])[$key2])
				if( $oldFileExists ) {
					$oldPathEsc = doubleEscapePathSpaces $($localSeedPathC + $oldvAppName + "/" + ($oldDiskMap[$key])[$key2])
					$command = "C:\cygwin64\bin\bash.exe --login -c 'mv " + $oldPathEsc + " " + $newPathEsc + "'"
					Write-Host -Fore Yellow "	MOVE VMDK FILE: $command"
					if( $createFile ) { $command | Out-File $fileName -Append }
					if ( !($debug) ) { Invoke-Expression -command $command }
					$command = $null
				}
			}
		}
		Write-Host "`n=====>End VMDK Map and Move"
	
		
		Write-Host "`n=====>Begin file sync:"
		
		## When we get here, the SEED files have been matched and renamed to the same 
		## names as the matching files and relocated to the local LIBRARY 
		## in preparation for the rsync call. The local pod is "scrambled"
	
		# In rsync, the '-a' does weird things with Windows permissions for
		# non-admin users... use '-tr' instead
		#	EXAMPLE rsync -tvhPr --stats user@remote:/SOURCE/ /cygdrive/c/LOCAL_TARGET
		
		if( $debug ) { 
			#the -n performs the "dry run" analysis
			$rsyncOpts = '-tvhPrIn --stats --delete --max-delete=6' 
		} 
		else { 
			# BEWARE: this is a "real" rsync .. it can delete things!
			$rsyncOpts = '-tvhPrI --stats --delete --max-delete=6' 
		}
	
		#rsync needs SSH path to be double-quoted AND double-escaped:
		# user@target:"/cygdrive/.../path\\ with\\ spaces"
		$remotePathRsync = $RemoteLib + $newvAppName
	# $remotePathRsyncEsc = $remotePathRsync.Replace(" ","\ ")
		$remotePathRsyncEsc = doubleEscapePathSpaces $remotePathRsync
	
		#rsync needs local path to be escaped
		# /cygdrive/.../path\ with\ spaces/
		# [05/22/2013-DB .. what about using -s option to rsync? need to test]
	# $targetPathRsyncEsc = doubleEscapePathSpaces $($TargetPath + $newvAppName)
		$targetPathRsyncEsc = $($localLibPathC + $newvAppName).Replace(" ","\ ")
		
		$syncCmd = "rsync $rsyncOpts " + $SSHuser + "@"	+ $sshComputer + ':"' + $remotePathRsyncEsc + '/" "' + $targetPathRsyncEsc + '"'
	
		$command = "C:\cygwin64\bin\bash.exe --login -c " + "'" + $syncCmd + "'"
	
		if( $debug ) { Write-Host "REPLICATE:" $command }
		if( $createFile ) { $syncCmd | Out-File $fileName -Append }
		
		#A little validation before the call ... just to make sure something bad didn't happen
		If ( ($OldName -ne '') -and ($NewName -ne '') ) {
			Invoke-Expression -command $command 
		}
		
		# Remove old Seed directory (clean up)
		# arbitrary value of >5 files remaining to limit exposure of accidental deletion
	
		if( $OldName -ne "" ) {
			$oldSeedDir = Get-Item $(Join-Path $LocalSeed $OldName)
	
			#First, remove the "CHECKSUM" files
			Get-ChildItem $oldSeedDir -Filter Checksum* | Remove-Item
	
			$count = 0
			$oldSeedDir.EnumerateFiles() | % {$count +=1}
			#there should be none of these besides the Manifest, old OVF, and OVF_BAK files
			$oldSeedDir.EnumerateDirectories() | % {$count +=10}
			if( $count -lt 5 ) {
				Write-Host "Removing SEED directory $($oldSeedDir.FullName)"
				if( !($debug) ) { Remove-Item $oldSeedDir -Recurse -Confirm:$false }
			}
			else {
				$msg = "`nWARNING!! $count files remaining in SEED directory: $($oldSeedDir.FullName)"
				Write-Host -Fore Red $msg
				if( $createFile ) { $msg | Out-File $fileName -Append }
			}
		}
	}

###############################################################################

	END {
		Write-Host "`n=*=*=*=*=* OvfTemplatePull $NewName End $(Get-Date) *=*=*=*=*="
		if ($createfile) { "#### COMPLETED $(Get-Date)" | Out-File $fileName -Append }
	}
	
} #Start-OvfTemplatePull