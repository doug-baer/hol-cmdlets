# hol-cmdlets
Management and replication functions and daemons for VMware Hands-on Labs

This project contains the base "vPod" administration and replication processes 
that we use for copying vCD vApp templates between clouds in different geographic 
locations. It uses LFTP over SSH for bulk transport and rsync to handle error 
detection/correction and differential transport (for moving updated versions of 
the same template).

The replication environment requires Windows hosts with port 22 (ssh). 
The following software should be installed to support the environment:
	* VMware PowerCLI 6.0u1+ with vCloud extensions
	* VMware OVFtool 4.1.0
	* Cygwin with openssh, rsync, lftp

All replication traffic uses SFTP with preshared keys and OVFtool for imports.

Configuration is largely performed in the hol_cmdlets_settings.xml file.
This file should be populated prior to any attempt at using these functions.

A skeleton/example has been included in this project as hol_cmdlets_settings-EXAMPLE.xml

Error handling is still pretty rudimentarty and this is a work in progress. 
When in doubt, most of the functions will and bail out and wait for a smart 
person to fix the issue.

Reference
	* rsync - https://rsync.samba.org/
	* lftp - http://lftp.yar.ru/

Further documentation is in progress, although much of this code is only useful in an environment containing multiple VMware vCloud Director-based clouds.

NO WARRANTY IS EXPRESSED OR IMPLIED. This code is what it is and, while no attempt is made to remove vApp Templates from vCD, rsync can and will delete files if it is either misconfigured or passed incorrect parameters. This has not happend during our usage and testing, but that does not mean that it will not happen in another environment. 

-DB (26 October 2015)
