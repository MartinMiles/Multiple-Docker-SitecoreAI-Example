# Step 1: Convert each codebase to multi-docker mode FIRST (unique project names, hostnames, ports)
# This must run before init.ps1 because init.ps1 has $ErrorActionPreference = "Stop"
# and may halt before completion, preventing subsequent lines from executing.
.\Convert-ToMultiDocker.ps1 -CodebasePath .\codebase-1 -InstanceName one -MssqlPort 14331 -SolrPort 8984
.\Convert-ToMultiDocker.ps1 -CodebasePath .\codebase-2 -InstanceName two -MssqlPort 14332 -SolrPort 8985
.\Convert-ToMultiDocker.ps1 -CodebasePath .\codebase-3 -InstanceName three -MssqlPort 14333 -SolrPort 8986

# Step 2: Run Sitecore init (generates certs, hosts entries, secrets)
.\codebase-1\local-containers\scripts\init.ps1 -LicenseXmlPath C:\Projects\license.xml -AdminPassword b -baseOs ltsc2022
.\codebase-2\local-containers\scripts\init.ps1 -LicenseXmlPath C:\Projects\license.xml -AdminPassword b -baseOs ltsc2022
.\codebase-3\local-containers\scripts\init.ps1 -LicenseXmlPath C:\Projects\license.xml -AdminPassword b -baseOs ltsc2022