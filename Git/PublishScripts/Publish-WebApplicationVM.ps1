#Requires -Version 3.0

<#
.SYNOPSIS
为 Visual Studio Web 项目创建和部署 Microsoft Azure 虚拟机。
有关更详细的文档，请转到: http://go.microsoft.com/fwlink/?LinkID=394472 

.EXAMPLE
PS C:\> .\Publish-WebApplicationVM.ps1 `
-Configuration .\Configurations\WebApplication1-VM-dev.json `
-WebDeployPackage ..\WebApplication1\WebApplication1.zip `
-VMPassword @{Name = "admin"; Password = "password"} `
-AllowUntrusted `
-Verbose


#>
[CmdletBinding(HelpUri = 'http://go.microsoft.com/fwlink/?LinkID=391696')]
param
(
    [Parameter(Mandatory = $true)]
    [ValidateScript({Test-Path $_ -PathType Leaf})]
    [String]
    $Configuration,

    [Parameter(Mandatory = $false)]
    [String]
    $SubscriptionName,

    [Parameter(Mandatory = $false)]
    [ValidateScript({Test-Path $_ -PathType Leaf})]
    [String]
    $WebDeployPackage,

    [Parameter(Mandatory = $false)]
    [Switch]
    $AllowUntrusted,

    [Parameter(Mandatory = $false)]
    [ValidateScript( { $_.Contains('Name') -and $_.Contains('Password') } )]
    [Hashtable]
    $VMPassword,

    [Parameter(Mandatory = $false)]
    [ValidateScript({ !($_ | Where-Object { !$_.Contains('Name') -or !$_.Contains('Password')}) })]
    [Hashtable[]]
    $DatabaseServerPassword,

    [Parameter(Mandatory = $false)]
    [Switch]
    $SendHostMessagesToOutput = $false
)


function New-WebDeployPackage
{
    #编写一个函数以生成和打包 Web 应用程序

    #若要生成 Web 应用程序，请使用 MsBuild.exe。若要寻求帮助，请参见 MSBuild 命令行参考，网址如下: http://go.microsoft.com/fwlink/?LinkId=391339
}

function Test-WebApplication
{
    #编辑此函数以对你的 Web 应用程序运行单元测试

    #若要编写一个函数以对 Web 应用程序运行单元测试，请使用 VSTest.Console.exe。若要寻求帮助，请参见 http://go.microsoft.com/fwlink/?LinkId=391340 上的 VSTest.Console 命令行参考
}

function New-AzureWebApplicationVMEnvironment
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [Object]
        $Configuration,

        [Parameter (Mandatory = $false)]
        [AllowNull()]
        [Hashtable]
        $VMPassword,

        [Parameter (Mandatory = $false)]
        [AllowNull()]
        [Hashtable[]]
        $DatabaseServerPassword
    )
   
    $VMInfo = New-AzureVMEnvironment `
        -CloudServiceConfiguration $Config.cloudService `
        -VMPassword $VMPassword

    # 创建 SQL 数据库。此连接字符串用于部署。
    $connectionString = New-Object -TypeName Hashtable
    
    if ($Config.Contains('databases'))
    {
        @($Config.databases) |
            Where-Object {$_.connectionStringName -ne ''} |
            Add-AzureSQLDatabases -DatabaseServerPassword $DatabaseServerPassword |
            ForEach-Object { $connectionString.Add($_.Name, $_.ConnectionString) }           
    }
    
    return @{ConnectionString = $connectionString; VMInfo = $VMInfo}   
}

function Publish-AzureWebApplicationToVM
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [Object]
        $Config,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Hashtable]
        $ConnectionString,

        [Parameter(Mandatory = $true)]
        [ValidateScript({Test-Path $_ -PathType Leaf})]
        [String]
        $WebDeployPackage,
        
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [Hashtable]
        $VMInfo           
    )
    $waitingTime = $VMWebDeployWaitTime

    $result = $null
    $attempts = 0
    $allAttempts = 60
    do 
    {
        $result = Publish-WebPackageToVM `
            -VMDnsName $VMInfo.VMUrl `
            -IisWebApplicationName $Config.webDeployParameters.IisWebApplicationName `
            -WebDeployPackage $WebDeployPackage `
            -UserName $VMInfo.UserName `
            -UserPassword $VMInfo.Password `
            -AllowUntrusted:$AllowUntrusted `
            -ConnectionString $ConnectionString
         
        if ($result)
        {
            Write-VerboseWithTime ($scriptName + ' 发布到 VM 成功。')
        }
        elseif ($VMInfo.IsNewCreatedVM -and !$Config.cloudService.virtualMachine.enableWebDeployExtension)
        {
            Write-VerboseWithTime ($scriptName + ' 你需要将“enableWebDeployExtension”设置为 $true。')
        }
        elseif (!$VMInfo.IsNewCreatedVM)
        {
            Write-VerboseWithTime ($scriptName + ' 现有 VM 不支持 Web Deploy。')
        }
        else
        {
            Write-VerboseWithTime ('{0}: Publishing to VM failed. Attempt {1} of {2}.' -f $scriptName, ($attempts + 1), $allAttempts)
            Write-VerboseWithTime ('{0}: Publishing to VM will start after {1} seconds.' -f $scriptName, $waitingTime)
            
            Start-Sleep -Seconds $waitingTime
        }
                                                                                                                       
         $attempts++
    
         #尝试再次仅为已安装 Web Deploy 的新建虚拟机进行发布。 
    } While( !$result -and $VMInfo.IsNewCreatedVM -and $attempts -lt $allAttempts -and $Config.cloudService.virtualMachine.enableWebDeployExtension)
    
    if (!$result)
    {                    
        Write-Warning ' 发布到虚拟机失败。这可能是不受信任或无效的证书导致的。你可指定 -AllowUntrusted 以接受不受信任的证书。'
        throw ($scriptName + ' 发布到 VM 失败。')
    }
}

