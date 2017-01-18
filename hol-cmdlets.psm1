### 
### HOL Administration Cmdlets
### -Doug Baer
###
### 2017 January 18 - v1.7.0
###
### Import-Module .\hol-cmdlets.psd1
### Get-Command -module hol-cmdlets
###

########################################################################
###### LOAD GLOBAL PER-CLOUD DEFAULTS FROM CONFIG FILE
########################################################################
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
		$default_cred = New-Object System.Management.Automation.PsCredential $DEFAULT_CLOUDUSER , $(Get-Content $DEFAULT_CLOUDCREDENTIAL | ConvertTo-SecureString)
		$DEFAULT_CLOUDPASSWORD = ($default_cred.GetNetworkCredential()).Password
	}
	$creds = @{}
#	foreach( $cloud in $SettingsFile.Settings.Clouds.Cloud ) { $creds.Add($cloud.key,$occ) }
	foreach( $cloud in $SettingsFile.Settings.Clouds.Cloud ) { 
		if( !($cloud.credential) ) {
			#legacy location
			$CredentialPath = $DEFAULT_CLOUDCREDENTIAL
			$u = $DEFAULT_CLOUDUSER
			Write-Verbose "$($cloud.key) will use DEFAULT CREDENTIAL"
		} else {
			$CredentialPath = $cloud.credential
			$u = $cloud.username
			Write-Verbose "$($cloud.key) configured: $u @ $credentialPath"
		}
		if( Test-Path $CredentialPath ) {
			Write-Verbose "  Using credential from $CredentialPath"
			$p = Get-Content $CredentialPath | ConvertTo-SecureString
			$Credential = New-Object System.Management.Automation.PsCredential $u , $p
			$creds.Add($cloud.key, $Credential)
		} else {
			Write-Verbose "  WARNING: unable to find credential file $CredentialPath"
		}
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


###########################################################################
#### OVF: OVF testing and manipulation
###########################################################################

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


Function Set-CleanOvf {
<#
.SYNOPSIS
	* Look for blank but required ovf password parameters, set them to "VMware1!"
	* Look for and remove "stuck" NAT rules
	* Look for CustomizeOnInstantiate flag set and unset
	* Look for VMs with "POOL" addresses and change to "DHCP"
	
	* 2015 Update: generate and replace OVF's checksum in Manifest
	* Correct VMDK sizes specified in MB, but are smaller than data population
	
	* 2016 Update: correct sizes for "full" disks (>60%?) to prevent being tagged as EZT on import
	* Added configurable threshold and calculation of new disk size to match it

	* 2017 Updates (Jan): strip "nonpersistent disk" flag
	* Print current VM name to console when in Verbose mode
	* Changed encoding to UTF8 all around
	* Now uses Update-Manifest function

.EXAMPLE
	Set-CleanOvf -LibraryPath E:\HOL-Library -Threshold 65 -Verbose
	
#>
	[CmdletBinding()] 

	PARAM(
		#Path to vPod library. Will be read recursively for *.OVF files
		$LibraryPath = $(throw "need -LibraryPath"),
		$Threshold = 60
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
				$fullDisks = $false

				### Handle vCD/OVF "rounding error" - KB#2094271 - for $DisksAllocatedInMb
				[xml]$xmlOvf = Get-Content -Encoding "UTF8" $OVF
				$newDiskReferences = $xmlOvf.Envelope.References.File
				$DisksAllocatedInMb = $xmlOvf.Envelope.DiskSection.Disk | where { $_.capacityAllocationUnits -eq 'byte * 2^20'}
				$AllDisks = $xmlOvf.Envelope.DiskSection.Disk

				$vmdkSizes = @{}
				foreach( $disk in $newDiskReferences ) {
					$diskID = ($disk.ID).Remove(0,5)
					$vmdkSizes.Add($diskID,$disk.size)
				}

				$disksToResizeMb = @{}
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
						Write-Verbose ("`tDisk {0} is {1:N0} bytes too small.`n`tIncreasing from {2:N0} to {3:N0} MB" -f $diskId, $diskSizeDifference, $diskCapacity, ($diskCapacity + $increaseMB) )
						$disksToResizeMb.Add($diskID, $increaseMB )
						$diskCapacity += $increaseMB
					}
				}

				$disksToResize = @{}
				foreach( $disk in $AllDisks ) {
					$diskID = ($disk.fileRef).Remove(0,5)
					$diskPopulatedSize = $disk.populatedSize
					$diskCapacity = [int]($disk.capacity)

					if( $disk.capacityAllocationUnits -eq 'byte * 2^30' ) {
						$diskSpecifiedSize = $diskCapacity * 1GB
						$newSize = [math]::Ceiling($diskPopulatedSize / ($Threshold / 100) / 1GB )
						$newFullPercent = 100 * $diskPopulatedSize / ($newSize * 1GB)
					} else {
						$diskSpecifiedSize = $diskCapacity * 1MB
						$newSize = [math]::Ceiling($diskPopulatedSize / ($Threshold / 100) / 1MB )
						$newFullPercent = 100 * $diskPopulatedSize / ($newSize * 1MB)
					}

					#calculate the % Full
					$diskFullnessPercent = 100 * $diskPopulatedSize / $diskSpecifiedSize
					Write-Verbose ("  Disk {0} is {1:N0}% full." -f $diskId, $diskFullnessPercent )
					
					if( $diskFullnessPercent -ge $Threshold ) {
						Write-Verbose ("  Disk {0} is too small for thin: {1:N0}% full.`n`tIncreased from {2:N0} to {3:N0} ( {4:N0}% full)" -f $diskId, $diskFullnessPercent, $diskCapacity, $newSize, $newFullPercent )
						$disksToResize.Add($diskID, $newSize)
					}
				}


				(Get-Content -Encoding "UTF8" $ovf.fullName) | % { 
					$line = $_

					foreach( $disk in $disksToResizeMb.Keys ) {
						if( $line -match "vmdisk-$disk" ) {
							#handle the mis-allocated VMDK/vCD rounding issue
							if( $line -match '.*ovf:capacity="(\d+)".*' ) {
								$oldSize = $matches[1]
								$newSize = [int]$oldSize + $disksToResizeMb[$disk]
								$line = $line -replace $oldSize, $newSize 
								Write-Verbose "Replacing $oldSize with $newSize (small disk)"
								$smallDisks = $true
							}
							#not necessary since it falls through to the Else while $keep=true
							#$line
						}
					}

					foreach( $disk in $disksToResize.Keys ) {
						if( $line -match "vmdisk-$disk" ) {
							#handle the "automatic EZT" when full issue
							if( $line -match '.*ovf:capacity="(\d+)".*' ) {
								$oldSize = $matches[1]
								$newSize = $disksToResize[$disk]
								if( $newSize -gt [int]$oldSize ) {
									$oldStr = 'ovf:capacity="' + $oldSize + '"'
									$newStr = 'ovf:capacity="' + $newSize + '"'
									$line = $line -replace $oldStr, $newStr 
									Write-Verbose "Replacing $oldSize with $newSize (full disk)"
									$smallDisks = $true
								}
							}
							#not necessary since it falls through to the Else while $keep=true
							#$line
						}
					}

					#record the name of the current VM for use later			
					if( $line -match '<ovf:VirtualSystem ovf:id="(.*)">' ) {
						$currentVmName = $matches[1]
						Write-Verbose "`tworking on VM $currentVmName"
					}

					#handle the OVF password stripping that vCD performs
					if( $line -match 'ovf:password="true"' ) {
						$line = $line -replace 'value=""','value="VMware1!"' 
						$setPassword = $true
						Write-Verbose "`tsetting password on VM $currentVmName"
						$line
					}
					elseif( $line -match 'CustomizeOnInstantiate>true' ) {
						#handle the CustomizeOnInstantiate -- we don't want it!
						$line = $line -replace 'true','false' 
						$setCustomize = $true
						Write-Verbose "`tun-setting customize on VM $currentVmName"
						$line
					}
					elseif( $line -match 'vcloud:ipAddressingMode="POOL"' ) {
						#POOL ip addresses to DHCP
						$line = $line -replace '<rasd:Connection vcloud:ipAddress="[0-9.]+" vcloud:ipAddressingMode="POOL"' , '<rasd:Connection vcloud:ipAddressingMode="DHCP"'
						$setPool = $true
						Write-Verbose "`tsetting DHCP on VM $currentVmName"
						$line
					}
					elseif( $line -match 'vmw:key="backing.diskMode" vmw:value="independent_nonpersistent"' ) {
						# NEW for 2017 - remove non-persistent disk setting
						Write-Verbose "`tignoring nonpersistent disk on VM $currentVmName"
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
				} | Out-String | % { $_.Replace("`r`n","`n") } | Out-File -FilePath $ovf.fullname -encoding "UTF8"

				if( $setPassword ) {
					Write-Host "Set Password in file: $($ovf.name)"
				}
				if( $setPool ) {
					Write-Host -fore Yellow "Changed Pool to DHCP in file: $($ovf.name)"
				}
				if( $setCustomize ) {
					Write-Host -fore Red "Set CustomizeOnInstantiate in file: $($ovf.name)"
				}
				if( $removedNat ) {
					Write-Host "Removed NAT rules in file: $($ovf.name)"
				}
				if( $smallDisks ) {
					Write-Host -Fore Red "Fixed disk sizes in file: $($ovf.name)"
				}
				if( $fullDisks ) {
					Write-Host -Fore Yellow "Fixed disk sizes (for EZT) in file: $($ovf.name)"
				}
				#Regenerated the OVF, so need a new Hash
				Update-Manifest -Manifest $mf -ReplacementFile $ovf.FullName
			}
			Write-Host -fore Green "END: Cleaning $ovf"
		}
	}
} #Set-CleanOvf



