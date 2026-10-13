import os
from pathlib import Path
import subprocess
import tempfile


source = (Path(__file__).resolve().parents[2] / "tools/install.sh").read_text()

with tempfile.TemporaryDirectory(prefix="macgenuity-installer-test-") as temp:
    root = Path(temp)
    commands = root / "bin"
    commands.mkdir()
    stubs = {
        "codesign": '#!/bin/bash\nexit "${VERIFY_FAILURE:-0}"\n',
        "xattr": "#!/bin/bash\nexit 0\n",
        "ditto": '#!/bin/bash\n[[ "${COPY_FAILURE:-0}" == 0 ]] || exit 1\n/bin/cp -R "$1" "$2"\n',
        "mv": '''#!/bin/bash
if [[ "${MOVE_FAILURE:-0}" == 1 && "$1" == */.MacGenuity-install.*/MacGenuity.app ]]; then
    exit 1
fi
/bin/mv "$@"
''',
    }
    for name, content in stubs.items():
        command = commands / name
        command.write_text(content)
        command.chmod(0o755)

    for failure in [None, "VERIFY_FAILURE", "COPY_FAILURE", "MOVE_FAILURE"]:
        case = root / (failure or "success")
        case.mkdir()
        destination = case / "Applications"
        destination.mkdir()
        old = destination / "MacGenuity.app"
        old.mkdir()
        (old / "version").write_text("old")
        new = case / "MacGenuity.app"
        new.mkdir()
        (new / "version").write_text("new")
        installer = case / "install.sh"
        installer.write_text(source.replace('DEST="/Applications"', f'DEST="{destination}"'))
        environment = dict(os.environ, PATH=f"{commands}:/usr/bin:/bin")
        if failure:
            environment[failure] = "1"
        result = subprocess.run(["/bin/bash", str(installer)], cwd=case,
                                env=environment, capture_output=True, text=True)
        assert (result.returncode == 0) == (failure is None), result.stderr
        assert (old / "version").read_text() == ("old" if failure else "new")
        assert (new / "version").read_text() == "new"
        assert not list(destination.glob(".MacGenuity-install.*"))

print("Installer success, verification failure, copy failure and rollback tests passed")
