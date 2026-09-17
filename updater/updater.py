"""
Updater.exe - Handles local auto-update for TestApp.

Usage:
    Updater.exe <installer_path> <testapp_exe_path>

Workflow:
    1. Validate installer exists
    2. Validate TestApp.exe path
    3. Wait for TestApp.exe to close
    4. Run the installer silently
    5. Wait for installer to finish
    6. Verify updated TestApp.exe
    7. Start TestApp.exe
    8. Write update log
    9. Exit
"""

import sys
import os
import time
import subprocess
import logging
from datetime import datetime
from pathlib import Path

LOG_DIR = Path(os.environ.get("APPDATA", "")) / "TestApp"
LOG_FILE = LOG_DIR / "update.log"
LOCK_FILE = LOG_DIR / "updater.lock"

UPDATE_TIMEOUT = 300  # 5 minutes max wait for installer
POLL_INTERVAL = 1     # seconds between checks


def setup_logging():
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        filename=str(LOG_FILE),
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    console = logging.StreamHandler()
    console.setLevel(logging.INFO)
    console.setFormatter(logging.Formatter("[%(levelname)s] %(message)s"))
    logging.getLogger().addHandler(console)


def acquire_lock():
    if LOCK_FILE.exists():
        try:
            lock_pid = int(LOCK_FILE.read_text().strip())
            if is_process_running(lock_pid):
                logging.error(
                    "Another Updater.exe process is already running (PID %d). "
                    "Exiting to prevent duplicates.",
                    lock_pid,
                )
                sys.exit(1)
            else:
                logging.warning(
                    "Stale lock file found (PID %d not running). Removing.",
                    lock_pid,
                )
                LOCK_FILE.unlink(missing_ok=True)
        except (ValueError, OSError):
            logging.warning("Corrupt lock file. Removing.")
            LOCK_FILE.unlink(missing_ok=True)

    LOCK_FILE.write_text(str(os.getpid()))
    logging.info("Lock acquired (PID %d).", os.getpid())


def release_lock():
    LOCK_FILE.unlink(missing_ok=True)
    logging.info("Lock released.")


