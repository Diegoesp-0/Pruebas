# 1. Ver que existe en LocalUser
Get-ChildItem "C:\ftp\LocalUser" -ErrorAction SilentlyContinue

# 2. Ver permisos de LocalUser
Get-Acl "C:\ftp\LocalUser" | Select -ExpandProperty Access | 
    Format-Table IdentityReference, FileSystemRights, AccessControlType

# 3. Ver si existe la jaula del usuario diego
Test-Path "C:\ftp\LocalUser\diego"
Get-ChildItem "C:\ftp\LocalUser\diego" -ErrorAction SilentlyContinue

# 4. Ver permisos de la jaula
Get-Acl "C:\ftp\LocalUser\diego" | Select -ExpandProperty Access | 
    Format-Table IdentityReference, FileSystemRights, AccessControlType

# 5. Ver isolation mode actual
Import-Module WebAdministration
(Get-ItemProperty "IIS:\Sites\ServidorFTP" -Name "ftpServer.userIsolation.mode").Value