# 脚本主例程
Set-StrictMode -Version 3
Import-Module Azure

try {
    $AzureToolsUserAgentString = New-Object -TypeName System.Net.Http.Headers.ProductInfoHeaderValue -ArgumentList 'VSAzureTools', '1.5'
    [Microsoft.Azure.Common.Authentication.AzureSession]::ClientFactory.UserAgents.Add($AzureToolsUserAgentString)
} catch {}

Remove-Module AzureVMPublishModule -ErrorAction SilentlyContinue
$scriptDirectory = Split-Path -Parent $PSCmdlet.MyInvocation.MyCommand.Definition
Import-Module ($scriptDirectory + '\AzureVMPublishModule.psm1') -Scope Local -Verbose:$false

New-Variable -Name VMWebDeployWaitTime -Value 30 -Option Constant -Scope Script 
New-Variable -Name AzureWebAppPublishOutput -Value @() -Scope Global -Force
New-Variable -Name SendHostMessagesToOutput -Value $SendHostMessagesToOutput -Scope Global -Force

try
{
    $originalErrorActionPreference = $Global:ErrorActionPreference
    $originalVerbosePreference = $Global:VerbosePreference
    
    if ($PSBoundParameters['Verbose'])
    {
        $Global:VerbosePreference = 'Continue'
    }
    
    $scriptName = $MyInvocation.MyCommand.Name + ':'
    
    Write-VerboseWithTime ($scriptName + ' 开始')
    
    $Global:ErrorActionPreference = 'Stop'
    Write-VerboseWithTime ('{0} $ErrorActionPreference 设置为 {1}' -f $scriptName, $ErrorActionPreference)
    
    Write-Debug ('{0}: $PSCmdlet.ParameterSetName = {1}' -f $scriptName, $PSCmdlet.ParameterSetName)

    # 验证你是否装有 Azure 模块 0.7.4 或更高版本。
	$validAzureModule = Test-AzureModule

    if (-not ($validAzureModule))
    {
         throw '无法加载 Azure PowerShell。若要安装最新版本，请访问 http://go.microsoft.com/fwlink/?LinkID=320552。如果你已安装 Azure PowerShell，则你可能需要重新启动计算机或手动导入该模块。'
    }

    # 保存当前订阅。它稍后将在脚本中还原为“当前”状态
    Backup-Subscription -UserSpecifiedSubscription $SubscriptionName
        
    if ($SubscriptionName)
    {

        # 如果你提供了订阅名称，请验证你的帐户中是否存在相应的订阅。
        if (!(Get-AzureSubscription -SubscriptionName $SubscriptionName))
        {
            throw ("{0}: 找不到订阅名称 $SubscriptionName" -f $scriptName)

        }

        # 将指定的订阅设为当前订阅。
        Select-AzureSubscription -SubscriptionName $SubscriptionName | Out-Null

        Write-VerboseWithTime ('{0}: 订阅设置为 {1}' -f $scriptName, $SubscriptionName)
    }

    $Config = Read-ConfigFile $Configuration -HasWebDeployPackage:([Bool]$WebDeployPackage)

    #生成并打包 Web 应用程序
    New-WebDeployPackage

    #对 Web 应用程序运行单元测试
    Test-WebApplication

    #创建 JSON 配置文件中描述的 Azure 环境

    $newEnvironmentResult = New-AzureWebApplicationVMEnvironment -Configuration $Config -DatabaseServerPassword $DatabaseServerPassword -VMPassword $VMPassword

    #如果用户指定了 $WebDeployPackage，则部署 Web 应用程序包 
    if($WebDeployPackage)
    {
        Publish-AzureWebApplicationToVM `
            -Config $Config `
            -ConnectionString $newEnvironmentResult.ConnectionString `
            -WebDeployPackage $WebDeployPackage `
            -VMInfo $newEnvironmentResult.VMInfo
    }
}
finally
{
    $Global:ErrorActionPreference = $originalErrorActionPreference
    $Global:VerbosePreference = $originalVerbosePreference

    # 将原来处于当前状态的订阅还原为“当前”状态
	if($validAzureModule)
	{
   	    Restore-Subscription
	}   

    Write-Output $Global:AzureWebAppPublishOutput    
    $Global:AzureWebAppPublishOutput = @()
}
