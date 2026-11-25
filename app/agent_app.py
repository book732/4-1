#!/usr/bin/env python3
"""Local verification app; this is not the original application from the assignment."""


def _main():
    import os
    from http.server import BaseHTTPRequestHandler, HTTPServer
    from pathlib import Path

    def _ok(_step, _message):
        print(f"[{_step}/5] {_message} [OK]", flush=True)

    def _require(_condition, _message):
        if not _condition:
            raise RuntimeError(_message)

    class _Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            _body = b'{"status":"ready"}\n'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(_body)))
            self.end_headers()
            self.wfile.write(_body)

        def log_message(self, _format, *_args):
            # Avoid writing unbounded access logs for the verification endpoint.
            return

    try:
        print("Starting Agent Boot Sequence... (verification replacement)", flush=True)
        _require(os.geteuid() != 0, "Root execution is forbidden")
        _ok(1, "Checking User Account")
        _names = ("AGENT_HOME", "AGENT_PORT", "AGENT_UPLOAD_DIR", "AGENT_KEY_PATH", "AGENT_LOG_DIR")
        _require(all(os.environ.get(_name) for _name in _names), "Missing required environment")
        _home = Path(os.environ["AGENT_HOME"])
        _upload = Path(os.environ["AGENT_UPLOAD_DIR"])
        _key = Path(os.environ["AGENT_KEY_PATH"])
        _logs = Path(os.environ["AGENT_LOG_DIR"])
        _port = int(os.environ["AGENT_PORT"])
        _require(_port == 15034 and all(_path.is_absolute() for _path in (_home, _upload, _key, _logs)), "Invalid environment")
        _require(_upload == _home / "upload_files" and _key == _home / "api_keys/t_secret.key", "Unexpected application paths")
        _ok(2, "Verifying Environment Variables")
        _require(_key.read_bytes() == b"agent_api_key_test\n", "Invalid key file")
        _require(_upload.is_dir() and os.access(_upload, os.W_OK | os.X_OK), "Upload directory is not writable")
        _ok(3, "Checking Required Files")
        # Bind once and retain the socket through the remaining boot checks.
        with HTTPServer(("0.0.0.0", _port), _Handler) as _server:
            _ok(4, "Checking Port Availability")
            with (_logs / "boot.log").open("a", encoding="utf-8") as _stream:
                _stream.write("All Boot Checks Passed! Agent READY (verification replacement)\n")
            _ok(5, "Verifying Log Permission")
            print("All Boot Checks Passed!\nAgent READY", flush=True)
            _server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        return 0
    except (OSError, RuntimeError, ValueError) as _error:
        print(f"[ERROR] {_error}", flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(_main())
