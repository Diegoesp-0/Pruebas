$path = "C:\ftp\LocalUser"
$acl = Get-Acl $path

$authUsers = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-11")
$authAccount = $authUsers.Translate([System.Security.Principal.NTAccount])

$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $authAccount,
    "ReadAndExecute",
    "ContainerInherit,ObjectInherit",
    "None",
    "Allow"
)

$acl.AddAccessRule($rule)
Set-Acl -Path $path -AclObject $acl

# Verificar
Get-Acl "C:\ftp\LocalUser" | Select -ExpandProperty Access | 
    Format-Table IdentityReference, FileSystemRights, AccessControlType
