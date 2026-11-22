"""Test the real Launch Services handoff with an isolated app and a slow quit."""
import argparse
import pathlib
import plistlib
import re
import subprocess
import tempfile
import time
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[2]
FIXTURE = r'''
import AppKit

@main @MainActor
final class RelaunchFixture: NSObject, NSApplicationDelegate {
    static let delegate = RelaunchFixture()
    let directory = Bundle.main.bundleURL.deletingLastPathComponent()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let marker = directory.appendingPathComponent("first")
        let pid = ProcessInfo.processInfo.processIdentifier
        if let previous = try? String(contentsOf: marker, encoding: .utf8), let oldPID = Int32(previous) {
            let result = oldPID != pid && kill(oldPID, 0) == -1 && errno == ESRCH ? "ok" : "overlap"
            try! result.write(to: directory.appendingPathComponent("result"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        } else {
            try! String(pid).write(to: marker, atomically: true, encoding: .utf8)
            AppRelauncher.relaunch(resetInputMonitoring: FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("reset").path))
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
'''

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--reset", action="store_true", help="also exercise tccutil on the isolated test bundle")
args = parser.parse_args()
# tccutil looks up the bundle by ID. Launch Services excludes system temp directories from that lookup.
with tempfile.TemporaryDirectory(dir=pathlib.Path.home() if args.reset else None) as tmp:
    work = pathlib.Path(tmp)
    app = work / "Relaunch Check.app"
    contents = app / "Contents"
    binary = contents / "MacOS" / "RelaunchCheck"
    binary.parent.mkdir(parents=True)
    (contents / "Info.plist").write_bytes(plistlib.dumps(dict(
        CFBundleIdentifier="io.github.loujessler.macgenuity.relaunch-test." + uuid.uuid4().hex,
        CFBundleExecutable=binary.name, CFBundlePackageType="APPL", LSUIElement=True)))
    source = work / "Fixture.swift"
    source.write_text(FIXTURE)
    subprocess.run(["swiftc", "-parse-as-library", str(source),
                    str(ROOT / "MacGenuity/Infrastructure/System/AppRelauncher.swift"),
                    str(ROOT / "MacGenuity/Shared/Logger.swift"), "-o", str(binary)], check=True)
    subprocess.run(["codesign", "--sign", "-", str(app)], check=True)
    if args.reset:
        (work / "reset").touch()
    errors = work / "stderr"
    subprocess.run(["open", "-g", "-n", "--stderr", str(errors), str(app)], check=True)
    result = work / "result"
    for _ in range(200):
        if result.exists():
            break
        time.sleep(0.1)
    if not result.is_file():
        # A failed reset can leave the fixture displaying its recovery alert.
        binary.unlink()
        subprocess.run(["pkill", "-f", "^" + re.escape(str(binary.resolve())) + "( |$)"])
        raise AssertionError("The replacement app did not launch. " + errors.read_text().strip())
    assert result.read_text() == "ok", "The old and replacement processes overlapped"
    print("Relaunch passed with a new PID after the old process exited")
