"""隔离守护进程的命令行客户端，仅用于验收：netd.py status|arm <网卡> [域名...]|pin <网卡>|block|release|terminate"""
import json, socket, sys
def call(**request):
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(25); s.connect("/var/run/appnetworkguard/control.sock")
        s.sendall(json.dumps(request).encode() + b"\n"); s.shutdown(socket.SHUT_WR)
        data = b""
        while part := s.recv(65536): data += part
    return json.loads(data)
if __name__ == "__main__":
    a = sys.argv[1:] or ["status"]
    r = (call(command="arm", mode="usb", interface=a[1], domains=[d for d in a[2:] if d[0] != "-"], strictDNS="-dns" in a, confined="-confined" in a) if a[0] == "arm" else
         call(command="arm", mode="pin", interface=a[1]) if a[0] == "pin" else call(command=a[0]))
    if "-v" not in a: r["events"] = [f"{e['kind']}: {e['detail']}" for e in r.get("events", [])[-4:]]
    print(json.dumps(r, ensure_ascii=False))
