### 
### HOL Administration Cmdlets
### -Doug Baer
###
### 2015 November 3
###
### Import-Module .\hol-cmdlets.psd1
### Get-Command -module hol-cmdlets
###

###### LOAD GLOBAL PER-CLOUD DEFAULTS FROM CONFIG FILE
$holSettingsFile = 'E:\Scripts\hol_cmdlets_settings.xml'

if( Test-Path $holSettingsFile ) {
	[xml]$SettingsFile = Get-Content $holSettingsFile
	#if the setting does not exist in the XML file, the result is ''
	$vcds = @{}
	foreach( $cloud in $SettingsFile.Settings.Clouds.Cloud ) { $vcds.Add($cloud.key,$cloud.host) }

	$orgs = @{}
	foreach( $cloud in $SettingsFile.Settings.Clouds.Cloud ) { $orgs.Add($cloud.key,$cloud.org) }

	$ovdcs = @{}
	foreach( $cloud in $SettingsFile.Settings.Clouds.Cloud ) { $ovdcs.Add($cloud.key,$cloud.ovdc) }

	$catalogs = @{}
	foreach( $cloud in $SettingsFile.Settings.Clouds.Cloud ) { $catalogs.Add($cloud.key,$cloud.catalog) }

	$creds = @{}
	foreach( $cloud in $SettingsFile.Settings.Clouds.Cloud ) { $creds.Add($cloud.key,$occ) }

	#these pods get special treatment (metadata added for VLP)
	$wiredUpVpods = @{}
	foreach( $vpod in $SettingsFile.Settings.VPodSettings.Metadata.WireUp ) { $wiredUpVpods.Add($vpod,"vappNetwork1") }

	#Read/Set Default values
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

<#
NOTE: To Store the password encrypted for use here:
		$c = Get-Credential $DEFAULT_CLOUDUSER
		$c.Password | ConvertFrom-SecureString | Set-Content $DEFAULT_CLOUDCREDENTIAL
#>

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

##Aliases (module-level)
if( !(Test-Path $DEFAULT_OVFTOOLPATH) ) {
	Write-Host -fore Red "!!! OVFtool not found: $DEFAULT_OVFTOOLPATH"
	Return
} else {
	try {
		New-Alias -Name ovftool -Value $DEFAULT_OVFTOOLPATH -ErrorAction 0
	}
	catch {
		Get-Alias ovftool
	}
}

Function SetHolPrompt {
<#
	Set the prompt to include the $cloudkey variable (used for per-session defaults)
#>
	Function global:Prompt { Write-Host "HOL/$cloudKey " -nonewline -fore Green ; Write-Host ((Get-Location).Path + ">") -NoNewLine ; return " " }
}


Function Connect-Cloud {
<#
	This is a shortcut to connecting to the various clouds used in HOL
	It relies on credential objects being instantiated in $profile
	It will default to using the $cloudKey variable defined in the current session
#>
	PARAM (
		$Key = $cloudKey
	)
	PROCESS {
		if( $Key -ne '' ) { 
			Write-host "Connecting to $($orgs[$Key]) in $($vcds[$Key])"
			Connect-CIServer $($vcds[$Key]) -org $($orgs[$Key]) -credential $($creds[$Key])
		} Else {
			Write-Host -Fore Red "ERROR: -Key or $cloudKey required"
		}
	}
} #Connect-Cloud


Function Add-CIVAppShadows {
<#
	Takes a list of vAppTemplates and a list of OrgVDCs
	Provisions one copy of a vApp on each OrgVdc simultaneously (asynchronously)
	Named <vAppName>_shadow_<OrgvdcName>
	with 5 hour storage and Runtime leases so vCD clean them up if you forget
	
	Waits for the last of the vApps to finish deploying before moving to the next template

	.EXAMPLE
	$vApps = @()
	$vAppNames | % { $vApps += (Get-CIVAppTemplate $_ -Catalog MY_CATALOG) } 
	$orgVDCs = @()
	$orgVdcNames | % { $orgVDCs += (Get-OrgVDC $_) }
	Add-CIVAppShadows -o $orgVdcs -v $vApps
#>
	PARAM (
		$vApps = $(throw "need -vApps"), 
		$OrgVDCs = $(throw "need -OrgVdcs"),
		$SleepTime = 120,
		[Switch]$DebugMe
	)
	
	PROCESS {
		$fiveHr = New-Object System.Timespan 5,0,0

		foreach( $vApp in $vApps ) {
			#LEGACY - add Internet-Connect Metadata if Description matches pattern
			if( $vApp.Description -like "*~" ) {
				Write-Host -fore Green "** Adding vCD metadata for VLP to wire up **"
				Add-InternetMetadata -vpodName $vApp.Name
			}

			#NEW - add Internet-Connect Metadata if truncated name exists in wiredUpVpods
			$foundV = ($vApp.Name).IndexOf('v')
			if( $foundV -ne -1 ) {
				$vAppShortName = ($vApp.Name).Substring(0,$foundV-1)
				if( $wiredUpVpods.ContainsKey($vAppShortName) ) {
					Write-Host -fore Green "** Adding vCD metadata for VLP to wire up **"
					Add-InternetMetadata -vpodName $vApp.Name
				}
			}
			
			#create one shadow on each orgvdc
			Write-Host -fore Green "Beginning shadows for $($vApp.Name) at $(Get-Date)"
			foreach( $orgVDC in $OrgVDCs ) { 
				$shadowName = $($($vApp.Name) + "_shadow_" + $($orgVDC.Name))
				New-CIVApp -Name $shadowName -OrgVdc $orgVDC -VAppTemplate $vApp -RuntimeLease $fiveHr -StorageLease $fiveHr -RunAsync | Out-Null
				Write-Host "==> Creating $shadowName"
			}
			
			#pulling the "Status" from the object returned by New-vApp isn't right. This works.
			$shadows = @{}
			$shadowPattern = $($vApp.Name) + "_shadow_*"
			if( $DebugMe ) { Write-Host -Fore Yellow "DEBUG: looking for $shadowPattern" }
			foreach( $shadow in $(Get-CIVApp $shadowPattern) ) { 
				$shadows.Add( $shadow.Name , $(Get-CIView -CIObject $shadow) )
			}

			#wait for all shadows of this template to complete before starting on next one
			while( $shadows.Count -gt 0 ) {
				#working around a Powershell quirk related to enumerating and modification
				$keys = $shadows.Clone().Keys

				foreach( $key in $keys ) {
					$shadows[$key].UpdateViewData()		
					if( $shadows[$key].Status -ne 0 ) { 
						#has completed (status=8 is good), remove it from the waitlist
						Write-Host "==> Finished $key with status $($shadows[$key].Status), $($shadows.count - 1) to go." 
						$shadows.Remove($key)
					}
				}

				#sleep between checks
				if( $shadows.Count -gt 0 ) {
					if( $DebugMe ) { Write-Host -Fore Yellow "DEBUG: Sleeping 120 sec at $(Get-Date)" }
					Sleep -sec $SleepTime
				}
			}
			Write-Host -fore Green "Finished shadows for $($vApp.Name) at $(Get-Date)"
		}
	}
} #Add-CIVAppShadows


Function Add-CIVAppShadowsWait {
<#
	Wait for a single template to be "Resolved" then kick off shadows
	Quick and dirty... no error checking.. can go infinite if the import fails
#>
	PARAM (
		$vApp = $(throw "need -vApps"), 
		$OrgVDCs = $(throw "need -OrgVdcs"),
		$SleepTime = 300
	)
	PROCESS {
		while( $vApp.status -ne "Resolved" ) {
			write-host "$($vApp.status) : $(($vApp.ExtensionData.Tasks).Task[0].Progress)% complete"
			Sleep -sec $SleepTime
			$vApp = Get-civapptemplate $vApp.name -catalog $vApp.catalog
		}
		Add-CIVAppShadows -o $OrgVDCs -v $vApp
	}
} #Add-CIVAppShadowsWait


Function Compare-Catalogs {
<#
	Compares vApp Templates in two specified catalogs, possibly across clouds
	This is a "source-target" relationship rather than a two-way differential
#>
	PARAM(
		$CatalogSrcName = $(throw "need -CatalogSrcName"),
		$CloudSrcName = $(throw "need -CloudSrcName"),
		$OrgSrcName = $(throw "need -OrgSrcName"),
		$CatalogNewName = $(throw "need -CatalogNewName"),
		$CloudNewName = $(throw "need -CloudNewName"),
		$OrgNewName = $(throw "need -OrgNewName"),
		$TemplateFilter = 'HOL-*'
	)
	PROCESS {
	
		##TODO: check authentication to both clouds here
	
		try {
			$catSrc = Get-Catalog $catalogSrcName -Server $cloudSrcName -MyOrgOnly -ErrorAction Stop | Where {$_.org.name -eq $OrgSrcName}
		}
		catch { 
			Write-Host -Fore Red "Unable to find catalog on source cloud. Please verify that you are logged in to $CloudSrcName."
			Return
		}
		try {
			$catNew = Get-Catalog $catalogNewName -Server $cloudNewName -MyOrgOnly -ErrorAction Stop | Where {$_.org.name -eq $OrgNewName}
		}
		catch { 
			Write-Host -Fore Red "Unable to find catalog on target cloud. Please verify that you are logged in to $CloudNewName."
			Return
		}

		#Build the list of "available" vPods in the "source"
		$vAppList = @{}

		foreach( $vApp in ( $catSrc.ExtensionData.CatalogItems.catalogItem | where { $_.name -like $TemplateFilter } ) ) {
			$vAppList.Add( $($vApp.Name), "X" )
		}

		#Walk the "target" catalog and remove any that it already has
		foreach( $vApp in ( $catNew.ExtensionData.CatalogItems.catalogItem | where { $_.name -like $TemplateFilter } ) ) {
			if( $vAppList.ContainsKey( $vApp.Name ) ) {
				$vAppList.Remove($vApp.Name)
			}
		}

		#Here, the list contains the vApp Templates that are not yet in the Library
		if( $vAppList.Count -ne 0 ) {
			#What's left is the list of vPods that are different
			Write-Host "==> vApp Templates present in $CatalogSrcName on $CloudSrcName"
			Write-Host "==> and not in $catalogNewName on $cloudNewName"
			foreach( $name in ($vAppList.Keys) ) { Write-Host $name }
			Write-Host ""
			#Return the vPod names on the pipeline for further processing
			Return $($vAppList.Keys | Sort)
		} else {
			Write-Host "==>No vApp Templates exist in $CatalogSrcName on $CloudSrcName"
			Write-Host "==> and not in $CatalogNewName on $CloudNewName"
			Return
		}
	}
} #Compare-Catalogs


Function Compare-CatalogToDirectory {
<#
	Compare a vCD Catalog to a directory of exports (a "Library")
	Assumes catalog is authoritative source of vApp Templates.
	Output is an array of vApp Templates that exist in the Catalog 
		but not the specified directory.

	Requires being logged in to the cloud in question.

#>
	PARAM(
		$ServerName = $(throw "need -ServerName"),
		$OrgName = $(throw "need -OrgName"),
		$CatalogName = $(throw "need -CatalogName"),
		$LibraryPath = $DEFAULT_LOCALLIB
	)
	PROCESS {
		try { 
			$catalog = Get-Catalog $CatalogName -Server $ServerName -MyOrgOnly -ErrorAction Stop
		}
		catch {
			Write-Host -Fore Red "Not connected to $ServerName or missing catalog $CatalogName"
			Return
		}

		if( -Not (Test-Path $LibraryPath) ) { 
			Write-Host -Fore Red "Library path $LibraryPath is not reachable."
			Return
		}
	
		$library = Get-ChildItem $LibraryPath | where {$_.mode -match "d"} | select Name

		if( $catalog.VAppTemplateCount -eq 0 ) {
			Write-Host -Fore Red "$CatalogName contains no vApp Templates"
			Return
		}
		#Build the list of vApp Templates in the Catalog
		$vAppList = @{}
		foreach( $vApp in (Get-CIVappTemplate -catalog $catalog) ) {
			$vAppList.Add($($vApp.name), $vApp)
		}
		#Walk the "target" Library and remove from the list any that already exist
		foreach( $vApp in $library ) {
			if( $vAppList.ContainsKey($vApp.Name) ) { $vAppList.Remove($vApp.Name) }
		}
	
		#Here, the list contains the vApp Templates that are not yet in the Library
		if( $vAppList.Count -ne 0 ) {
			Write-Host "=== vPods in $CatalogName and not $LibraryPath ==="
			foreach( $name in ($vAppList.Keys) ) { Write-Host $name }
			Write-Host ""
			
			#Return the vPod names on the pipeline for further processing
			Return $($vAppList.Values)
		} else {
			Write-Host "No vApp Templates exist in $CatalogName and not $LibraryPath"
			Return
		}
	}
} #Compare-CatalogToDirectory


Function Compare-DirectoryToCatalog {
<#
	Compare a directory of exports (a "Library") to a vCD catalog.
	Assumes directory is authoritative source of vApp Templates.
	Output is the names of vApp Templates that exist in the directory 
		but not the specified Catalog.

	Requires being logged in to the cloud in question.

#>
	PARAM(
		$ServerName = $(throw "need -ServerName"),
		$OrgName = $(throw "need -OrgName"),
		$CatalogName = $(throw "need -CatalogName"),
		$LibraryPath = $DEFAULT_LOCALLIB
	)

	PROCESS {
		try { 
			$catalog = Get-Catalog $CatalogName -Server $ServerName -MyOrgOnly -ErrorAction Stop
		}
		catch {
			Write-Host -Fore Red "Not connected to $ServerName or missing catalog $CatalogName"
			Return
		}

		if( -Not (Test-Path $LibraryPath) ) { 
			Write-Host -Fore Red "Library path $LibraryPath is not rachable."
			Return
		}
	
		$library = Get-ChildItem $LibraryPath | where {$_.mode -match "d"} | select Name
		if( -not $library ) {
			Write-Host -Fore Red "Empty Library at $LibraryPath"
			Return
		}
		#Build the list of vApp Templates in the Library (directory)
		$vAppList = @{}
		foreach( $vApp in $library ) {
			$vAppList.Add($($vApp.name), "X")
		}
		#Walk the "target" Catalog and remove from the list any that already exist
		foreach( $vApp in (Get-CIVappTemplate -catalog $catalog) ) {
			if( $vAppList.ContainsKey($vApp.Name) ) { $vAppList.Remove($vApp.Name) }
		}
	
		#The remainder contains the ones that are not yet in the Catalog
		if( $vAppList.Count -ne 0 ) {
			Write-Host "=== vPods in $libraryPath and not $CatalogName ==="
			foreach( $name in ($vAppList.Keys) ) { Write-Host $name }
			Write-Host ""
			
			#Return the vPod names on the pipeline for further processing
			Return $($vAppList.Keys | Sort)
		} else {
			Write-Host "No vApp Templates exist in $LibraryPath and not $CatalogName"
			Return
		}
	}
} #Compare-DirectoryToCatalog


Function Test-Ovf {
<#
	Tests whether all files referenced in an OVF exist on disk
	Takes full path to OVF, assumes referenced files are in same directory
	Returns True or False
#>
	PARAM(
		$OVF = $(throw "need -OVF (path to OVF file)")

	)
	PROCESS {
		#Read the OVF
		try {
			[xml]$new = Get-Content $OVF -ErrorAction "Stop"
		}
		catch {
			Return $false
		}
		#Read the filenames and sizes into a hash table
		$ovfVmdks = @{}
		foreach( $disk in $new.Envelope.References.File ) {
			$ovfVmdks.Add($disk.href,$disk.size)
		}
		#Read the files from the current directory
		#note that new OVFs can specify other files like .json or .rpms as well
		#so the original *.vmdk" filter has been removed
		$vmdkFiles = Get-ChildItem $(Split-Path $ovf) | select Name, Length
		#compare
		foreach( $vmdk in ($vmdkFiles) ) {
			if( $ovfVmdks.ContainsKey($vmdk.Name) ) { 
				if( $($ovfVmdks[$vmdk.Name]) -eq $($vmdk.Length) ) {
					$ovfVmdks.Remove($vmdk.Name) 
				}
			}
		}
		#if there is nothing left in the $ovfVmdks, that's good...
		if( $ovfVmdks.Count -eq 0 ) { Return $true }
		else { 
			foreach( $vmdk in ($ovfVmdks.Keys) ) {
				Write-Host -Fore Red "Missing file: $vmdk with length $($ovfVmdks[$vmdk])"
			}
			Return $false
		}
	}
} #Test-Ovf


Function Get-OvfMap {
<#
	Feed it an OVF and it will spit out the mapping of VMDK-to-VM within the vPod
#>
	PARAM(
		$OVF = $(throw "need -Ovf")
	)
	PROCESS {
		#Read the OVF
		[xml]$new = Get-Content $OVF
		$newfiles = $new.Envelope.References.File
		$newvAppName = $new.Envelope.VirtualSystemCollection.Name 
	
		#Read the filenames to the OVF IDs in a hash table by diskID within the OVF
		Write-Host "`n=====>OVF Mapping for $newvAppName"
		$newVmdks = @{}
		foreach( $disk in $new.Envelope.References.File ) {
			$diskID = ($disk.ID).Remove(0,5)
			$newVmdks.Add($diskID,$disk.href)
		}
		## Match the VMs and their files
		$newVms = @()
		$newVms = $new.Envelope.VirtualSystemCollection.VirtualSystem
		$newDiskMap = @{}
	
		foreach( $vm in $newVms ) {
			$newDiskMap.Add($vm.name,@{})
			$disks = ($vm.VirtualHardwareSection.Item | Where {$_.description -like "Hard disk*"} | Sort -Property AddressOnParent)
			$i = 0
			foreach( $disk in $disks ) {
				$parentDisks = @($Disks)
				$diskName = $parentDisks[$i].ElementName
				$i++
				$ref = ($disk.HostResource."#text")
				$ref = $ref.Remove(0,$ref.IndexOf("-") + 1)
				($newDiskMap[$vm.name]).Add($diskName,$newVmdks[$ref])
			}
		}
		
		#Output the data
		foreach($key in $newDiskMap.Keys ) {
			foreach( $key2 in ($newDiskMap[$key]).Keys ) { 
				$str2 = "	" + $key2 + "->" + ($newDiskMap[$key])[$key2]
				if( $key -ne $curKey ) { 
					Write "`n==> VM: $key"
					$curKey = $key
				}
				Write $str2
			}
		}
	}
} #Get-OvfMap


Function Get-MountPointFreeSpace {
<#
	Reports free space information for mount points on local host; Windows sucks at this on its own.
#>
	$server = "localhost"
	$TotalGB = @{Name="Capacity(GB)";expression={[math]::round(($_.Capacity/ 1073741824),2)}}
	$FreeGB = @{Name="FreeSpace(GB)";expression={[math]::round(($_.FreeSpace / 1073741824),2)}}
	$FreePerc = @{Name="Free(%)";expression={[math]::round(((($_.FreeSpace / 1073741824)/($_.Capacity / 1073741824)) * 100),0)}}
	$volumes = Get-WmiObject -computer $server win32_volume | Where-object {$_.DriveLetter -eq $null}
	$volumes | Select SystemName, Label, $TotalGB, $FreeGB, $FreePerc | Format-Table -AutoSize
} #Get-MountPointFreeSpace


Function Publish-VCDMediaDirectory {
<#
	Upload a directory of ISOs to a vCD catalog
	WARNINGS:
		* vCD periodically fails this for unknown reasons
		* not tested very much
#>
	PARAM(
		$Catalog = $(throw "need -Catalog"),
		$OrgVdc = $(throw "need -OrgVdc"),
		$LibraryPath = $(throw "need -LibraryPath (folder containing ISOs)")
	)
	PROCESS {
		# Get the ISOs that are in the specified folder
		Get-ChildItem $LibraryPath -Filter *.iso | %{
			#Preserve the current item
			$iso = $_
			#Test to determine whether the object already exists
			try {
				$mediaList = Get-Media $iso.Name -Catalog $catalog -ea 1
				Write-Host "Media object $($iso.Name) found, not importing"
			}
			catch {
				Write-Host "Media object $($iso.Name) not found, importing"
				#It does not exist, create the media object
				$media = New-Object VMware.VimAutomation.Cloud.Views.Media
				$media.name = $iso.name
				$media.ImageType = 'iso'
				$media.size = $iso.length
				
				$media.Files = New-Object VMware.VimAutomation.Cloud.Views.FilesList
				$media.Files.File = @(new-object VMware.VimAutomation.Cloud.Views.File)
				$media.Files.File[0] = new-object VMware.VimAutomation.Cloud.Views.File
				$media.Files.file[0].type = 'iso'
				$media.Files.file[0].name = $iso.name
				
				$OrgVdc.ExtensionData.CreateMedia($media)
				
				$filehref = (Get-Media $media.name | Get-CIView).files.file[0].link[0].href
				$webclient = New-Object system.net.webclient
				$webclient.Headers.Add('x-vcloud-authorization',$global:DefaultCIServers[0].sessionid)
				Write-Host "Uploading $($iso.Name)"
				$webclient.Uploadfile($filehref, 'PUT', $iso.fullname)
			}
		}

		#Add media w/o catalog to the specified catalog
		$unboundMediaList = Get-Media | where {!$_.catalog}
		
		foreach( $unboundItem in $unboundMediaList ) {
			$newItem = New-Object VMware.VimAutomation.Cloud.Views.CatalogItem
			$newItem.Entity = $unboundItem.href
			$newItem.name = $unboundItem.name
			$newItem.description = ""
			Write-Host "	Adding $($unboundItem.Name) to $($catalog.Name)"
			$catalog.extensiondata.createcatalogitem($newItem)
		}
	}
} #Publish-VCDMediaDirectory


Function Set-CleanOvf {
<#
	* Look for blank but required ovf password parameters, set them to "VMware1!"
	* Look for and remove "stuck" NAT rules
	* Look for CustomizeOnInstantiate flag set and unset
	* Look for VMs with "POOL" addresses and change to "DHCP"
	
	* 2015 Update: generate and replace OVF's checksum in Manifest
	* Correct VMDK sizes specified in MB, but are smaller than data population
#>
	PARAM(
		#Path to vPod library. Will be read recursively for *.OVF files
		$LibraryPath = $(throw "need -LibraryPath")
	)
	PROCESS {
		$ovfs = Get-ChildItem -path $LibraryPath -include "*.ovf" -Recurse
		foreach( $ovf in $ovfs ) {
			Write-Host -fore Green "BEGIN: Cleaning $ovf"
			$manifestExists = $false
			#Create the expected Manifest file's path
			$mf = $ovf.FullName.Replace('.ovf','.mf')
			if( Test-Path $mf ) { 
				$manifestExists = $true
				$ovfHash = (Get-FileHash -Algorithm SHA1 -Path $ovf.FullName).Hash.ToLower()
			}
			#See if this has already been run (don't clobber backup!)
			$backupOVF = $ovf.fullName + "_BAK"
			if( -Not (Test-Path $backupOVF) ) {
				#Make a backup of the OVF file into the BAK file
				Copy-Item -LiteralPath $ovf.fullName -Destination $backupOVF -Force
				#these are used to filter out the NET rules
				$keep = $true ; $last = $false
				#keep track of what has been done .. for reporting later
				$setPassword = $false
				$setCustomize = $false
				$setPool = $false
				$removedNat = $false
				$smallDisks = $false

				### Handle vCD/OVF "rounding error" - KB#2094271
				[xml]$xmlOvf = Get-Content $OVF
				$newDiskReferences = $xmlOvf.Envelope.References.File
				$DisksAllocatedInMb = $xmlOvf.Envelope.DiskSection.Disk | where { $_.capacityAllocationUnits -eq 'byte * 2^20'}

				$vmdkSizes = @{}
				foreach( $disk in $newDiskReferences ) {
					$diskID = ($disk.ID).Remove(0,5)
					$vmdkSizes.Add($diskID,$disk.size)
				}

				$disksToResize = @{}
				foreach( $disk in $DisksAllocatedInMb ) {
					$diskID = ($disk.fileRef).Remove(0,5)
					$diskRequiredSize = $disk.populatedSize
					$diskCapacity = [int]($disk.capacity)
					$diskCapacitySize = $diskCapacity * 1MB
					$diskFileSize = $($vmdkSizes[$diskID])
					$diskSizeDifference = $diskFileSize - $diskCapacitySize

					#the issue is that the FileSize > CapacitySize in some cases

					if( $diskSizeDifference -gt 0 ) {
						$increaseMB = [math]::Ceiling($diskSizeDifference / 1MB)
						Write-Output ("`tDisk {0} is {1:N0} bytes too small.`n`tIncreasing from {2:N0} to {3:N0} MB" -f $diskId, $diskSizeDifference, $diskCapacity, ($diskCapacity + $increaseMB) )
						$disksToResize.Add($diskID, $increaseMB )
						$diskCapacity += $increaseMB
					}
				}

				(Get-Content $ovf.fullName) | % { 
					$line = $_

					foreach( $disk in $disksToResize.Keys ) {
						if( $line -match "vmdisk-$disk" ) {
							#handle the mis-allocated VMDK/vCD rounding issue
							If( $line -match '.*ovf:capacity="(\d+)".*' ) {
								$oldSize = $matches[1]
								$newSize = [int]$oldSize + $disksToResize[$disk]
								$line = $line -replace $oldSize, $newSize 
								Write-Host "Replacing $oldSize with $newSize"
								$smallDisks = $true
							}
							#not necessary since it falls through to the Else while $keep=true
							#$line
						}
					}

					#handle the OVF password stripping that vCD performs
					if( $line -match 'ovf:password="true"' ) {
						$line = $line -replace 'value=""','value="VMware1!"' 
						$setPassword = $true
						$line
					}
					elseif( $line -match 'CustomizeOnInstantiate>true' ) {
						#handle the CustomizeOnInstantiate -- we don't want it!
						$line = $line -replace 'true','false' 
						$setCustomize = $true
						$line
					}
					elseif( $line -match 'vcloud:ipAddressingMode="POOL"' ) {
						#POOL ip addresses to DHCP
						$line = $line -replace '<rasd:Connection vcloud:ipAddress="[0-9.]+" vcloud:ipAddressingMode="POOL"' , '<rasd:Connection vcloud:ipAddressingMode="DHCP"'
						$setPool = $true
						$line
					}
					else {
						#handle "stuck" NAT rules
						if( $line -match '<vcloud:NatService>' ) { 
							$keep = $false
							$removedNat = $true
						}
						if( $line -match '</vcloud:NatService>' ) { 
							$keep = $true
							$last = $true
						}
						if( $keep -and !$last ) {
							$line
						}
						if( $last ) {
							$last = $false
						}
					}
				} | Out-String | %{ $_.Replace("`r`n","`n") } | Out-File -FilePath $ovf.fullname -encoding "ASCII"

				if( $setPassword ) {
					Write "Set Password in file: $($ovf.name)"
				}
				if( $setPool ) {
					Write-Host -fore Yellow "Changed Pool to DHCP in file: $($ovf.name)"
				}
				if( $setCustomize ) {
					Write-Host -fore Red "Set CustomizeOnInstantiate in file: $($ovf.name)"
				}
				if( $removedNat ) {
					Write "Removed NAT rules in file: $($ovf.name)"
				}
				if( $smallDisks ) {
					Write "Fixed disk sizes in file: $($ovf.name)"
				}
				#Regenerated the OVF, so need a new Hash
				if( $manifestExists ) {
					$newOvfHash = (Get-FileHash -Algorithm SHA1 -Path $ovf.FullName).Hash.ToLower()
					$backupMF = $mf + '_BAK'
					Copy-Item -LiteralPath $mf -Destination $backupMF -Force
					(Get-Content $mf) | % { 
						$line = $_
						if( $line -match $ovfHash ) {
							$line = $line -replace $ovfHash,$newOvfHash
						}
						$line
					} | Out-File -FilePath $mf -encoding "ASCII"
				}
			}
			Write-Host -fore Green "END: Cleaning $ovf"
		}
	}
} #Set-CleanOvf


### Some vCD Metadata management functions from Alan Renouf

Function Get-CIMetaData { 
	<# 
	.SYNOPSIS 
		Retrieves all Metadata Key/Value pairs. 
	.DESCRIPTION 
		Retrieves all custom Metadata Key/Value pairs on a specified vCloud object 
		Updated 6-Mar-2014 by Doug Baer to support vCD 5.1 Metadata
	.PARAMETER	CIObject 
		The object on which to retrieve the Metadata. 
	.PARAMETER	Key 
		The key to retrieve. 
	.EXAMPLE 
		PS C:\> Get-CIMetadata -CIObject (Get-Org Org1) 
	#> 
	PARAM( 
		[parameter(Mandatory=$true,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)] 
			[PSObject[]]$CIObject, 
			$Key 
		)
	PROCESS { 
		foreach( $Object in $CIObject ) { 
			if( $Key ) { 
				($Object.ExtensionData.GetMetadata()).MetadataEntry | Where {$_.Key -eq $key } | Select @{N="CIObject";E={$Object.Name}}, Key, @{N="Value";E={$_.TypedValue.Value}} 
			} else { 
				($Object.ExtensionData.GetMetadata()).MetadataEntry | Select @{N="CIObject";E={$Object.Name}}, Key, @{N="Value";E={$_.TypedValue.Value}} 
			}
		}
	}
} #Get-CIMetaData


Function New-CIMetaData { 
	<# 
	.SYNOPSIS 
		Creates a Metadata Key/Value pair. 
	.DESCRIPTION 
		Creates a custom Metadata Key/Value pair on a specified vCloud object 
	.PARAMETER	Key 
		The name of the Metadata to be applied. 
	.PARAMETER	Value 
		The value of the Metadata to be applied. 
	.PARAMETER	CIObject 
		The object on which to apply the Metadata. 
	.EXAMPLE 
		PS C:\> New-CIMetadata -Key "Owner" -Value "Alan Renouf" -CIObject (Get-Org Org1) 
	.NOTE
		Setting a key in the 'SYSTEM' domain requires sysadmin access, I believe:
			$Metadata.MetadataEntry[0].Domain = New-Object VMware.VimAutomation.Cloud.Views.MetadataDomainTag
			$Metadata.MetadataEntry[0].Domain.Value = 'SYSTEM'
			$Metadata.MetadataEntry[0].Domain.Visibility = 'READONLY' or 'PRIVATE'
	#> 
	 [CmdletBinding( 
		 SupportsShouldProcess=$true, 
		ConfirmImpact="High" 
	)] 
	PARAM( 
		[parameter(Mandatory=$true,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)] 
			[PSObject[]]$CIObject, 
			$Key, 
			$Value 
		) 
	PROCESS { 
		foreach( $Object in $CIObject ) { 
			$Metadata = New-Object VMware.VimAutomation.Cloud.Views.Metadata 
			$Metadata.MetadataEntry = New-Object VMware.VimAutomation.Cloud.Views.MetadataEntry 
			$Metadata.MetadataEntry[0].Key = $Key
			$Metadata.MetadataEntry[0].TypedValue = New-Object VMware.VimAutomation.Cloud.Views.MetadataStringValue
			$Metadata.MetadataEntry[0].TypedValue.Value = $Value
			$Object.ExtensionData.CreateMetadata($Metadata) 
			($Object.ExtensionData.GetMetadata()).MetadataEntry | Where {$_.Key -eq $key } | Select @{N="CIObject";E={$Object.Name}}, Key, @{N="Value";E={$_.TypedValue.Value}} 
		} 
	} 
} #New-CIMetaData


Function Remove-CIMetaData { 
	<# 
	.SYNOPSIS 
		Removes a Metadata Key/Value pair. 
	.DESCRIPTION 
		Removes a custom Metadata Key/Value pair on a specified vCloud object 
	.PARAMETER	Key 
		The name of the Metadata to be removed. 
	.PARAMETER	CIObject 
		The object on which to remove the Metadata. 
	.EXAMPLE 
		PS C:\> Remove-CIMetaData -CIObject (Get-Org Org1) -Key "Owner" 
	.NOTE
		If the key is in the 'SYSTEM' domain, you need to specify the domain: GetMetaDataValue($Key,'SYSTEM') 
	#> 
	 [CmdletBinding( 
		 SupportsShouldProcess=$true, 
		ConfirmImpact="High" 
	)] 
	PARAM( 
		[parameter(Mandatory=$true,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)] 
			[PSObject[]]$CIObject, 
			$Key 
		)
	PROCESS { 
		$CIObject | foreach { 
			try {
				$metadataValue = ($_.ExtensionData.GetMetadata()).GetMetaDataValue($Key)
			}
			catch {
				Write "Key $key not found on object $($_.Name)"
			} 
			if( $metadataValue ) { $metadataValue.Delete() } 
		} 
	} 
} # Remove-CIMetaData


Function Import-VPod {
<#
	Takes a vPod Name, Catalog, "cloud key", and a path to the vPod Library
	Imports the OVF located at <library>\vPodName\vPodName.ovf
	Will attempt to resume until successful completion (or 5x) -- Imports should NOT be failing
	Written for OVFTOOL 3.x ... works with 4.1.0
#>
	PARAM (
		$Key = $cloudKey,
		$Catalog = $DEFAULT_TARGETCLOUDCATALOG,
		$VPodName = $(throw "need -VPodName"), 
		$LibPath = $DEFAULT_LOCALLIB,
		$User = $DEFAULT_CLOUDUSER,
		$Password = $DEFAULT_CLOUDPASSWORD,
		$AlternateName = '',
		$Options = '--allowExtraConfig',
		$MaxRetries = 5
	)
	PROCESS {

		$ovfPath = Join-Path $LibPath $($VPodName + "\" + $VPodName + ".ovf")
		
		#test path, bail if not found
		if( !(Test-Path $ovfPath) ) {
			Write-Host -fore Red "!!! OVF file not found: $ovfPath"
			Return
		}
		
		## Import-CIVAppTemplate does not check for all VMDKs, but will DIE if something is not there

		## Check to see if all the vmdk files referenced in the OVF exist.
		if ( !(Test-Ovf -Ovf $ovfPath) ) {
			Write-Host -fore Red "!!! OVF incomplete on disk"
			Return
		}

		$retryCount = 0
		
		if( $AlternateName -ne '' ) {
			$vp = $AlternateName
		} else {
			$vp = $VPodName
		}

		$k = $Key
		$un = $User

		if($Password -eq "") {
			$pw = 'xx'
		} else { 
			$pw = $Password
		}
		
		$type = 'vappTemplate'
		
		if( $Catalog -eq "" ) {
			Write-Host "	Importing to default catalog: $($catalogs[$k])"
			$cat = $catalogs[$k]
		} else {
			$cat = $Catalog
		}

		$src = $ovfPath
		$tgt = "vcloud://$un" + ':' + $pw + '@' + $vcds[$k] + ':443/?org=' + $orgs[$k] + '&vdc=' + $ovdcs[$k] + "&catalog=$cat&$type=$vp"

		Write-Host -fore Yellow "DEBUG: Target is: $($vcds[$k]) org: $($orgs[$k]) ovdc: $($ovdcs[$k])"

		#Options ( additional options to OVFtool like '--overwrite')
		#PS doesn't seem to like passing multiple params to ovftool..
		$opt = $Options

		Write-Host -fore Yellow "DEBUG: $opt from $src to $($vcds[$k]) org: $($orgs[$k]) ovdc: $($ovdcs[$k]) catalog: $cat"

		Write-Host -fore Green "Beginning import of vPod $vPodName at $(Get-Date)"
		### need to put in a loop to ensure it is restarted if it times out. 
		Do {
			$retryCount += 1
			Write-Host "	Running ovftool (try $retryCount of $MaxRetries) for $vp with options: $opt"
			Invoke-Expression -Command $("ovftool $opt $src '" + $tgt +"'")
			Sleep -sec 60
		} Until ( ($lastexitcode -eq 0) -or ($retryCount -gt $MaxRetries) )
		
		if( !($retryCount -gt $maxRetries) ) {
			Write-Host -fore Green "Completed import of vPod $vPodName at $(Get-Date)"
		} else {
			Write-Host -fore Red "FAILED import of vPod $vPodName at $(Get-Date)"
		} 
	}
} #Import-VPod


Function Export-VPod {
<#
   Takes a vPod Name, Catalog, "cloud key", and a path to the vPod Library
   Exports the vPod to an OVF located at <library>\vPodName\vPodName.ovf
   Will attempt to resume until successful completion (or 20x)
   ALWAYS uses '--exportFlags=preserveIdentity' flag to ovftool for HOL

#>
	PARAM (
		$Key = $cloudKey,
		$Catalog = $DEFAULT_SOURCECLOUDCATALOG,
		$VPodName = $(throw "need -VPodName"), 
		$LibPath = $DEFAULT_LOCALLIB,
		$User = $DEFAULT_CLOUDUSER,
		$Password = $DEFAULT_CLOUDPASSWORD,
		$MaxRetries = 20,
		$Options = '--exportFlags=preserveIdentity --allowExtraConfig',
		[Switch]$Print
	)
	PROCESS {

		$ovfPath = Join-Path $LibPath $($VPodName + "\" + $VPodName + ".ovf")

		#test path to OVF, bail if found: no clobbering
		if( (Test-Path $ovfPath) ) {
			Write-Host -fore Red "!!! OVF file found: $ovfPath"
			Return
		}

		$retryCount = 0

		$vp = $VPodName
		$k = $Key
		$un = $User
		$pw = $Password
		$type = 'vappTemplate'

		if( $Catalog -eq "" ) {
			Write-Host "	 Exporting from default catalog: $($catalogs[$k])"
			$cat = $catalogs[$k]
		} else {
			$cat = $Catalog
		}

		$tgt = $ovfPath
		$src = "vcloud://$un" + ':' + $pw + '@' + $vcds[$k] + ':443/?org=' + $orgs[$k] + '&vdc=' + $ovdcs[$k] + '&catalog=' + $cat + '&' + "$type=$vp"

		#Options ... ALWAYS preserveIdentity for HOL
		$opt = $Options

		if( $Print ) { Write-Host -Fore Green "$opt $src $tgt" }

		Write-Host -fore Green "Beginning export of vPod $vPodName at $(Get-Date)"
		### need to put in a loop to ensure it is restarted when ovftool times out waiting for vCD
		Do {
			$retryCount += 1
			Write-Host "	 Running ovftool (try $retryCount of $MaxRetries)"
			Invoke-Expression -Command $("ovftool $opt '" + $src + "' $tgt")
			Sleep -sec 60
		} Until ( ($lastexitcode -eq 0) -or ($retryCount -gt $MaxRetries) )

		if( !($retryCount -gt $maxRetries) ) {
			Write-Host -fore Green "Completed export of vPod $vPodName at $(Get-Date)"
			#Clean the OVF per HOL specifications
			$vPodPath = Join-Path $LibPath $VPodName
			Set-CleanOvf -LibraryPath $vPodPath

			#If subject to the ovftool redundant path bug, fix it
			$vPodDupPath = Join-Path $vPodPath $VPodName
			if( Test-Path $vPodDupPath ) {
				Get-ChildItem $vPodDupPath | Move-Item -Destination $vPodPath
				Remove-Item $vPodDupPath
			}
			if( $vappNetIsSet ) { 
				Write-Host "Creating metadata flag file: $wireFilePath"
				New-Item -Path $wireFilePath -Type File 
			}
		} else {
			Write-Host -fore Red "FAILED export of vPod $vPodName at $(Get-Date)"
		}
	 }
} #Export-VPod


Function Import-VcdMedia {
<#
	Takes an ISO Name, Catalog, "cloud key", and a path to the local Media Library
	Imports the ISO( or OVA) located at <library>\ISONAME.<TYPE>
	Will attempt to resume until successful completion (or 20x)
#>
	PARAM (
		$Key = $(throw "need -Key"),
		$Catalog = "",
		$MediaName = $(throw "need -MediaName"), 
		$MediaType = 'iso',
		$LibPath = $(throw "need -LibPath"),
		$User = $DEFAULT_CLOUDUSER,
		$Password = $DEFAULT_CLOUDPASSWORD,
		$OvDC = "",
		$Options = ""
	)
	PROCESS {

		$mediaPath = Join-Path $LibPath $($MediaName + "." + $MediaType)

		#test path, bail if not found
		if( !(Test-Path $mediaPath) ) {
			Write-Host -fore Red "!!! $mediaType file not found: $mediaPath"
			Return
		}
		
		$maxRetries = 20
		$retryCount = 0
		
		$vp = $MediaName
		$k = $Key
		$un = $User

		if( $Password -eq "" ) {
			$pw = 'xx'
		} else { 
			$pw = $Password
		}

		if( $MediaType.ToLower() -match 'ov[a,f]' ) {
			$type = 'vappTemplate'
		} else {
			$type = 'media'
		}
		
		if( $Catalog -eq "" ) {
			Write-Host "	Importing to default catalog: $($catalogs[$k])"
			$cat = $catalogs[$k]
		} else {
			$cat = $Catalog
		}

		$src = $mediaPath
	
		#allow override of OrgVDC via command line. Default based on $key
		if( $OvDC -eq "" ) { 
			$OvDC = $ovdcs[$k] 
		}
	
		$tgt = "vcloud://$un" + ':' + $pw + '@' + $vcds[$k] + ':443/?org=' + $orgs[$k] + '&vdc=' + $OvDC + "&catalog=$cat&$type=$vp"

		Write-Host -fore Yellow "DEBUG: Target is: catalog: $cat in $($vcds[$k]) org: $($orgs[$k]) ovdc: $($ovdcs[$k])"

		#Options ( additional options to OVFtool like '--overwrite')
		$opt = $Options

		Write-Host -fore Yellow "DEBUG: Importing from $src with options: $opt"

		Write-Host -fore Green "Beginning import of media $MediaName at $(Get-Date)"

		### put in a loop to ensure it is restarted if it times out. 
		Do {
			$retryCount += 1
			Write-Host "	Running ovftool (try $retryCount of $maxRetries) for $vp with options: $opt"
			ovftool $opt $src $tgt
			Sleep -sec 60
		} Until ( ($lastexitcode -eq 0) -or ($retryCount -gt $maxRetries) )
		
		if( !($retryCount -gt $maxRetries) ) {
			Write-Host -fore Green "Completed import of media $MediaName at $(Get-Date)"
		} else {
			Write-Host -fore Red "FAILED import of media $MediaName at $(Get-Date)"
		} 
	}
} #Import-VcdMedia


Function Test-CIVAppTemplateCustomization {
<#
	### HOL-specific use case ###
	Limited use function for reporting purposes.
	Checks the 'CustomizeOnInstantiate' flag on a checked-in vAppTemplate or catalog full of templates
	Assumes login to ONLY one cloud
#>
	PARAM(
		$Template="",
		$Catalog="",
		[Switch]$ShowOnlyBad
	)
	PROCESS {
		if( $Catalog -eq "" ) {
			$vp = $Template
		} else {
			$vp = Get-CIVappTemplate -catalog $Catalog
		}

		foreach( $vpod in $vp ) { 
			if( $vpod.CustomizeOnInstantiate ) {
				Write-Host -Fore Red "$($vpod.name) is BAD"
			} else {
				if ( !($ShowOnlyBad) ) { 
					Write-Host "$($vpod.name) is GOOD"
				}
			}
		}
	}
} #Test-CIVAppTemplateCustomization


Function Add-InternetMetadata {
<#
	### HOL-specific use case ###
	Add metadata to vApp template that VLP/NEE uses to attach it to the external network (Internet)
	Update 11/2014 to handle varying vApp network names
	Update 07/2015 to handle different orgvdc patterns: grabs first one matching *UT*
		Also handle special case for vCloud Air external network naming
	Update 08/2015 to allow specification of catalog name 
#>
	PARAM (
		$VPodName = $(throw "need -vPodName"),
		$CatalogName = $DEFAULT_TARGETCLOUDCATALOG
	)
	PROCESS {
		$vp = Get-CIVAppTemplate $VPodName -Catalog $CatalogName
		$networkConfig = ($vp.ExtensionData.Section | where {$_.NetworkConfig -ne $null}).NetworkConfig 
		$vAppNetName = ($networkConfig | where { $_.NetworkName -like "vAppNet*"}).NetworkName
		if( $vAppNetName -ne $null ) {
			New-CIMetaData -CIObject $vp -Key 'vappNetwork1' -Value $vAppNetName
			#grab the first user OrgVdc
			$nn = (get-orgvdc *ut*)[0].ExtensionData.AvailableNetworks.Network.name
			if( $nn -like 'VMware-HOL*' ) {
				#this is vCloud Air "p11vX"
				$netName = "VMware-HOL"
			} Else {
				$netName = $($nn.substring(0,$nn.length -1))
			}
			#assign the NEE "name pattern" to the network, less one digit (the last one)
			New-CIMetaData -CIObject $vp -Key 'orgVdcNetwork1' -Value $netName
		}
		Else {
			Write-Host -Fore Red "Unable to find vapp transit network matching 'vAppNet*'"
		}
	}
} #Add-InternetMetadata


Function Get-VmdkHashes {
<#
	Create a list of SHA1 hashes for the VMDKs at a given path
	Write the list to vpodName-<SITENAME>.hash at the root of the VPODPATH
	...And compare against values in Manifest (victim of scope creep)
	HashAlgorithm defaults to SHA1, which is used by ovftool in the Manifest file
	Requires Powershell 4.0 or higher
#>
	PARAM(
		$VpodPath = $(throw "need -VPodPath"),
		$SiteName = 'LOCAL',
		$HashAlgorithm = 'SHA1' #one of the supported types: MD5, SHA1, SHA256, SHA384, SHA512
	)
	PROCESS {
		Write-Host -Fore Green "$(Get-Date) Started creating hashes for $VpodPath"
		$vpodName = Split-Path $VpodPath -Leaf
		$manifestFile = Join-Path $VpodPath "$vpodName.mf"

		# See if the checksum file already exists. create new if it's already there.
		$outputFile = Join-Path $VpodPath "$vpodName-$SiteName.hash"
		if( -Not (Test-Path $outputFile) ) {
			#create the file so we don't try to calculate twice
			New-Item -Path $outputFile -Type File | Out-Null
			$vmdkHashes = @()
			foreach ( $vmdk in (Get-ChildItem $VpodPath -Exclude '*.hash') ) {
				$vmdkHash = "" | Select FileName,Hash
				$vmdkHash.FileName = $vmdk.Name
				Write-Host "...creating hash for $($vmdk.Name)"
				$vmdkHash.Hash = (Get-FileHash -Path $vmdk.FullName -Algorithm $HashAlgorithm).Hash.ToLower()
				$vmdkHashes += $vmdkHash
			}
			$vmdkHashes | Export-Csv -NoTypeInformation $outputFile -Force
			Write-Host -Fore Green "$(Get-Date) Finished creating hashes in $outputFile"
		} else {
			Write-Host -Fore Green "$(Get-Date) Loading hashes from existing $outputFile"
		}
		$vmdkHashes = @{}
		Import-CSV $outputFile | % { $vmdkHashes.Add($_.FileName,$_.Hash) }

		#Read the Manifest file into a hashtable: keys are filenames, values are SHA1 hashes
		if( Test-Path $manifestFile ) {
			$manifestHashes = @{}
			$regex = '\bSHA1\(([A-Z0-9\-\.a-z]+)\)=\ ([a-f0-9]+)\b'
			Write-Host -Fore Green "$(Get-Date) Loading hashes from Manifest $manifestFile"
			$count = 0
			Select-String -Path $manifestFile -Pattern $regex -AllMatches | % { $_.Matches } | % { $_.Groups } | % {
				$val = $_.Value
				switch ($count % 3) {
					0  { $count +=1 ; break }
					1  { $vmdkName = $val ; $count +=1 ; break }
					2  { $manifestHashes.Add($vmdkName,$val) ; $count +=1 ; break }
				}
			}
		}

		#compare manifest hashes to the ones we generated - Manifest is the authority
		$good = $true
		foreach( $FileName in ($vmdkHashes.Keys) ) {
			if( ($manifestHashes.ContainsKey($FileName)) -And ( -Not( $manifestHashes[$FileName] -eq $vmdkHashes[$FileName] ) ) ){
				Write-Host -Fore Red "...$FileName - hashes DO NOT match"
				$good = $false
			}
			$manifestHashes.Remove($FileName)
		}

		#Report 'extra' files in Manifest that don't show up in generated file
		if( $manifestHashes.Length -ne 0 ) {
			foreach( $FileName in ($manifestHashes.Keys) ) {
				Write-Host -Fore Red "...$FileName - SOURCE FILE MISSING"
				$good = $false
			}
		}

		if( -Not ($good) ) {
			Write-Host -Fore Red "$(Get-Date) Checksums for $VpodPath DO NOT match Manifest"
		} else {
			Write-Host -Fore Green "$(Get-Date) Checksums for $VpodPath match Manifest"
		}
		return $good
	}
} #Get-VmdkHashes


Function Get-CloudInfoFromKey {
<#
	Lookup module internal Cloud Info (host, org, catalog) when passed a cloudKey
	Returns an array containing the three values, in that order.
#>
	PARAM(
		$Key = $(throw "need -Key to lookup")
	)
	PROCESS {
		if( $vcds.ContainsKey($Key) ) {
			Return ($($vcds[$Key]),$($orgs[$Key]),$($catalogs[$Key]))
		} else {
			Return
		}
	}
} #Get-CloudInfoFromKey


Function Test-OvfDisk {
<#
	Pass an OVF and it will report on the OVF rounding issue (KB 2094271)

.EXAMPLE
	Test-OvfDisk -OVF 'E:\HOL-Library\MyPod\MyPod.ovf'
.EXAMPLE
	Test-OvfDisk -OVF 'E:\HOL-Library\MyPod\MyPod.ovf' -DebugMe
.EXAMPLE
	Get-ChildItem E:\HOL-Library -Recurse -Filter '*.ovf' | Test-OvfDisk

#>
	PARAM(
		[Parameter(Position=0,Mandatory=$true,HelpMessage="Path to the OVF",
		ValueFromPipeline=$true)]
		$OVF,
		[Switch]$DebugMe
	)
	PROCESS {
		if( $OVF.GetType().ToString() -eq "System.IO.FileInfo" ) { $OVF = $OVF.FullName }
		Write-Host -fore Green "BEGIN: Checking $ovf"

		[xml]$xmlOvf = Get-Content $OVF
		$newDiskReferences = $xmlOvf.Envelope.References.File
		$DisksAllocatedInMb = $xmlOvf.Envelope.DiskSection.Disk | where { $_.capacityAllocationUnits -eq 'byte * 2^20'}

		$vmdkSizes = @{}
		foreach( $disk in $newDiskReferences ) {
			$diskID = ($disk.ID).Remove(0,5)
			$vmdkSizes.Add($diskID,$disk.size)
		}

		$disksToResize = @{}
		foreach( $disk in $DisksAllocatedInMb ) {
			$diskID = ($disk.fileRef).Remove(0,5)
			$diskRequiredSize = $disk.populatedSize
			$diskCapacity = [int]($disk.capacity)
			$diskSpecifiedSize = $diskCapacity * 1MB
			$diskFileSize = $($vmdkSizes[$diskID])
			
			#the issue is that the FileSize > SpecifiedSize
			$diskSizeDifference = $diskSpecifiedSize - $diskFileSize
			
			
			if( $diskSizeDifference -lt 0 ) {
				if( $DebugMe ) {
					Write-Host -fore Green "BEFORE"
					Write-Host -Fore Yellow "`tSPECIFIED:  $diskSpecifiedSize"
					Write-Host -Fore Yellow "`tPOPULATED:  $diskRequiredSize"
					Write-Host -Fore Yellow "`tREFERENCE:  $diskFileSize"
					Write-Host -Fore Yellow "`tDIFFERENCE: $diskSizeDifference"
				}

				$increaseMB = [math]::Ceiling($(-$diskSizeDifference / 1MB))
				Write-Output ("  Disk {0} is {1:N0} bytes too small.`n`tIncrease from {2:N0} to {3:N0} MB" -f $diskId, $(-$diskSizeDifference), $diskCapacity, ($diskCapacity + $increaseMB) )
				$disksToResize.Add($diskID, $diskSpecifiedSize + $increaseMB * 1MB)
				$diskCapacity += $increaseMB

				if( $DebugMe ) {
					Write-Host -fore Green "AFTER"
					Write-Host -Fore Yellow "`tSPECIFIED:  $($diskCapacity * 1MB)"
					Write-Host -Fore Yellow "`tPOPULATED:  $diskRequiredSize"
					Write-Host -Fore Yellow "`tREFERENCE:  $diskFileSize"
					Write-Host -Fore Yellow "`tDIFFERENCE: $($diskCapacity * 1MB - $diskFileSize)"
				}
			}
		}
		Write-Host -fore Green "END: Checking $ovf"
	}
} #Test-OvfDisk


Function Show-VpodVersions {
<#
	Query Clouds and return presence + version(s) of each one matching VpodFilter
	Assumes $LibPath is authoritative regarding which SKUs should be reported.

	*** Must be authenticated to all $Clouds prior to running this function
#>
	PARAM (
		$Clouds = $(throw "need -Clouds (array of cloudKeys to search)"),
		$Catalog = $DEFAULT_TARGETCLOUDCATALOG,
		$LibPath = $DEFAULT_LOCALLIB,
		$VpodFilter = '*'
	)
	BEGIN {
		#Setup variables to collect the data
		$report = @{}
		$cloudHash = @{}
		$currentVersions = @{}
		$Clouds | % { $cloudHash.Add($_,"") }

		if( Test-Path $LibPath ) {
			(Get-ChildItem $LibPath) | % { 
				$vAppName = $_.Name
				$vAppSKU = $vAppName.Substring(0,$vAppName.LastIndexOf('-'))
				$vAppVersion = $vAppName.Replace("$vAppSKU-",'')
				$currentVersions.Add($vAppSKU,$vAppVersion)
				$report.Add($vAppSKU,$cloudHash.Clone()) 
			}
		} Else {
			Write-Host -Foreground Red "ERROR: Unable to continue. Path $LibPath does not exist"
			Return
		}
	}
	PROCESS {
		foreach( $cloud in $Clouds ) {
			$cloudName = (Get-CloudInfoFromKey -Key $cloud)[0]
			$orgName = (Get-CloudInfoFromKey -Key $cloud)[1]
			
			try {
				$catSrc = Get-Catalog $Catalog -Server $cloudName -Org $orgName  -ErrorAction 1
				foreach( $vApp in ( $catSrc.ExtensionData.CatalogItems.catalogItem ) ) {
					$vAppName = $vApp.Name
					if( $vAppName -like $VpodFilter ) {
						$vAppSKU = $vAppName.Substring(0,$vAppName.LastIndexOf('-'))
						$vAppVersion = $vAppName.Replace("$vAppSKU-",'')
						#Write-Host -Fore Yellow "DEBUG: $cloud $vAppSKU $vAppVersion"
						#Add the information only if the SKU exists in the hashtable
						if( ($vAppVersion -like 'v*') -and ($report.ContainsKey($vAppSKU)) ) {
							if( $vAppVersion -ne $currentVersions[$vAppSKU] ) {
								$vAppVersion += '*'
							}
							$report[$vAppSKU][$cloud] += "$vAppVersion "
						}
					} else {
						Write-Host -Fore Yellow "DEBUG: $cloud discarding $vAppName by filter"
					}
				}
			}
			catch {
				Write-Host -Fore Red "ERROR: $Catalog not found in $orgName of $cloudName"
			}
		}
		
		$out = @()
		foreach( $vpod in ( $report.keys | Sort-Object ) ) {
			$line = "" | select (@('SKU') + $Clouds)
			$line.SKU = $vpod
			foreach( $cloud in $Clouds ) {
				$line.($cloud) = $report[$vpod][$cloud]
			}
			$out += $line
		}
		#Note: Format-Table won't output more than 9 columns at a time
		$out | Sort-Object -Property "SKU" | Format-Table -AutoSize
	}
} #Show-VpodVersions


Function Test-PowerCLI {
<#
	WORK IN PROGRESS
	Check for VMware PowerCLI modules -- I care mostly about the Cloud module
#>
	if( (Get-Module | where { $_.name -like 'VMware.VimAutomation.Cloud' }).Count -gt 0 ) {
		Return $true
	} else { 
		Return $false 
	}
} #Test-PowerCLI


Function Import-PowerCLI {
<#
	WORK IN PROGRESS
	Import PowerCLI commands (v6.0+)
#>
	if ( !(Get-Module -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue) ) {
	. 'C:\Program Files (x86)\VMware\Infrastructure\vSphere PowerCLI\Scripts\Initialize-PowerCLIEnvironment.ps1'
	}
}

###########################################################################
### The following require SYSADMIN access and I think came from Clint Kitson @ EMC

Function Get-CIVMShadow {
<#
	Show all of the shadows deployed as well as their respective parents (vApp Templates, Catalogs)
#> 
	[array]$arrShadowVMs = Search-Cloud adminshadowvm 
	$hashCatalogs = @{}
	$hashVAppTemplates = @{}
	Search-Cloud AdminCatalog | %{ $hashCatalogs.($_.id) = $_ }
	Search-Cloud AdminVAppTemplate | %{ $hashVAppTemplates.($_.id) = $_ }
	$arrShadowVMs | %{
		$ShadowVM = $_
		$ShadowVM | select name,PrimaryVMName,@{n="PrimaryVAppTemplateName";e={$hashVAppTemplates.($ShadowVM.PrimaryVAppTemplate).name}},@{n="PrimaryVMCatalog";e={$hashCatalogs.($ShadowVM.PrimaryVMCatalog).name}},VcName,DatastoreName,IsDeleted
	}
} #Get-CIVMShadow


Function Set-CIVAppTemplateConsolidate { 
<# 
.EXAMPLE 
	PS C:\> Get-CIVAppTemplate Base-ePod-Basic-v8 -Catalog (Get-Org HOLDEV | Get-Catalog HOL_BASE_CAT01) | Set-CIVAppTemplateConsolidate
#> 
	PARAM (
		[Parameter(Mandatory=$True, Position=1, ValueFromPipeline=$true)]
		[PSObject[]]$InputObject
	) 
	PROCESS {
		$InputObject | %{ 
			$VApp = $_
			$vmCount = $VApp.ExtensionData.Children.vm.Count
			$count = 0
			$VApp.ExtensionData.Children.vm | %{ 
				$count += 1
				Write-Host "Working on VM $count of $vmCount"
				$_.Consolidate()
			}
		}
	}
} #Set-CIVAppTemplateConsolidate

Function Test-CloudCredential {

	Write-Host "Cloud Credential: $DEFAULT_CLOUDCREDENTIAL"
	Write-Host "Cloud User: $DEFAULT_CLOUDUSER"
	Write-Host "Cloud Password: $DEFAULT_CLOUDPASSWORD"

} #Test-CloudCredential


## Manage vCD Catalog vs. Local Export library

Function Sync-DirectoryToCatalog {
<#
	Sync a directory of exports (a "Library") to a vCD catalog.
	Assumes directory is authoritative source of vApp Templates.

	Requires being logged in to the (one) cloud in question.

#>
	PARAM(
		$Key = $cloudKey,
		$CatalogName = '',
		$LibraryPath = $DEFAULT_LOCALLIB,
		$UserName = $DEFAULT_CLOUDUSER,
		$Password = $DEFAULT_CLOUDPASSWORD
	)
	PROCESS {
		if( $LibraryPath -eq '' ) {
			Throw "Need -LibraryPath to identify source Library"
		}
		if( $Key -eq '' ) {
			Throw "Need -Key CLOUD or defined $cloudKey to identify the cloud"
		} else {
			($serverName, $orgName, $CatalogName) = Get-CloudInfoFromKey -Key $Key
			if( $CatalogName -eq '' ) {
				Throw "Need -CatalogName to identify target vCD Catalog name"
			}

			$podsToUpload = Compare-DirectoryToCatalog -ServerName $serverName -OrgName $orgName -CatalogName $CatalogName -LibraryPath $LibraryPath
		
		foreach( $pod in $podsToUpload ) {
			Write-Host "Uploading $pod from $LibraryPath to $CaatalogName"
			Import-VPod -Key $Key -CatalogName $CatalogName -VPodName $pod -LibPath $LibraryPath -User $UserName -Password $Password
		}
	}
} #Sync-DirectoryToCatalog