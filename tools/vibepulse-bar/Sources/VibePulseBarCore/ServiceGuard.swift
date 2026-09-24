import Foundation

/// The launcher the app runs `tokenserver.py` through.
///
/// macOS has no parent-death signal: a crashed or force-quit app would leave
/// its child serving with nobody left to stop it. The launcher runs the
/// server in-process, stops it the way the app would once the app is gone,
/// and leads its own process group so helpers the server spawned (the
/// `codex app-server` probe) can be cleared out with it.
public enum ServiceGuard {
    public static let fileName = "vibepulse-bar-guard.py"
    /// Seconds the launcher gives the server's SIGINT cleanup before SIGKILL.
    public static let orphanGrace = 10

    /// Writes the launcher next to `directory`'s other app state and returns
    /// its path. Rewritten on every spawn, so it always matches this build.
    public static func install(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(self.fileName)
        let data = Data(self.source.utf8)
        if (try? Data(contentsOf: url)) != data {
            try data.write(to: url, options: .atomic)
        }
        return url
    }

    public static let source = #"""
    """VibePulse Bar's launcher for tokenserver.py (written by the app; edits are overwritten).

    usage: python3 -u vibepulse-bar-guard.py <tokenserver.py> [arguments...]
    """
    import os
    import runpy
    import signal
    import sys
    import threading
    import time

    POLL_S = 0.5
    GRACE_S = \#(orphanGrace)

    _stopping = threading.Event()


    def _note(message):
        stamp = time.strftime("%Y-%m-%d %H:%M:%S")
        print(f"{stamp} WARNING vibepulse-bar: {message}", flush=True)


    def _leads_group():
        return os.getpgrp() == os.getpid()


    def _on_sigint(signum, frame):
        # A second stop request must not cut the first one's cleanup short.
        if _stopping.is_set():
            return
        _stopping.set()
        raise KeyboardInterrupt


    def _watch_parent(parent):
        while os.getppid() == parent:
            time.sleep(POLL_S)
        if not _stopping.is_set():
            _note(f"app pid {parent} is gone; stopping tokenserver pid {os.getpid()}: SIGINT")
            os.kill(os.getpid(), signal.SIGINT)
        time.sleep(GRACE_S)
        _note(f"tokenserver pid {os.getpid()} still running {GRACE_S} s after the app left: SIGKILL")
        if _leads_group():
            os.killpg(os.getpid(), signal.SIGKILL)
        os._exit(70)


    def _stop_helpers():
        """SIGTERM whatever the server left behind in our process group."""
        if not _leads_group():
            return
        previous = signal.signal(signal.SIGTERM, signal.SIG_IGN)
        try:
            os.killpg(os.getpid(), signal.SIGTERM)
        except OSError:
            pass
        finally:
            signal.signal(signal.SIGTERM, previous)


    def main():
        if len(sys.argv) < 2:
            print(__doc__, file=sys.stderr)
            return 64
        script = os.path.abspath(sys.argv[1])
        try:
            os.setpgid(0, 0)
        except OSError:
            pass
        # An ignored SIGINT survives exec; the server's cleanup depends on it.
        # SIGTERM (logout, shutdown) takes the same path instead of skipping it.
        signal.signal(signal.SIGINT, _on_sigint)
        signal.signal(signal.SIGTERM, _on_sigint)
        parent = int(os.environ.pop("VPBAR_PARENT_PID", "") or 0) or os.getppid()
        threading.Thread(target=_watch_parent, args=(parent,),
                         name="vibepulse-bar-guard", daemon=True).start()
        sys.argv = [script] + sys.argv[2:]
        sys.path[0] = os.path.dirname(script)
        try:
            runpy.run_path(script, run_name="__main__")
        except KeyboardInterrupt:
            return 130
        finally:
            _stop_helpers()
        return 0


    if __name__ == "__main__":
        sys.exit(main())

    """#
}