Function Get-VmdkFromOvf {
<#
.SYNOPSIS
	Searches an OVF for the VMDK(s) associated with the $VmName
	By default, uses "vpodrouterHOL" as the $VmName
	
.RETURNVALUE
	Full path(s) to VMDK(s) associated with the VM matching VmName
	
	$undef if no VM with a matching name
#>
	[CmdletBinding()] 
	
	PARAM(
		$OVF = $(throw "need -OVF (path_to_OVF_file)"),
		$VmName = "vpodrouterHOL"
	)
	PROCESS {
		if( Test-Path $OVF ) {
			$templatePath = Split-Path (Get-Item -Path $OVF).FullName
			#Read the OVF as XML
			[xml]$new = Get-Content $OVF
			$newfiles = $new.Envelope.References.File
			$newvAppName = $new.Envelope.VirtualSystemCollection.Name 
	
			#Read the filenames to the OVF IDs in a hash table by diskID within the OVF
			Write-Verbose "Reading $newvAppName OVF"
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
		
			$diskList = @()
			#Parse the data
			Write-Verbose "Searching for $VmName"
			foreach($key in ($newDiskMap.Keys -match $VmName) ) {
				foreach( $key2 in ($newDiskMap[$key]).Keys ) { 
					$str2 = Join-Path $templatePath (($newDiskMap[$key])[$key2])
					if( $key -ne $curKey ) { 
						Write-Verbose "`tVM: $key"
						$curKey = $key
					}
					$diskList += $str2
				}
			}
			return $diskList | Sort
		}
		else {
			Write-Verbose "Error, $OVF not found"
			return
		}
	}
} #Get-VmdkFromOvf


