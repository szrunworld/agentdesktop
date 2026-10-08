import os
import subprocess
import threading

process = subprocess.Popen(["swift", "test", "--package-path", "engine"])
done = threading.Event()

def diagnose():
    if done.wait(45):
        return
    print("Native tests still running: sampling descendants", flush=True)
    rows = subprocess.check_output(["ps", "-axo", "pid,ppid,comm"], text=True).splitlines()[1:]
    children = []
    ancestors = {process.pid}
    records = []
    for row in rows:
        fields = row.strip().split(None, 2)
        if len(fields) == 3:
            records.append((int(fields[0]), int(fields[1]), fields[2]))
    for _ in range(5):
        for pid, parent, command in records:
            if parent in ancestors:
                ancestors.add(pid)
    for pid, parent, command in records:
        if pid in ancestors:
            print(pid, parent, command, flush=True)
            if "swiftpm-testing" in command:
                output = f"/tmp/native-test-{pid}.sample.txt"
                subprocess.run(["sample", str(pid), "2", "1", "-file", output], timeout=15)
                if os.path.exists(output):
                    print(open(output).read(), flush=True)

threading.Thread(target=diagnose, daemon=True).start()
code = process.wait()
done.set()
raise SystemExit(code)
