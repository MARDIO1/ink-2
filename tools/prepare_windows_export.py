"""Install only Windows templates from the official ZIP using HTTP ranges."""
import io
import pathlib
import urllib.request
import zipfile
from PIL import Image

class RemoteArchive(io.RawIOBase):
    def __init__(self, url):
        response = urllib.request.urlopen(urllib.request.Request(url, method="HEAD"), timeout=30)
        self.url = response.url
        self.length = int(response.headers["Content-Length"])
        self.position = 0

    def seekable(self):
        return True

    def tell(self):
        return self.position

    def seek(self, offset, whence=0):
        self.position = offset if whence == 0 else self.position + offset if whence == 1 else self.length + offset
        return self.position

    def read(self, size=-1):
        size = min(size if size >= 0 else self.length, self.length - self.position)
        if size <= 0:
            return b""
        request = urllib.request.Request(self.url, headers={"Range": f"bytes={self.position}-{self.position + size - 1}"})
        with urllib.request.urlopen(request, timeout=120) as response:
            if response.status != 206:
                raise RuntimeError("Server does not support partial downloads")
            chunks = []
            remaining = size
            while remaining:
                chunk = response.read(min(1024 * 1024, remaining))
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
                if size > 1024 * 1024:
                    print(f"Downloaded {(size - remaining) // 1024 // 1024}/{size // 1024 // 1024} MiB", flush=True)
            data = b"".join(chunks)
        if len(data) != size:
            raise RuntimeError("Incomplete download")
        self.position += len(data)
        return data

template_dir = pathlib.Path("C:/Users/youli/AppData/Roaming/Godot/export_templates/4.7.2.stable")
template_dir.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(RemoteArchive("https://github.com/godotengine/godot-builds/releases/download/4.7.2-stable/Godot_v4.7.2-stable_export_templates.tpz")) as archive:
    names = sorted([name for name in archive.namelist() if "windows" in name and "x86_64" in name], key=lambda name: ("release" not in name, "console" in name))
    print("Windows templates:", names, flush=True)
    for name in names:
        target = template_dir / pathlib.PurePosixPath(name).name
        if not target.exists():
            print("Downloading", name, flush=True)
            target.write_bytes(archive.read(name))
    (template_dir / "version.txt").write_text("4.7.2.stable", encoding="utf-8")

tools_dir = pathlib.Path("D:/Godot/export-tools")
tools_dir.mkdir(exist_ok=True)
rcedit = tools_dir / "rcedit-x64.exe"
if not rcedit.exists():
    urllib.request.urlretrieve("https://github.com/electron/rcedit/releases/download/v2.0.0/rcedit-x64.exe", rcedit)

image = Image.open("D:/Ink/ui/icon/int_fff.png").convert("RGBA")
image.save("D:/Ink/ui/icon/int_fff.ico", sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
print("Templates, resource editor and multi-size Windows icon ready", flush=True)