Function Set-VPodRouterVmdk {
<#
.SYNOPSIS
	Replace the VPodRouter VMDK in an OVF with another
	Update the Manifest with the hash of the replacement VMDK
	Default manifest filename is same as OVF, but with .mf extension instead
	Default $ReplacementXX values are for a common replacement VMDK
	Default VmName is 'vpodrouterhol'

.NOTE
	This is low-level mucking with the VMDKs assigned to VMs within an OVF and may result
	in a well-formed but completely non-functional vApp. Use caution. 
#>
	[CmdletBinding()] 
	
	PARAM(
		$OVF = $(throw "need -Ovf"),
		$Manifest = ($OVF -replace '.ovf$','.mf'),
		$VmName = 'vpodrouterhol',
		$ReplacementVmdk = 'E:\Components\2016-vPodRouter-v6.1\2016-vPodRouter-v6.1-disk2.vmdk',
		$ReplacementVmdkHash = 'e7f0ea921455cd9ba5a161392c2c30355843eeac'
	)
	PROCESS {
		$vPodPath = Split-Path $OVF
		$vPodRouterVmdk = Get-VmdkFromOvf -OVF $OVF -VmName $VmName
		$vmNameNoSpaces = $VmName -Replace " ","-"
		if( $vPodRouterVmdk -ne $undef ) {
			Write-Verbose "replacing $vPodRouterVmdk"
			Write-Verbose "  with $ReplacementVmdk"
			try {
				$currentVmdk = Get-Item -Path $vPodRouterVmdk
				$currentVmdkFileName = $currentVmdk.Name
				$backupVmdkFileName = $currentVmdkFileName + "_" + $vmNameNoSpaces + "_BACKUP"
				Write-Verbose "Renaming existing file: $vPodRouterVmdk"
				Rename-Item -Path $vPodRouterVmdk -NewName $backupVmdkFileName -ErrorAction 1
			}
			catch {
				Write-Error "Rename failed for $vPodRouterVmdk to $backupVmdkFileName"
				return
			}
			try {
				#TODO: check for disk space before attempting copy?
				Write-Verbose "Copying replacement file"
				Copy-Item -LiteralPath $ReplacementVmdk -Destination $vPodRouterVmdk
				#update the manifest file with the new hash
			}
			catch {
				Write-Error "File copy failed for $ReplacementVmdk to $vPodRouterVmdk"
				return
			}
			
			Write-Verbose "Updating $Manifest"
			Update-Manifest -Manifest $Manifest -ReplacementFile $currentVmdk.FullName -ReplacementFileHash $ReplacementVmdkHash 

		}
		else {
			Write-Verbose "$VmName no found in $OVF. No replacement necessary."
		}
	}
} #Set-VPodRouterVmdk


Function Update-Manifest {
<#
.SYNOPSIS
	Makes a backup copy of the current Manifest file
	Updates the hash for $ReplacementFile in the Manifest
	Generates the hash of $ReplacementFile if none is provided as $ReplacementFileHash

.RETURNVALUE
	$true if successful
	$false if no changes or failure
#>
	[CmdletBinding()] 
	
	PARAM(
		$Manifest = $(throw "need -Manifest <full_path_to_file>"),
		$ReplacementFile = $(throw "need -ReplacementFile <full_path_to_file>"),
		$ReplacementFileHash = ''
	)
	PROCESS {
		$manifestExists = ( ($Manifest -match ".mf$") -and (Test-Path $Manifest) )
		$replacementFileExists = Test-Path $ReplacementFile

		#proceed if parameters are reasonably sane
		if( $manifestExists -and $replacementFileExists) {
			$mf = Get-Item -Path $Manifest
			$vmdk = Get-Item -Path $ReplacementFile
			$replacementFileName = Split-Path $ReplacementFile -Leaf
			
			if( $ReplacementFileHash -eq '' ) {
				Write-Verbose "Please stand by, generating hash for $ReplacementFile"
				$ReplacementFileHash = (Get-FileHash -Algorithm SHA1 -Path $vmdk.FullName).Hash.ToLower()
				Write-Verbose "Hash generated: $ReplacementFileHash"
			}
			
			$backupMF = $mf.FullName + '_BAK-MF'
			try { 
				Copy-Item -LiteralPath $mf -Destination $backupMF -Force
			}
			catch {
				Write-Error "Failed to create backup copy of Manifest $Manifest"
				return $false
			}
			
			(Get-Content $mf) | % { 
				$line = $_
				# looks like "SHA1(2016-vPodRouter-v6.1-disk1.vmdk)= e7f0ea921455cd9ba5a161392c2c30355843eeac"
				if( $line -match "SHA1\($replacementFileName\)\= ([0-9a-f]*)" ) {
					$line = $line -replace $matches[1],$ReplacementFileHash
				}
				$line
			} | Out-File -FilePath $mf -encoding "ASCII"
			return $true
		} 
		else {
			Write-Verbose "Manifest $Manifest does not exist. No changes written."
			return $false
		}
	}
} #Update-Manifest


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


###########################################################################
#### SHADOWS: Shadow Creation - management requires SYSADMIN
###########################################################################

