# Get the path to the shared modules folder
$script:ModulesFolderPath = Join-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent)) `
                                      -ChildPath 'Modules'

# Import the Networking Resource Helper Module
Import-Module -Name (Join-Path -Path $script:ModulesFolderPath `
                               -ChildPath (Join-Path -Path 'NetworkingDsc.ResourceHelper' `
                                                     -ChildPath 'NetworkingDsc.ResourceHelper.psm1'))

# Import Localization Strings
$script:localizedData = Get-LocalizedData `
    -ResourceName 'MSFT_xNetBIOS' `
    -ResourcePath $PSScriptRoot

# Import the common networking functions
Import-Module -Name (Join-Path -Path $script:ModulesFolderPath `
                               -ChildPath (Join-Path -Path 'NetworkingDsc.Common' `
                                                     -ChildPath 'NetworkingDsc.Common.psm1'))

#region check NetBIOSSetting enum loaded, if not load
try
{
    [void][reflection.assembly]::GetAssembly([NetBIOSSetting])
}
catch
{
    Add-Type -TypeDefinition @'
    public enum NetBiosSetting
    {
       Default,
       Enable,
       Disable
    }
'@
}
#endregion

function Get-TargetResource
{
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param
    (
        [parameter(Mandatory = $true)]
        [System.String]
        $InterfaceAlias,

        [parameter(Mandatory = $true)]
        [ValidateSet("Default","Enable","Disable")]
        [System.String]
        $Setting
    )
    $Netadapterparams = @{
        ClassName = 'Win32_NetworkAdapter'
        Filter = 'NetConnectionID="{0}"' -f $InterfaceAlias
    }

    $NetAdapterConfig = Get-CimInstance @Netadapterparams -ErrorAction Stop |
            Get-CimAssociatedInstance `
                -ResultClassName Win32_NetworkAdapterConfiguration `
                -ErrorAction Stop

    return @{
        InterfaceAlias = $InterfaceAlias
        Setting = $([NETBIOSSetting].GetEnumValues()[$NetAdapterConfig.TcpipNetbiosOptions])
    }
}


function Set-TargetResource
{
    [CmdletBinding()]
    param
    (
        [parameter(Mandatory = $true)]
        [System.String]
        $InterfaceAlias,

        [parameter(Mandatory = $true)]
        [ValidateSet("Default","Enable","Disable")]
        [System.String]
        $Setting
    )
    $Netadapterparams = @{
        ClassName = 'Win32_NetworkAdapter'
        Filter = 'NetConnectionID="{0}"' -f $InterfaceAlias
    }
    $NetAdapterConfig = Get-CimInstance @Netadapterparams -ErrorAction Stop |
            Get-CimAssociatedInstance `
                -ResultClassName Win32_NetworkAdapterConfiguration `
                -ErrorAction Stop

    if ($Setting -eq [NETBIOSSetting]::Default)
    {
        Write-Verbose -Message $LocalizedData.ResetToDefaut
        #If DHCP is not enabled, settcpipnetbios CIM Method won't take 0 so overwrite registry entry instead.
        $RegParam = @{
            Path = "HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces\Tcpip_$($NetAdapterConfig.SettingID)"
            Name = 'NetbiosOptions'
            Value = 0
        }
        $null = Set-ItemProperty @RegParam
    }
    else
    {
        Write-Verbose -Message ($LocalizedData.SetNetBIOS -f $Setting)
        $null = $NetAdapterConfig |
            Invoke-CimMethod -MethodName SetTcpipNetbios -ErrorAction Stop -Arguments @{
                TcpipNetbiosOptions = [uint32][NETBIOSSetting]::$Setting.value__
            }
    }
}


function Test-TargetResource
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param
    (
        [parameter(Mandatory = $true)]
        [System.String]
        $InterfaceAlias,

        [parameter(Mandatory = $true)]
        [ValidateSet("Default","Enable","Disable")]
        [System.String]
        $Setting
    )
    $NIC = Get-CimInstance `
        -ClassName Win32_NetworkAdapter `
        -Filter "NetConnectionID=`"$InterfaceAlias`""
    if ($Null -ne $NIC)
    {
        Write-Verbose -Message ($LocalizedData.InterfaceDetected -f $InterfaceAlias,$NIC.InterfaceIndex)
    }
    else
    {
        $ErrorParam = @{
            ErrorId = 'NICNotFound'
            ErrorMessage = ($LocalizedData.NICNotFound -f $InterfaceAlias)
            ErrorCategory = 'ObjectNotFound'
            ErrorAction = 'Stop'
        }
        New-TerminatingError @ErrorParam
    }

    $NICConfig = $NIC | Get-CimAssociatedInstance -ResultClassName Win32_NetworkAdapterConfiguration

    Write-Verbose -Message ($LocalizedData.CurrentNetBiosSetting -f [NETBIOSSetting].GetEnumValues()[$NICConfig.TcpipNetbiosOptions])

    $DesiredSetting = ([NETBIOSSetting]::$($Setting)).value__
    Write-Verbose -Message ($LocalizedData.DesiredSetting -f $Setting)

    if ($NICConfig.TcpipNetbiosOptions -eq $DesiredSetting)
    {
        Write-Verbose -Message $LocalizedData.InDesiredState
        return $true
    }
    else
    {
        Write-Verbose -Message $LocalizedData.NotInDesiredState
        return $false
    }
}

#region helper functions
function New-TerminatingError
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [String] $ErrorId,

        [Parameter(Mandatory = $true)]
        [String] $ErrorMessage,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorCategory] $ErrorCategory
    )

    $exception = New-Object System.InvalidOperationException $errorMessage
    $errorRecord = New-Object System.Management.Automation.ErrorRecord $exception, $errorId, $errorCategory, $null
    throw $errorRecord
}
#endregion


Export-ModuleMember -Function *-TargetResource

