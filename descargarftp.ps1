Test-Path "C:\ftp\LocalUser\usuario1"
Get-ChildItem "C:\ftp\LocalUser\usuario1"
Get-Acl "C:\ftp\LocalUser\usuario1" | Select -ExpandProperty Access | Format-Table

Get-Acl "C:\ftp\LocalUser" | Select -ExpandProperty Access | Format-Table IdentityReference, FileSystemRights, AccessControlType