Function Add-CIVAppShadows {
<#
	Takes a list of vAppTemplates and a list of OrgVDCs
	Provisions one copy of a vApp on each OrgVdc simultaneously (asynchronously)
	Named <vAppName>_shadow_<OrgvdcName>
	with 24 hour storage and Runtime leases so vCD cleans them up if you forget
	
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
		[Switch]$Cleanup,
		[Switch]$DebugMe
	)
	
	PROCESS {
		$leaseTime = New-Object System.Timespan 24,0,0

		foreach( $vApp in $vApps ) {
			#LEGACY - add Internet-Connect Metadata if Description matches pattern
			if( $vApp.Description -like "*~" ) {
				Write-Host -fore Green "** Adding vCD metadata for VLP to wire up **"
				Add-InternetMetadata -vpodName $vApp.Name -UserOrgVdcPattern $($OrgVDCs[0].Name)
			}

			#NEW - add Internet-Connect Metadata if truncated name exists in wiredUpVpods
			$foundV = ($vApp.Name).IndexOf('v')
			if( $foundV -ne -1 ) {
				$vAppShortName = ($vApp.Name).Substring(0,$foundV-1)
				if( $wiredUpVpods.ContainsKey($vAppShortName) ) {
					Write-Host -fore Green "** Adding vCD metadata for VLP to wire up **"
					Add-InternetMetadata -vpodName $vApp.Name -UserOrgVdcPattern $($OrgVDCs[0].Name)
				}
			}
			
			#create one shadow on each orgvdc
			Write-Host -fore Green "Beginning shadows for $($vApp.Name) at $(Get-Date)"
			foreach( $orgVDC in $OrgVDCs ) { 
				$shadowName = $($($vApp.Name) + "_shadow_" + $($orgVDC.Name))
				New-CIVApp -Name $shadowName -OrgVdc $orgVDC -VAppTemplate $vApp -RuntimeLease $leaseTime -StorageLease $leaseTime -RunAsync | Out-Null
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
			if( $Cleanup ) {
				Write-Host "Cleaning up shadows"
				$shadows = @{}
				foreach( $shadow in $(Get-CIVApp $shadowPattern) ) {
					if( $shadow.Status -ne "PoweredOff" ) {
						Write-Host -BackgroundColor Magenta -ForegroundColor Black "Bad Shadow:" $shadow.Name $shadow.Status
					}
					$shadowList += $shadow
				}
				Write-Host "Cleaned up shadows"
				$shadowList | Remove-CIVapp -Confirm:$false
			}
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


Function Add-ShadowBatch {
<#
	Shadow a batch of pods using the SKU alone (no need for version number.. get that from the folder name)
#>
	[CmdletBinding()]

	PARAM (
		[string]$KEY=$cloudKey, 
		[string]$SKU, 
		[string]$OVDCfilter='*ut*',
		[string]$LIBRARY
	)
	
	$ov = get-orgvdc $OVDCfilter 
	$filter = "HOL-$SKU" + '*'
	$vpod = Get-ChildItem $LIBRARY -Filter $filter
	if( $vpod.Count -gt 0 ) {
		$vpodName = $vpod[0].Name
		add-civappshadows -o $ov -v $(get-civapptemplate $vpodName)
	} else {
		Write-Host "$vpod matching $filter not found in $LIBRARY"
	}
} #Add-ShadowBatch


Function Remove-ShadowVapps {
<#
	In each provided cloud, remove the vApps with names matching the name pattern
#>
	[CmdletBinding()]

	PARAM (
		$Clouds = $(throw "need -Clouds (array of cloudKeys to search)"),
		$ShadowNamePattern = 'HOL-*_shadow_*',
		[switch]$ReportOnly,
		[switch]$LeaveBadOnes		
	)
	
	BEGIN {
		Write-Verbose "Checking for shadow vApps matching pattern: $ShadowNamePattern"
		
		Foreach( $cloud in $Clouds ) {
			Write-Verbose "Connecting to cloud: $cloud"
			$cloudConnecton = Connect-Cloud -k $cloud

			$shadowList = @()
			Write-Verbose "Getting shadow vApps"
			$shadowVapps = Get-civapp $ShadowNamePattern 
			Foreach( $shadowVapp in $shadowVapps ) {
				## IN PROGRESS -- DON'T KNOW IF THIS WORKS ##
				switch ($shadowVapp.Status) {

					"PoweredOff" { 
						# add to the "good list" so we can remove the good ones and leave the "bodies" behind for analysis
						Write-Verbose "`tAdding $($shadowVapp.Name) to the list"
						$shadowList += $shadowVapp
						break
					}

					"PoweredOn" {
						# oops. someone powered the shadow on. Can't delete it if it is PoweredOn
						Write-Host -ForegroundColor Black -BackgroundColor Yellow "Powered On Shadow:" $shadowVapp.Name $shadowVapp.Status
						break
						}
					
					default { 
						Write-Host -ForegroundColor Black -BackgroundColor Magenta "Bad Shadow:" $shadowVapp.Name $shadowVapp.Status
						break
					}
				}
			}

			# make with the removing
			if( !($ReportOnly) ) {
				Write-Verbose "`tRemoving shadow vApps"
				if( $LeaveBadOnes ) {
					Write-Verbose "`tLeaving the bodies behind"
					$shadowList | Remove-CIVapp -Confirm:$false
				} else {
					Write-Verbose "`tRemoving all matching vApps (but not PoweredOn)"
					$shadowVapps | Where { $_.Status -ne "PoweredOn" } | Remove-CIVapp -Confirm:$false 
				}
			}
			
			Write-Verbose "Disconnecting from cloud: $cloud ($($cloudConnecton.Name))"
			#WTH? the specific fails, saying the variable is NULL. It isn't.
			#Disconnect-CiServer -Server $cloudConnection -Force -Confirm:$false
			Disconnect-CiServer -Server * -Confirm:$false
		}
	}
} #Remove-ShadowVapps


###########################################################################
#### MEDIA: vCD Media object manipulation
###########################################################################

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
		$unboundMediaList = Get-Media | where {! $_.catalog}
		
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


Function Import-VcdMedia {
<#
	Takes an ISO Name, Catalog, "cloud key", and a path to the local Media Library
	Imports the ISO( or OVA) located at <library>\ISONAME.<TYPE>
	Will attempt to resume until successful completion (or 20x)
#>
	PARAM (
		$Key = $cloudKey,
		$Catalog = $(if( $catalogs.ContainsKey($Key) ){ $catalogs[$Key] } else{ "" } ),
		$MediaName = $(throw "need -MediaName"), 
		$MediaType = 'iso',
		$LibPath = $(throw "need -LibPath"),
		$User = $(if( $creds.ContainsKey($Key) ){ $creds[$Key].GetNetworkCredential().UserName } else{ $DEFAULT_CLOUDUSER } ),
		$Password = $(if( $creds.ContainsKey($Key) ){ $creds[$Key].GetNetworkCredential().Password } else{ $DEFAULT_CLOUDPASSWORD } ),
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

		Write-Host -fore Yellow "DEBUG: Target is: catalog: $cat in $($vcds[$k]) org: $($orgs[$k]) ovdc: $OvDC"

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


Function Export-VcdMedia {
<#
	Takes an ISO Name, Catalog, "cloud key", and a path to the local Media Library
	Imports the ISO( or OVA) located at <library>\ISONAME.<TYPE>
	Will attempt to resume until successful completion (or 20x)
#>
	PARAM (
		$Key = $cloudKey,
		$Catalog = $(if( $catalogs.ContainsKey($Key) ){ $catalogs[$Key] } else{ "" } ),
		$MediaName = $(throw "need -MediaName"), 
		$MediaType = 'iso',
		$LibPath = $(throw "need -LibPath"),
		$User = $(if( $creds.ContainsKey($Key) ){ $creds[$Key].GetNetworkCredential().UserName } else{ $DEFAULT_CLOUDUSER } ),
		$Password = $(if( $creds.ContainsKey($Key) ){ $creds[$Key].GetNetworkCredential().Password } else{ $DEFAULT_CLOUDPASSWORD } ),
		$OvDC = "",
		$Options = ""
	)
	PROCESS {

		$mediaPath = Join-Path $LibPath $($MediaName + "." + $MediaType)

		#test path, bail if found
		if( Test-Path $mediaPath ) {
			Write-Host -fore Red "!!! $mediaType file found: $mediaPath"
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
			Write-Host "	Exporting from default catalog: $($catalogs[$k])"
			$cat = $catalogs[$k]
		} else {
			$cat = $Catalog
		}

		$tgt = $mediaPath
	
		#allow override of OrgVDC via command line. Default based on $key
		if( $OvDC -eq "" ) { 
			$OvDC = $ovdcs[$k] 
		}
	
		$src = "vcloud://$un" + ':' + $pw + '@' + $vcds[$k] + ':443/?org=' + $orgs[$k] + '&vdc=' + $OvDC + "&catalog=$cat&$type=$vp.$mediaType"

		Write-Host -fore Yellow "DEBUG: Source is: catalog: $cat in $($vcds[$k]) org: $($orgs[$k]) ovdc: $OvDC"

		#Options ( additional options to OVFtool like '--overwrite')
		$opt = $Options

		Write-Host -fore Yellow "DEBUG: Exporting from $src with options: $opt"

		Write-Host -fore Green "Beginning export of media $MediaName at $(Get-Date)"

		### put in a loop to ensure it is restarted if it times out. 
		Do {
			$retryCount += 1
			Write-Host "	Running ovftool (try $retryCount of $maxRetries) to $tgt with options: $opt"
			ovftool $opt $src $tgt
			Sleep -sec 60
		} Until ( ($lastexitcode -eq 0) -or ($retryCount -gt $maxRetries) )
		
		if( !($retryCount -gt $maxRetries) ) {
			Write-Host -fore Green "Completed export of media $vp at $(Get-Date)"
		} else {
			Write-Host -fore Red "FAILED export of media $vp at $(Get-Date)"
		} 
	}
} #Export-VcdMedia


###########################################################################
#### METADATA: vCD Metadata management functions from Alan Renouf
###########################################################################

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


Function Add-InternetMetadata {
<#
	### HOL-specific use case ###
	Add metadata to vApp template that VLP/NEE uses to attach it to the external network (Internet)
	Update 11/2014 to handle varying vApp network names
	Update 07/2015 to handle different orgvdc patterns: grabs first one matching *UT*
		Also handle special case for vCloud Air external network naming
	Update 08/2015 to allow specification of catalog name 
	Update 07/2016 to allow specification of "user" orgvdc pattern (OC changed it!)

#>
	PARAM (
		$VPodName = $(throw "need -vPodName"),
		$UserOrgVdcPattern = '*ut*',
		$CatalogName = $DEFAULT_TARGETCLOUDCATALOG
	)
	PROCESS {
		$vp = Get-CIVAppTemplate $VPodName -Catalog $CatalogName
		$networkConfig = ($vp.ExtensionData.Section | where {$_.NetworkConfig -ne $null}).NetworkConfig 
		$vAppNetName = ($networkConfig | where { $_.NetworkName -like "vAppNet*"}).NetworkName
		if( $vAppNetName -ne $null ) {
			New-CIMetaData -CIObject $vp -Key 'vappNetwork1' -Value $vAppNetName
			#grab the first user OrgVdc
			$nn = (get-orgvdc -Name $UserOrgVdcPattern)[0].ExtensionData.AvailableNetworks.Network.name
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


###########################################################################
#### IMPORT/EXPORT: vApp Template I/O and replication
###########################################################################

Function Import-FinalVpod {
<#
	Upload 'final' versions of vPods, specifying "v1.0" as the version number
.EXAMPLE
	('1723','1725','1755','1756','1720') | % { Import-FinalVpod -KEY $cloudkey -LIBRARY E:\HOL-Library -SKU $_ }

.NOTE
	Run "Update-TemplateDescription" after phase2 import completes in order to reset description
	...doing all s one command requires waiting on the import to complete... TOO LONG!
#>
	[CmdletBinding()]

	PARAM (
		[string]$Key, 
		[string]$SKU, 
		[string]$Library,
		[string]$NewVersion = '1.0'
	)
	
	$filter = "HOL-$SKU" + '*'
	$versionString = "-v$NewVersion"
	$vpod = Get-ChildItem $Library -Filter $filter
	if( $vpod.Count -gt 0 ) {
		$vpodName = $vpod[0].Name
		$newName = $vpodName -replace '-(v.*)$',$versionString
		Import-Vpod -k $KEY -l $Library -v $vpodName -alt $newName
	} else {
		Write-Host "vPod matching $filter not found in $Library"
	}
} #Import-FinalVpod


Function Import-Vpod {
<#
	Takes a vPod Name, Catalog, "cloud key", and a path to the vPod Library
	Imports the OVF located at <library>\vPodName\vPodName.ovf
	Will attempt to resume until successful completion (or 5x) -- Imports should NOT be failing
	Written for OVFTOOL 3.x ... works with 4.1.0
#>
	PARAM (
		$Key = $cloudKey,
		$Catalog = $(if( $catalogs.ContainsKey($Key) ){ $catalogs[$Key] } else{ $DEFAULT_TARGETCLOUDCATALOG } ),
		$VPodName = $(throw "need -VPodName"), 
		$LibPath = $DEFAULT_LOCALLIB,
		$User = $(if( $creds.ContainsKey($Key) ){ $creds[$Key].GetNetworkCredential().UserName } else{ $DEFAULT_CLOUDUSER } ),
		$Password = $(if( $creds.ContainsKey($Key) ){ $creds[$Key].GetNetworkCredential().Password } else{ $DEFAULT_CLOUDPASSWORD } ),
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


Function Export-Vpod {
<#
   Takes a vPod Name, Catalog, "cloud key", and a path to the vPod Library
   Exports the vPod to an OVF located at <library>\vPodName\vPodName.ovf
   Will attempt to resume until successful completion (or 20x)
   ALWAYS uses '--exportFlags=preserveIdentity' flag to ovftool for HOL

#>
	PARAM (
		$Key = $cloudKey,
		$Catalog = $(if( $catalogs.ContainsKey($Key) ){ $catalogs[$Key] } else{ $DEFAULT_SOURCECLOUDCATALOG } ),
		$VPodName = $(throw "need -VPodName"), 
		$LibPath = $DEFAULT_LOCALLIB,
		$User = $(if( $creds.ContainsKey($Key) ){ $creds[$Key].GetNetworkCredential().UserName } else{ $DEFAULT_CLOUDUSER } ),
		$Password = $(if( $creds.ContainsKey($Key) ){ $creds[$Key].GetNetworkCredential().Password } else{ $DEFAULT_CLOUDPASSWORD } ),
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
			## GO GET IT VIA RSYNC OVER SSH
			$ovfFileRemoteEsc = doubleEscapePathSpaces $($RemoteLib + $NewName + "/" + $NewName + ".ovf")
			$newOvfPathC = cygwinPath $newOvfPath
#			$command = "C:\cygwin64\bin\bash.exe --login -c 'scp "+ $sshOptions + $SSHuser + "@" + $sshComputer + ':"' + $ovfFileRemoteEsc + '" "' + $newOvfPathC +'"' +"'"
## NEW COMMAND
			$rsyncOpts = '-tvhPrI --no-perms --chmod=ugo=rwX'
			$syncCmd = "rsync $rsyncOpts " + $SSHuser + "@" + $sshComputer + ':"' + $ovfFileRemoteEsc + '" "' + $newOvfPathC + '"'
			$command = "C:\cygwin64\bin\bash.exe --login -c " + "'" + $syncCmd + "'"
## NEW COMMAND
	
			if( $debug ) { Write-Host $command }
			if( $createFile ) { $command | Out-File $fileName -append } 
	
			Write-Host "Getting new OVF via SSH..."
			Invoke-Expression -command $command 
		}
	
		## second check -- see if we successfully downloaded it
		if( -not (Test-Path $newOvfPath) ) {
			Write-Host -Fore Red "Error: Unable to find new OVF @ $newOvfPath"
			CleanupAndExit
		}
	 
		#here, we have a copy of the new OVF in the new location
		#need to trap here in case file permissions prevent us from reading it
		try {
			[xml]$new = Get-Content $newOvfPath -ErrorAction 1
		}
		catch {
			Write-Host -Fore Red "Error: Unable to read new OVF @ $newOvfPath [permissions?]"
			CleanupAndExit
		}
		
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
			# updated 2015-Nov-18 to reset the file permissions to target defaults
			$rsyncOpts = '-tvhPrI --stats --delete --max-delete=6  --no-perms --chmod=ugo=rwX' 
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
		
		$syncCmd = "rsync $rsyncOpts " + $SSHuser + "@" + $sshComputer + ':"' + $remotePathRsyncEsc + '/" "' + $targetPathRsyncEsc + '"'
	
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


###########################################################################
#### REPORTING: Report status
###########################################################################

Function Get-CIVAppTemplateStatus {
<#
	Walk through the templates in CATALOG of each cloud, looking for those that are not "Resolved"
	Report on incomplete and "FailedCreation"
	Option to delete the FailedCreation ones... may work. (Remove-CivAppTemplate is problematic)

.EXAMPLE
	Get-CIVAppTemplateStatus -Clouds ('VW2','US21','IBM','NL01') -Catalog HOL-Masters -Verbose
.EXAMPLE
	Get-CIVAppTemplateStatus -Clouds ('VW2','US21','IBM','NL01') -Catalog HOL-Masters -RemoveBad
#>
	[CmdletBinding()]

	PARAM (
		$Clouds = $(throw "need -Clouds (array of cloudKeys to search)"),
		$Catalog = $DEFAULT_TARGETCLOUDCATALOG,
		$VpodFilter = 'HOL-*',
		[switch]$RemoveBad
	)
	
	BEGIN {
		Write-Verbose "Checking catalog $Catalog for templates matching pattern: $VpodFilter"
		
		Foreach( $cloud in $Clouds ) {
			Write-Verbose "Connecting to cloud: $cloud"
			$cloudConnecton = Connect-Cloud -k $cloud

			$badList = @()

			Write-Verbose "Getting catalog $Catalog"
			Get-Catalog $Catalog | Get-CIVappTemplate $VpodFilter | % {
				Write-Verbose "`tLooking at template $($_.Name) with status $($_.Status)"
				if( $_.Status -ne "Resolved" ) {
					Write-Host -Fore Black -BackgroundColor Magenta "Incomplete Template:" $_.Name $_.Status
				}
				if( $_.Status -eq "FailedCreation" ) {
					Write-Verbose "`tFound FAILED template $($_.Name).. going on the naughty list"
					$badList += $_
				}
			}
			
			if( $RemoveBad -and ($badList.Count -gt 0) ) {
				Write-Verbose "Removing failed templates:"
				Remove-CIvapptemplate -VappTemplate $badList -Confirm:$false
			} else {
				Write-Output "***Failed templates:"
				$badList
			}
			Write-Verbose "Disconnecting from cloud: $cloud ($($cloudConnecton.Name))"
			#WTH? the specific fails, saying the variable is NULL. It isn't.
			#Disconnect-CiServer -Server $cloudConnection -Force -Confirm:$false
			Disconnect-CiServer -Server * -Confirm:$false
		}
	}
} #Get-CIVAppTemplateStatus


Function Show-CloudPopulation {
<#
	Show the vapp template population of each cloud in the specified set
	Uses Show-VpodVersions
#>
	[CmdletBinding()]

	PARAM (
		$CloudSet = $(throw "need -CloudSet (one of HOL, VMWORLD, CATALOG)"),
		$CatalogName = 'HOL-Masters',
		$LibPath = 'E:\VMWORLD',
		$VpodFilter = 'HOL-*'
	)
	
	BEGIN {
		Write-Verbose "$(Get-Date) Beginning Show-CloudPopulation for $CLOUDSET"

		switch ($CloudSet)
		{
			'HOL' {
				Write-Host "Checking HOL clouds"
				$theClouds = ('HOL','VW3','SC2','US24')
				break
			} 
	
			'CATALOG' {
				Write-Host "Checking OneCloud Catalogs"
				$theClouds = ('CAT-US01','CAT-US01-4','CAT-US01-5','CAT-NL01')
				#bad form to hardcode this here, but it is a pain to type!
				$CatalogName = 'Global - HOL - VMworld 2016 Hands-on Labs'
				# old one: 'Global - HOL - VMworld 2016 Hands-on Labs'
				break
			} 
	
			'VMWORLD' {
				Write-Host "Checking VMworld Clouds"
				$theClouds = ('VW2','VW3','p11v2','p11v3','p11v4','p11v5','IBM','US21','NL01')
				break
			}
	
			default {
				Write-Host -ForegroundColor Red "Unrecognized cloud set. Use one of: HOL, CATALOG, VMWORLD"
				$theClouds = ''
				Return
				break
			}

		}

		if( $theClouds.count -gt 0 ) {

			if( $theClouds.count -gt 8 ) {
				#Powershell won't display more than 8 columns with Format-Table
				#FUTURE: split into multiple arrays and run multiple sets
				Write-Host -ForegroundColor Yellow "WARNING - Format-Table supports a maximim of 8 columns"
			}

			$theClouds | % { Connect-Cloud -k $_ }
			Show-VpodVersions -Clouds $theClouds -Catalog $CatalogName -LibPath $LibPath -VpodFilter $VpodFilter
			Disconnect-CiServer * -Confirm:$false
		}
	}
} #Show-CloudPopulation


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


Function Test-CloudCredential {
	Write-Host "== DEFAULTS =="
	Write-Host "Cloud Credential: $DEFAULT_CLOUDCREDENTIAL"
	Write-Host "Cloud User: $DEFAULT_CLOUDUSER"
#	Write-Host "Cloud Password: $DEFAULT_CLOUDPASSWORD"

	Write-Host "== CONFIGURED FOR $cloudKey =="
	Write-Host "Cloud User:" ($creds[$cloudKey]).userName
	
} #Test-CloudCredential


###########################################################################
#### CATALOG: Manage vCD Catalog vs. Local Export library
###########################################################################

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
			($serverName, $orgName, $defaultCatalogName) = Get-CloudInfoFromKey -Key $Key
			if( $CatalogName -eq '' ) {
				if( $defaultCatalogName -eq '' ) {
					Throw "Need -CatalogName to identify source vCD Catalog name"
				} else {
					$CatalogName = $defaultCatalogName
				}
			}
			$podsToUpload = Compare-DirectoryToCatalog -ServerName $serverName -OrgName $orgName -CatalogName $CatalogName -LibraryPath $LibraryPath
		
			foreach( $pod in $podsToUpload ) {
				Write-Host "Uploading $pod from $LibraryPath to $CatalogName"
				Import-VPod -Key $Key -Catalog $CatalogName -VPodName $pod -LibPath $LibraryPath -User $UserName -Password $Password
			}
		}
	}
} #Sync-DirectoryToCatalog


Function Sync-CatalogToDirectory {
<#
	Sync a vCD Catalog to a directory of exports (a "Library").
	Assumes catalog is authoritative source of vApp Templates.

	Requires being logged in to the (one) cloud in question .

#>
	PARAM(
		$Key = $cloudKey,
		$CatalogName = '',
		$LibraryPath = $DEFAULT_LOCALLIB,
		$UserName = $(if( $creds.ContainsKey($Key) ){ $creds[$Key].GetNetworkCredential().UserName } else{ $DEFAULT_CLOUDUSER } ),
		$Password = $(if( $creds.ContainsKey($Key) ){ $creds[$Key].GetNetworkCredential().Password } else{ $DEFAULT_CLOUDPASSWORD } )
	)
	PROCESS {
		if( $LibraryPath -eq '' ) {
			Throw "Need -LibraryPath to identify target Library"
		}

		try { 
			$lib = Get-Item $LibraryPath -ErrorAction "Stop"
			$libDrive = ($lib.Root.name).Substring(0,2)
		}
		catch {
			Write-Host -ForegroundColor Red "FAIL: $LibraryPath does not exist."
			Return
		}

		if( $Key -eq '' ) {
			Throw "Need -Key CLOUD or defined $cloudKey to identify the cloud"
		} else {
			($serverName, $orgName, $defaultCatalogName) = Get-CloudInfoFromKey -Key $Key
			if( $CatalogName -eq '' ) {
				if( $defaultCatalogName -eq '' ) {
					Throw "Need -CatalogName to identify source vCD Catalog name"
				} else {
					$CatalogName = $defaultCatalogName
				}
			}
			$podsToDownload = Compare-CatalogToDirectory -ServerName $serverName -OrgName $orgName -CatalogName $CatalogName -LibraryPath $LibraryPath
		
			foreach( $pod in $podsToDownload ) {
				Write-Host "Checking library capacity... "
				$volumeSpace = gwmi win32_logicaldisk | where { $_.DeviceID -like $libDrive } | select DeviceID, @{LABEL='GBfreespace';EXPRESSION={ ($_.freespace/1GB)} }

				if( $volumeSpace.GBfreespace -lt $DEFAULT_CATALOGFREESPACE ) {
					Write-Host -Foreground Red "WARNING: Library capacity below threshold: $DEFAULT_CATALOGFREESPACE GB, halting exports"
					Return
				}
				Write-Host "Exporting $pod from $CatalogName to $LibraryPath"
				Export-VPod -Key $Key -Catalog $CatalogName -VPodName $($pod.Name) -LibPath $LibraryPath -User $UserName -Password $Password
			}
		}
	}
} #Sync-CatalogToDirectory

###########################################################################
#### VPODS: manage vpods - vapp templates
###########################################################################

Function Remove-OldVpods {
<#
	Remove the vpods with names matching the provided list in each provided cloud

.EXAMPLE
	Remove-OldVpods -Clouds ('p11v2','p11v3','p11v4','p11v5') -Catalog 'HOL-Masters' -Vpods ('HOL-SDC-1602-v2.0','HOL-SDC-1610-v2.1')
#>
	[CmdletBinding()]

	PARAM (
		$Clouds = $(throw "need -Clouds (array of cloudKeys to search)"),
		$Catalog = $DEFAULT_TARGETCLOUDCATALOG,
		$Vpods = $(throw "need -OldVpods (array of names of templates to remove)"),
		[switch]$ReportOnly
	)
	
	BEGIN {
		Write-Verbose "Checking catalog $Catalog"
		
		Foreach( $cloud in $Clouds ) {
			Write-Verbose "Connecting to cloud: $cloud"
			$cloudConnecton = Connect-Cloud -k $cloud

			Write-Verbose "Getting catalog $Catalog"
			$vpodsInCatalog = Get-Catalog $Catalog | Get-CIVappTemplate 
			Foreach( $vPodName in $Vpods ) {
				Write-Verbose "`tLooking for vPod $vPodName"

				$oldVpod = $vpodsInCatalog | where { $_.Name -eq $vPodName }

				if( ($oldVpod.length -eq 1) -and ($oldVpod[0].Status -eq "Resolved") ) {
					if( !($ReportOnly) ) {
						Write-Verbose "`tRemoving old template $($oldvPod.Name)"
						Remove-CivAppTemplate -VappTemplate $oldVpod -Confirm:$false
					} else {
						Write-Host "`t(Report Only) Found old template $($oldvPod.Name)"
					}
				}
			}
			Write-Verbose "Disconnecting from cloud: $cloud ($($cloudConnecton.Name))"
			#WTH? the specific fails, saying the variable is NULL. It isn't.
			#Disconnect-CiServer -Server $cloudConnection -Force -Confirm:$false
			Disconnect-CiServer -Server * -Confirm:$false
		}
	}
} #Remove-OldVpods


Function Update-TemplateDescription {
<#
	Update the description of a 'v1.0' template to include the development version number in its Description
	
.EXAMPLE
	UpdateTemplateDescription -KEY CAT-US01 -LIBRARY E:\HOL-Library -CATALOG 'Global - HOL - VMworld 2016 Hands-on Labs' -Verbose -SKU '1701'

.EXAMPLE
	('1706','1708','1710','1720') | % { Update-TemplateDescription -KEY CAT-US01 -LIBRARY E:\HOL-Library -CATALOG 'Global - HOL - VMworld 2016 Hands-on Labs' -Verbose -SKU $_ }
#>
	[CmdletBinding()]

	PARAM (
		[string]$KEY, 
		[string]$SKU, 
		[string]$LIBRARY,
		[string]$CATALOG
	)
	
	$filter = "HOL-$SKU" + '*'
	$vpod = Get-ChildItem $LIBRARY -Filter $filter
	if( $vpod.Count -gt 0 ) {
		$vpodName = $vpod[0].Name
		$vpodVersion = $vpodName -replace '.*-(v.*)$','$1'
		$newName = $VPODNAME -replace '-(v.*)$','-v1.0'

		$vp = Get-Catalog $CATALOG | Get-civapptemplate $newName
		$vpv = Get-CIView $vp
		$newDescription = $vpv.Description
		Write-Verbose "CURRENT DESCRIPTION: $newDescription"
		$MaxDescriptionLength = 250 - $($vpodVersion.Length)

		if( $newDescription.Length -gt $MaxDescriptionLength ) {
			#truncate it if it would be too long with the version number added
			$newDescription = $newDescription[0..$MaxDescriptionLength] -Join ''
		}
		$newDescription += " $vpodVersion"

		$vpv.Description = $newDescription
		Write-Verbose "UPDATED DESCRIPTION: $newDescription"
		$vpv.UpdateServerData()
		
	} else {
		Write-Host "$vpod matching $filter not found in $LIBRARY"
	}
} #Update-TemplateDescription


###########################################################################
#### UTILITY: General utility functions
###########################################################################
Function SetHolPrompt {
<#
	Set the prompt to include the $cloudkey variable (used for per-session defaults)
#>
	Function global:Prompt { 
		foreach( $ciServer in $global:DefaultCiServers ) {
			if( $ciServer.org -eq "system" ) {
				Write-Host "SYSADMIN/$cloudKey " -nonewline -background Red -foreground Black
				Write-Host ((Get-Location).Path + ">") -NoNewLine
				return " "
			}
		}
		Write-Host "HOL/$cloudKey " -nonewline -foreground Green
		Write-Host ((Get-Location).Path + ">") -NoNewLine
		return " "
	}
} #SetHolPrompt


Function SetWindowTitle {
	PARAM (
		[String] $newTitle
	)
	PROCESS {
		if( $newTitle -eq "" ) {
			if( Test-PowerCLI ) { 
				$newTitle = "$cloudkey : $((Get-PowerCliVersion).UserFriendlyVersion)"
			} else {
				$newTitle = "$cloudkey : Windows Powershell $((Get-Host).Version)"
			}
		}
		
		$host.ui.RawUI.WindowTitle = $newTitle 
	}
} #SetWindowTitle


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


Function Get-CloudInfoFromKey {
<#
	Lookup/Test module internal Cloud Info (host, org, catalog) when passed a cloudKey
	Defaults to using defaultCloudkey for the session
	Returns an array containing the three values, in that order.
	TO DO: update this to return an object with named fields (or a hash)
		also include ovdc element
#>
	PARAM(
		$Key = $cloudKey
	)
	PROCESS {
		if( $vcds.ContainsKey($Key) ) {
			Write-Verbose "Looking up $cloudKey in CLOUDS list from XML config file."
			Return ($($vcds[$Key]),$($orgs[$Key]),$($catalogs[$Key]))
		} else {
			Write-Verbose "$cloudKey not found in CLOUDS list"
			Return
		}
	}
} #Get-CloudInfoFromKey


Function Get-Clouds {
<#
	Prints out a list of configured cloudkeys, hostnames, orgs, and default catalogs
#>
	PROCESS {
		Write-Output "== CloudKeys Configured =="
		$clouds = @()
		foreach( $ck in ($vcds.keys) ) { 
			$cloud = "" | select Key,Host,Org,Catalog,Credential
			$cloud.Key = $ck
			$cloud.Host = ($vcds[$ck]).Replace('.vmware.com','')
#			$cloud.Host = $vcds[$ck]
			$cloud.Org = $orgs[$ck]
			$cloud.Catalog = $catalogs[$ck]
			$cloud.Credential = ($creds[$ck]).UserName
			$clouds += $cloud
		}
		Write-Output $clouds | Sort -Property Key | Format-Table -Wrap
	}
} #Get-Clouds


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
} #Import-PowerCLI


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


##### testing
Function Test-MyParams {
	PARAM (
		$Key = $cloudKey,
		$User = $(if( $creds.ContainsKey($Key) ){ $creds[$Key].GetNetworkCredential().UserName } else{ $DEFAULT_CLOUDUSER } ),
		$Password = $(if( $creds.ContainsKey($Key) ){ $creds[$Key].GetNetworkCredential().Password } else{ $DEFAULT_CLOUDPASSWORD } )
	)
	PROCESS {
		Write-Host "checking parameter function for $KEY"
		Write-Host "User: $User"
		Write-Host "Password: $Password"
		if($creds.ContainsKey[$Key]){ 
			Write-Host "decoding password"
			Write-Host $(($creds[$Key].GetNetworkCredential()).User) 
		} else{
			Write-Host "Default: $DEFAULT_CLOUDUSER"
		}
		return
	}
}