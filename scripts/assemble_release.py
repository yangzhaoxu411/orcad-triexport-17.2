"""Build an allowlisted package. Never copy .work or user CAD documents."""
from pathlib import Path
import hashlib
import importlib.metadata
import json
import shutil
import sys
import zipfile

BASE = Path(__file__).resolve().parents[1]
NAME = "OrCAD-TriExport-17.2-1.0.0-rc6"
RELEASE = BASE / "release" / NAME


def copy(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def main():
    RELEASE.parent.mkdir(exist_ok=True)
    marker = RELEASE / ".package-owned"
    if RELEASE.exists():
        if not marker.is_file() or marker.read_text() != NAME:
            raise RuntimeError("Refusing to replace an unmarked release directory")
        # Validate the resolved deletion target before any recursive removal.
        if RELEASE.resolve().parent != (BASE / "release").resolve() or RELEASE.is_symlink():
            raise RuntimeError("Unsafe release path")
        shutil.rmtree(RELEASE)
    RELEASE.mkdir()
    marker.write_text(NAME)
    payload = RELEASE / "payload"
    payload.mkdir()
    (payload / ".triexport-owned").write_text("OrCADTriExport-17.2-owned-v1")
    for file in ["TriExport.tcl", "zzTriExport.tcl"]:
        copy(BASE / "src" / file, payload / file)
    shutil.copytree(BASE / ".work/dist/TriExportWorker", payload / "bin")
    for name in ["README.md", "README-中文.md", "ENVIRONMENT.md", "CHANGELOG.md", "VALIDATION.md", "LICENSE.txt", "install.cmd", "install.ps1",
                 "uninstall.cmd", "uninstall.ps1", "Installer.Common.ps1", "build.ps1", "requirements-build.txt"]:
        copy(BASE / name, RELEASE / name)
    copy(BASE / "LICENSE.txt", payload / "LICENSE.txt")
    for pattern, directory in [("*.py", "src"), ("*.tcl", "src"), ("test_*.py", "tests"),
                               ("test_*.tcl", "tests"), ("test_*.ps1", "tests"), ("*.py", "scripts")]:
        for path in (BASE / directory).glob(pattern):
            copy(path, RELEASE / directory / path.name)
    third_party = payload / "THIRD_PARTY"
    copy(Path(sys.base_prefix) / "LICENSE.txt", third_party / "Python-LICENSE.txt")
    for dist_name in ["pypdf", "pyinstaller", "typing_extensions"]:
        dist = importlib.metadata.distribution(dist_name)
        for file in dist.files:
            if file.name in {"LICENSE", "LICENSE.txt", "COPYING.txt"} and ".dist-info" in str(file):
                copy(Path(dist.locate_file(file)), third_party / (dist_name + "-" + file.name))
    for name in ["OpenSSL-LICENSE.txt", "libffi-LICENSE.txt", "XZ-COPYING.txt"]:
        copy(BASE / "licenses" / name, third_party / name)
        copy(BASE / "licenses" / name, RELEASE / "licenses" / name)
    (third_party / "NOTICE.txt").write_text(
        "Runtime: CPython 3.12, pypdf 6.21.4, typing_extensions 4.16.0 and the PyInstaller 6.22.3 bootloader.\n"
        "PyInstaller's license includes the bootloader exception for generated applications.\n"
        "Windows runtime DLLs are part of the CPython binary distribution.\n"
        "CPython native modules use OpenSSL, libffi and liblzma; license texts are included.\n"
        "License sources: openssl/openssl tag openssl-3.5.8 LICENSE.txt;\n"
        "libffi/libffi tag v3.4.4 LICENSE; tukaani-project/xz tag v5.2.5 COPYING.\n"
        "OrCAD/Capture, Cadence libraries and Ghostscript are NOT included.\n"
        "The user supplies licensed OrCAD 17.2 and a separate Ghostscript installation.\n",
        encoding="utf-8")
    hashes = {p.relative_to(payload).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in sorted(payload.rglob("*")) if p.is_file()}
    (RELEASE / "payload-sha256.json").write_text(json.dumps(hashes, indent=2), encoding="utf-8")
    archive = RELEASE.parent / (NAME + ".zip")
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for path in sorted(RELEASE.rglob("*")):
            if path.is_file():
                z.write(path, NAME + "/" + path.relative_to(RELEASE).as_posix())
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    (RELEASE.parent / (NAME + ".zip.sha256.txt")).write_text(checksum + "  " + archive.name + "\n")
    print(f"Package: {archive}\nSize: {archive.stat().st_size:,} bytes\nSHA256: {checksum}")


if __name__ == "__main__":
    main()
