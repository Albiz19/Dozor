"""Exercise the shipped sandbox policy against TCP/UDP sinks on loopback only."""
import errno
import json
import os
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

def endpoint(family, kind):
    s = socket.socket(family, kind)
    s.bind(("::1" if family == socket.AF_INET6 else "127.0.0.1", 0))
    if kind == socket.SOCK_STREAM:
        s.listen()
    return s

def probe(ports, guarded):
    out = []
    for i, (family, addr, kind) in enumerate([
            (socket.AF_INET, "127.0.0.1", socket.SOCK_STREAM), (socket.AF_INET, "127.0.0.1", socket.SOCK_DGRAM),
            (socket.AF_INET6, "::1", socket.SOCK_STREAM), (socket.AF_INET6, "::1", socket.SOCK_DGRAM)]):
        try:
            with socket.socket(family, kind) as s:
                s.settimeout(2); s.connect((addr, ports[i])); s.send(b"direct")
        except OSError as e:
            if not guarded or e.errno not in (errno.EPERM, errno.EACCES):
                raise
            out.append("denied")
        else:
            if guarded: raise AssertionError("unexpected direct delivery")
    return len(out)

def workload(args):
    depth, proxy, ports, tmp = int(args[0]),int(args[1]),json.loads(args[2]),Path(args[3])
    # The sandbox remains installed across both fork and exec.
    child = subprocess.Popen([sys.executable, __file__, "worker", str(depth+1), *args[1:]]) if depth < 2 else None
    try:
        assert os.environ["HTTP_PROXY"] == "http://127.0.0.1:"+str(proxy)
        n = probe(ports, True)
        with socket.create_connection(("127.0.0.1",proxy), timeout=4) as tunnel:
            tunnel.sendall(b"ping"); assert tunnel.recv(4) == b"pong"
            (tmp/f"ready{depth}").touch()
            assert tunnel.recv(1) == b""  # proxy drops an established tunnel
        n += probe(ports, True)
        try:
            socket.create_connection(("127.0.0.1",proxy),timeout=1).close()
        except ConnectionRefusedError:
            pass
        else:
            raise AssertionError("proxy unexpectedly reachable after drop")
        # A newly exec'd process after the drop inherits the same restriction.
        result = subprocess.check_output([sys.executable, __file__, "after", json.dumps(ports)], text=True)
        (tmp/f"count{depth}").write_text(str(n + int(result)))
        if child: assert child.wait(timeout=5) == 0
    finally:
        if child and child.poll() is None: child.kill(); child.wait()

def suite(launcher, verifier):
    with tempfile.TemporaryDirectory() as d:
        tmp=Path(d)
        sinks=[endpoint(f,k) for f in (socket.AF_INET,socket.AF_INET6) for k in (socket.SOCK_STREAM,socket.SOCK_DGRAM)]
        proxy=endpoint(socket.AF_INET,socket.SOCK_STREAM); proxy.settimeout(.1)
        upstream=endpoint(socket.AF_INET,socket.SOCK_STREAM); upstream.settimeout(.1)
        port=proxy.getsockname()[1]; ports=[s.getsockname()[1] for s in sinks]
        issuer=subprocess.Popen([verifier,"issue-permit",str(port)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
        assert issuer.stdout.readline().strip()=="ready"
        p=None
        closing=threading.Event(); lock=threading.Lock(); opened=[]; forwarded=[]; errors=[]
        def relay(client):
            try:
                with client:
                    data=client.recv(4)
                    if not data: return # launch-time health check
                    with socket.create_connection(upstream.getsockname(),timeout=2) as server:
                        server.sendall(data); client.sendall(server.recv(4))
                        closing.wait(5)
            except Exception as e: errors.append(e)
        def serve():
            while not closing.is_set():
                try: conn,_=proxy.accept()
                except socket.timeout: continue
                except OSError: return
                t=threading.Thread(target=relay,args=(conn,),daemon=True); opened.append(t);t.start()
        def receive():
            while not closing.is_set():
                try: conn,_=upstream.accept()
                except socket.timeout: continue
                except OSError: return
                with conn:
                    data=conn.recv(4); forwarded.append(data);conn.sendall(b"pong")
        try:
            probe(ports,False)
            for i,s in enumerate(sinks):
                s.settimeout(1)
                if i in (0,2):
                    with s.accept()[0] as client: assert client.recv(8)==b"direct"
                else: assert s.recv(8)==b"direct"
            print("PASS: all four unguarded TCP/UDP IPv4/IPv6 controls reach local sinks",flush=True)
            threads=[threading.Thread(target=f,daemon=True) for f in (serve,receive)]
            for t in threads:t.start()
            p=subprocess.Popen([launcher,str(port),sys.executable,__file__,"worker","0",str(port),json.dumps(ports),d])
            deadline=time.monotonic()+8
            while len(list(tmp.glob("ready*")))<3:
                assert p.poll() is None and time.monotonic()<deadline, "fixture failed before drop"
                time.sleep(.01)
            proxy.close();closing.set()
            assert p.wait(timeout=9)==0
            assert not errors and forwarded==[b"ping"]*3
            assert sum(int((tmp/f"count{i}").read_text()) for i in range(3))==36
            assert not select.select(sinks,[],[],.2)[0], "guarded traffic reached direct sinks"
            print("PASS: 3 proxied positive controls; 36 direct attempts denied; 0 direct accepts/datagrams; established proxy sockets reached EOF",flush=True)
            issuer.stdin.write("refresh\n");issuer.stdin.flush();assert issuer.stdout.readline().strip()=="ready"
            marker=tmp/"unexpected-launch"
            assert subprocess.run([launcher,str(port),"/usr/bin/touch",str(marker)]).returncode==69 and not marker.exists()
            print("PASS: valid permit but listener off cannot start a new job",flush=True)
            proxy2=endpoint(socket.AF_INET,socket.SOCK_STREAM)
            try:
                assert subprocess.run([launcher,str(proxy2.getsockname()[1]),"/usr/bin/touch",str(marker)]).returncode==69 and not marker.exists()
            finally: proxy2.close()
            issuer.stdin.close();issuer.wait(timeout=2)
            assert subprocess.run([launcher,str(port),"/usr/bin/touch",str(marker)]).returncode==69 and not marker.exists()
            print("PASS: wrong port and dead proof issuer cannot authorize launch",flush=True)
        finally:
            closing.set();proxy.close();upstream.close()
            for s in sinks:s.close()
            if p and p.poll() is None:p.kill();p.wait()
            if issuer.poll() is None:issuer.kill();issuer.wait()

if __name__=="__main__":
    if sys.argv[1]=="worker": workload(sys.argv[2:])
    elif sys.argv[1]=="after": print(probe(json.loads(sys.argv[2]),True))
    else: suite(*sys.argv[1:])
