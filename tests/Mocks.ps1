# Données simulées : permettent d'exercer le rendu des outils Windows sur
# n'importe quelle plateforme (tests Pester, captures d'écran de la doc).
# Usage :  . tests/Mocks.ps1 ; & src/tools/monitor.ps1 -Once
$env:PSTOOLS_TEST_WINDOWS = '1'
if (-not $env:COMPUTERNAME) { $env:COMPUTERNAME = 'ATELIER-PC' }
if (-not $env:USERNAME) { $env:USERNAME = 'charles' }

function Get-CimInstance {
    param([Parameter(Position = 0)][string]$ClassName, [string]$Filter)
    switch ($ClassName) {
        'Win32_OperatingSystem' {
            [pscustomobject]@{ Caption = 'Microsoft Windows 11 Professionnel'; Version = '10.0.26100'; OSArchitecture = '64 bits'
                LastBootUpTime = (Get-Date).AddHours(-53).AddMinutes(-12); TotalVisibleMemorySize = 33400000; FreePhysicalMemory = 14100000 }
        }
        'Win32_Processor' { [pscustomobject]@{ Name = 'AMD Ryzen 7 7800X3D 8-Core Processor'; NumberOfCores = 8; NumberOfLogicalProcessors = 16 } }
        'Win32_ComputerSystem' { [pscustomobject]@{ Manufacturer = 'Micro-Star International'; Model = 'MS-7E26' } }
        'Win32_VideoController' { [pscustomobject]@{ Name = 'NVIDIA GeForce RTX 4070'; CurrentHorizontalResolution = 2560; CurrentVerticalResolution = 1440; CurrentRefreshRate = 144 } }
        'Win32_LogicalDisk' {
            [pscustomobject]@{ DeviceID = 'C:'; VolumeName = 'Système'; Size = 999GB; FreeSpace = 412GB }
            [pscustomobject]@{ DeviceID = 'D:'; VolumeName = 'Données'; Size = 1863GB; FreeSpace = 141GB }
        }
        'Win32_Battery' { [pscustomobject]@{ EstimatedChargeRemaining = 76; BatteryStatus = 2 } }
        'Win32_PerfFormattedData_PerfOS_Processor' {
            $loads = 34, 61, 12, 8, 77, 23, 5, 41, 18, 9, 52, 30, 4, 95, 11, 27
            [pscustomobject]@{ Name = '_Total'; PercentProcessorTime = 28 }
            for ($i = 0; $i -lt $loads.Count; $i++) { [pscustomobject]@{ Name = "$i"; PercentProcessorTime = $loads[$i] } }
        }
        'Win32_PerfFormattedData_Tcpip_NetworkInterface' { [pscustomobject]@{ Name = 'Intel Ethernet I226-V'; BytesReceivedPersec = 2480000; BytesSentPersec = 312000 } }
        default { @() }
    }
}

function Get-NetTCPConnection {
    param($State, $ErrorAction)
    [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 135; OwningProcess = $PID }
    [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 5432; OwningProcess = $PID }
    [pscustomobject]@{ LocalAddress = '::'; LocalPort = 3000; OwningProcess = $PID }
    [pscustomobject]@{ LocalAddress = '127.0.0.1'; LocalPort = 6379; OwningProcess = 1 }
}
function Get-NetUDPEndpoint { param($ErrorAction) [pscustomobject]@{ LocalAddress = '0.0.0.0'; LocalPort = 5353; OwningProcess = $PID } }

function Get-NetIPConfiguration {
    param([switch]$All, $ErrorAction)
    [pscustomobject]@{
        InterfaceAlias = 'Ethernet'; InterfaceDescription = 'Intel(R) Ethernet Controller I226-V'
        NetAdapter = [pscustomobject]@{ Status = 'Up'; LinkSpeed = '2.5 Gbps'; MacAddress = '04-7C-16-AA-BB-CC' }
        IPv4Address = @([pscustomobject]@{ IPAddress = '192.168.1.42'; PrefixLength = 24 })
        IPv6Address = @([pscustomobject]@{ IPAddress = 'fe80::1c2d:3e4f' })
        IPv4DefaultGateway = @([pscustomobject]@{ NextHop = '192.168.1.1' })
        DNSServer = @([pscustomobject]@{ AddressFamily = 2; ServerAddresses = @('1.1.1.1', '9.9.9.9') })
    }
}
function Get-NetIPAddress { param($AddressFamily, $ErrorAction) [pscustomobject]@{ IPAddress = '192.168.1.42'; AddressState = 'Preferred'; InterfaceMetric = 25 } }
function Get-ItemProperty { param([Parameter(Position = 0)]$Path) [pscustomobject]@{ DisplayVersion = '24H2'; CurrentBuild = '26100'; UBR = 2314 } }
