# Run on a disposable Windows VM as administrator. All traffic stays on loopback.
param([Parameter(Mandatory)][string]$Dozor, [string]$FixtureController)
$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('dozor-fixture-' + [guid]::NewGuid() + '.exe')
$source = @'
using System;
using System.Net;
using System.Net.Sockets;
public class Fixture {
    public static int Main(string[] args) {
        var addr = IPAddress.Parse(args[0]);
        if (args.Length == 3 && args[2] == "udp") {
            using (var udp = new UdpClient(addr.AddressFamily)) {
                try {
                    udp.Connect(addr, int.Parse(args[1]));
                    return udp.Send(new byte[]{42}, 1) == 1 ? 0 : 4;
                } catch (SocketException e) {
                    return e.SocketErrorCode == SocketError.AccessDenied ? 3 : 4;
                }
            }
        }
        using (var client = new TcpClient(addr.AddressFamily)) {
            try {
                var t = client.ConnectAsync(addr, int.Parse(args[1]));
                if (!t.Wait(3000)) return 2;
                return 0;
            } catch (AggregateException ex) {
                var socket = ex.GetBaseException() as SocketException;
                return socket != null && socket.SocketErrorCode == SocketError.AccessDenied ? 3 : 4;
            }
        }
    }
}
'@
$compiler = New-Object Microsoft.CSharp.CSharpCodeProvider
$params = New-Object System.CodeDom.Compiler.CompilerParameters
$params.GenerateExecutable = $true
$params.OutputAssembly = $fixture
$params.ReferencedAssemblies.Add('System.dll') | Out-Null
$result = $compiler.CompileAssemblyFromSource($params, $source)
if ($result.Errors.HasErrors) { throw ($result.Errors | Out-String) }
$listeners = @()
$udpReceivers = @()
function Check-Fixture([int]$Expected) {
    foreach ($server in $listeners) {
        $ep = $server.LocalEndpoint
        & $fixture ($ep.Address.ToString()) ($ep.Port.ToString())
        if ($LASTEXITCODE -ne $Expected) { throw "Expected fixture exit $Expected for $ep, got $LASTEXITCODE" }
    }
    foreach ($receiver in $udpReceivers) {
        $ep = $receiver.Client.LocalEndPoint
        & $fixture ($ep.Address.ToString()) ($ep.Port.ToString()) udp
        $exit = $LASTEXITCODE
        $available = $receiver.Client.Poll(250000, [Net.Sockets.SelectMode]::SelectRead)
        if ($Expected -eq 0) {
            if ($exit -ne 0 -or !$available) { throw "UDP baseline failed for $ep (exit $exit)" }
            $sender = $null
            $data = $receiver.Receive([ref]$sender)
            if ($data.Length -ne 1 -or $data[0] -ne 42) { throw "Unexpected UDP data on $ep" }
        } elseif ($available -or $exit -notin @(0, 3)) {
            throw "UDP lock failed for $ep (received: $available, exit: $exit)"
        }
    }
}
function Change-Lock([string]$Command) {
    & $Dozor $Command $fixture
    if ($LASTEXITCODE -ne 0) { throw "Dozor $Command failed ($LASTEXITCODE)" }
}
try {
    foreach ($ip in @([Net.IPAddress]::Loopback, [Net.IPAddress]::IPv6Loopback)) {
        $server = New-Object Net.Sockets.TcpListener($ip, 0)
        $server.Start()
        $listeners += $server
        $binding = New-Object Net.IPEndPoint($ip, 0)
        $udpReceivers += New-Object Net.Sockets.UdpClient($binding)
    }
    Check-Fixture 0
    Change-Lock lock
    Change-Lock lock
    Check-Fixture 3
    Change-Lock unlock
    Check-Fixture 0

    if ($FixtureController) {
        $log = [IO.Path]::GetTempFileName()
        $controller = $null
        try {
            $controller = Start-Process -FilePath $FixtureController -ArgumentList @('guard', '{00000000-0000-0000-0000-000000000000}', ('"' + $fixture + '"')) -PassThru -RedirectStandardOutput $log
            $ready = $false
            for ($i = 0; $i -lt 100; $i++) {
                if ($controller.HasExited) { throw "Fixture controller exited before installing rules" }
                if (Select-String -Quiet -LiteralPath $log -Pattern 'VPN rules active') { $ready = $true; break }
                Start-Sleep -Milliseconds 100
            }
            if (!$ready) { throw 'Timed out waiting for the loopback permits' }
            Check-Fixture 0
            $controller.Kill()
            $controller.WaitForExit()
            Check-Fixture 3
        } finally {
            if ($controller -and !$controller.HasExited) { $controller.Kill(); $controller.WaitForExit() }
            Remove-Item -LiteralPath $log
        }
    }

    & $Dozor guard '{00000000-0000-0000-0000-000000000000}' $fixture
    if ($LASTEXITCODE -eq 0) { throw 'Missing tunnel accepted' }
    Check-Fixture 3
    & $Dozor unlock $fixture ($fixture + '-missing.exe')
    if ($LASTEXITCODE -eq 0) { throw 'Invalid batch accepted' }
    Check-Fixture 3
} finally {
    foreach ($server in $listeners) { $server.Stop() }
    foreach ($receiver in $udpReceivers) { $receiver.Close() }
    Change-Lock unlock
    Remove-Item -LiteralPath $fixture
}
