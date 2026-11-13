# Run on a disposable Windows VM as administrator. All traffic stays on loopback.
param([Parameter(Mandatory)][string]$Dozor)
$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('dozor-fixture-' + [guid]::NewGuid() + '.exe')
$source = @'
using System;
using System.Net;
using System.Net.Sockets;
public class Fixture {
    public static int Main(string[] args) {
        var addr = IPAddress.Parse(args[0]);
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
function Check-Fixture([int]$Expected) {
    foreach ($server in $listeners) {
        $ep = $server.LocalEndpoint
        & $fixture ($ep.Address.ToString()) ($ep.Port.ToString())
        if ($LASTEXITCODE -ne $Expected) { throw "Expected fixture exit $Expected for $ep, got $LASTEXITCODE" }
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
    }
    Check-Fixture 0
    Change-Lock lock
    Change-Lock lock
    Check-Fixture 3
    Change-Lock unlock
    Check-Fixture 0

    & $Dozor guard '{00000000-0000-0000-0000-000000000000}' $fixture
    if ($LASTEXITCODE -eq 0) { throw 'Missing tunnel accepted' }
    Check-Fixture 3
    & $Dozor unlock $fixture ($fixture + '-missing.exe')
    if ($LASTEXITCODE -eq 0) { throw 'Invalid batch accepted' }
    Check-Fixture 3
} finally {
    foreach ($server in $listeners) { $server.Stop() }
    Change-Lock unlock
    Remove-Item -LiteralPath $fixture
}