def is_process_running(pid):
    try:
        result = subprocess.run(
            ["tasklist", "/FI", f"PID eq {pid}", "/NH"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        return str(pid) in result.stdout
    except Exception:
        return False


def wait_for_process_close(exe_name, timeout=UPDATE_TIMEOUT):
    exe_lower = exe_name.lower()
    logging.info("Waiting for %s to close (timeout=%ds)...", exe_name, timeout)
    start = time.time()

    while time.time() - start < timeout:
        result = subprocess.run(
            ["tasklist", "/FI", f"IMAGENAME eq {exe_name}"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if exe_lower not in result.stdout.lower():
            logging.info("%s has closed.", exe_name)
            return True
        time.sleep(POLL_INTERVAL)

    logging.error("Timed out waiting for %s to close.", exe_name)
    return False


def run_installer(installer_path):
    logging.info("Starting installer: %s", installer_path)
    try:
        process = subprocess.Popen(
            [
                str(installer_path),
                "/VERYSILENT",
                "/SUPPRESSMSGBOXES",
                "/NORESTART",
                "/SP-",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        logging.info("Installer started with PID %d. Waiting for it to finish...", process.pid)
        process.wait(timeout=UPDATE_TIMEOUT)

        if process.returncode == 0:
            logging.info("Installer finished successfully (exit code 0).")
            return True
        else:
            logging.warning(
                "Installer finished with exit code %d. "
                "This may still be acceptable (e.g. reboot requested).",
                process.returncode,
            )
            return True

    except subprocess.TimeoutExpired:
        logging.error("Installer timed out after %ds.", UPDATE_TIMEOUT)
        try:
            process.kill()
        except Exception:
            pass
        return False
    except Exception as e:
        logging.error("Failed to start installer: %s", e)
        return False


def verify_updated_exe(testapp_exe_path):
    path = Path(testapp_exe_path)
    if path.exists():
        size = path.stat().st_size
        logging.info("Verified TestApp.exe exists (size: %d bytes).", size)
        return True
    logging.error("TestApp.exe not found at: %s", testapp_exe_path)
    return False


def start_testapp(testapp_exe_path):
    logging.info("Starting TestApp.exe: %s", testapp_exe_path)
    try:
        subprocess.Popen(
            [str(testapp_exe_path)],
            cwd=str(Path(testapp_exe_path).parent),
        )
        logging.info("TestApp.exe started successfully.")
        return True
    except Exception as e:
        logging.error("Failed to start TestApp.exe: %s", e)
        return False


def cleanup_installer(installer_path):
    try:
        path = Path(installer_path)
        if path.exists():
            path.unlink()
            logging.info("Cleaned up downloaded installer: %s", installer_path)
    except Exception as e:
        logging.warning("Could not clean up installer: %s", e)


def write_log_summary(installer_path, testapp_exe_path, success):
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    status = "SUCCESS" if success else "FAILED"
    summary = (
        f"\n{'='*50}\n"
        f"Update Summary\n"
        f"{'='*50}\n"
        f"Timestamp:  {timestamp}\n"
        f"Status:     {status}\n"
        f"Installer:  {installer_path}\n"
        f"Target:     {testapp_exe_path}\n"
        f"{'='*50}\n"
    )
    logging.info(summary)


def main():
    setup_logging()
    logging.info("Updater.exe started.")

    if len(sys.argv) != 3:
        logging.error(
            "Usage: Updater.exe <installer_path> <testapp_exe_path>"
        )
        sys.exit(1)

    installer_path = sys.argv[1]
    testapp_exe_path = sys.argv[2]
    logging.info("Installer path: %s", installer_path)
    logging.info("TestApp.exe path: %s", testapp_exe_path)

    acquire_lock()

    success = False
    exit_code = 1
    try:
        # Step 1: Validate installer
        if not os.path.isfile(installer_path):
            logging.error("Installer not found: %s", installer_path)
            write_log_summary(installer_path, testapp_exe_path, False)
            return

        logging.info("Installer validated: %s", installer_path)

        # Step 2: Validate TestApp.exe path
        if not os.path.isdir(os.path.dirname(testapp_exe_path)):
            logging.error("TestApp.exe directory not found: %s", testapp_exe_path)
            write_log_summary(installer_path, testapp_exe_path, False)
            return

        logging.info("TestApp.exe path validated.")

        # Step 3: Wait for TestApp.exe to close
        testapp_exe_name = os.path.basename(testapp_exe_path)
        if not wait_for_process_close(testapp_exe_name):
            logging.error("TestApp.exe did not close in time. Aborting.")
            write_log_summary(installer_path, testapp_exe_path, False)
            return

        # Step 4: Run installer
        if not run_installer(installer_path):
            logging.error("Installer failed. Aborting.")
            write_log_summary(installer_path, testapp_exe_path, False)
            return

        # Step 5: Verify updated exe
        time.sleep(2)
        if not verify_updated_exe(testapp_exe_path):
            logging.error("Updated TestApp.exe not found. Aborting.")
            write_log_summary(installer_path, testapp_exe_path, False)
            return

        # Step 6: Start TestApp.exe
        if not start_testapp(testapp_exe_path):
            logging.error("Failed to start TestApp.exe after update.")
            write_log_summary(installer_path, testapp_exe_path, False)
            return

        success = True
        exit_code = 0
        write_log_summary(installer_path, testapp_exe_path, True)
        logging.info("Update completed successfully.")

        cleanup_installer(installer_path)

    except Exception as e:
        logging.error("Unexpected error during update: %s", e)
        write_log_summary(installer_path, testapp_exe_path, False)
    finally:
        release_lock()

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
