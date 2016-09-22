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


####
Function UpdateTemplateDescription {
<#
	Update the description of a 'v1.0' template to include the development version number in its Description
	
.EXAMPLE
	UpdateTemplateDescription -KEY CAT-US01 -LIBRARY E:\HOL-Library -CATALOG 'Global - HOL - VMworld 2016 Hands-on Labs' -Verbose -SKU '1701'

.EXAMPLE
	('1706','1708','1710','1720') | % { UpdateTemplateDescription -KEY CAT-US01 -LIBRARY E:\HOL-Library -CATALOG 'Global - HOL - VMworld 2016 Hands-on Labs' -Verbose -SKU $_ }
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
}


Function UploadFinalPod {
<#
	Upload 'final' versions of vPods, specifying "v1.0" as the version number
.EXAMPLE
	('1723','1725','1755','1756','1720') | % { UploadFinalPod -KEY $cloudkey -LIBRARY E:\HOL-Library -SKU $_ }

.NOTE
	Run "UpdateTemplateDescription" after phase2 upload completes in order to reset description
	(need to check -- can we do that as part of the import?)
#>
	[CmdletBinding()]

	PARAM (
		[string]$KEY, 
		[string]$SKU, 
		[string]$LIBRARY
	)
	
	$filter = "HOL-$SKU" + '*'
	$vpod = Get-ChildItem $LIBRARY -Filter $filter
	if( $vpod.Count -gt 0 ) {
		$vpodName = $vpod[0].Name
		$newName = $VPODNAME -replace '-(v.*)$','-v1.0'
		Import-vPod -k $KEY -l $LIBRARY -v $VPODNAME -alt $newName
	} else {
		Write-Host "$vpod matching $filter not found in $LIBRARY"
	}
}


Function ShadowBatch {
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
}
