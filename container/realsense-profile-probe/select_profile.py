#!/usr/bin/env python3
"""Produce safe ROS launch argv within a shared capability-query deadline."""

import os
import re
import signal
import subprocess
import sys
import time


PROBE = "/usr/local/bin/realsense-profile-probe"
QUERY_TIMEOUT_S = 3.0


class ProbeInterrupted(BaseException):
    def __init__(self, signum):
        self.signum = signum


def interrupt_query(signum, _frame):
    raise ProbeInterrupted(signum)


def query(command, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("capability-query deadline reached")
    # ros2 launch --show-args may spawn a Python child. Kill the complete query
    # group on timeout so no probe process survives into the real driver launch.
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, start_new_session=True) as child:
        completed = False
        try:
            output, diagnostic = child.communicate(timeout=remaining)
            completed = True
        except subprocess.TimeoutExpired as error:
            raise TimeoutError("capability query exceeded 3 seconds") from error
        finally:
            if not completed:
                # Cancellation must reach the detached query group too. Shield
                # cleanup from a repeated signal until every query child exits.
                handlers = {signum: signal.signal(signum, signal.SIG_IGN)
                            for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)}
                try:
                    try:
                        os.killpg(child.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    child.communicate()
                finally:
                    for signum, handler in handlers.items():
                        signal.signal(signum, handler)
        if diagnostic:
            print(diagnostic.rstrip(), file=sys.stderr)
        if child.returncode:
            raise RuntimeError(f"{command[0]} query failed ({child.returncode})")
        return output


def argument_defaults(show_args):
    # Read each declared default from ROS launch --show-args, without importing
    # or evaluating the driver launch file. Unknown layouts safely fall back.
    defaults = {}
    current_name = None
    for line in show_args.splitlines():
        name = re.fullmatch(r"\s*['\"]([A-Za-z0-9_.]+)['\"]\s*:\s*", line)
        if name:
            current_name = name.group(1)
            continue
        value = (re.fullmatch(r"\s*\(default:\s*(['\"])(.*?)\1\)\s*", line) or
                 re.fullmatch(r"\s*Default value:\s*(['\"])(.*?)\1\s*", line))
        if current_name is not None and value:
            defaults[current_name] = value.group(2)
            current_name = None
    return defaults


def profile_arguments(requested, deadline):
    defaults = argument_defaults(query(
        ["ros2", "launch", "realsense2_camera", "rs_launch.py", "--show-args"],
        deadline))
    names = set(defaults)
    if {"rgb_camera.color_profile", "depth_module.depth_profile"} <= names:
        color_arg, depth_arg = "rgb_camera.color_profile", "depth_module.depth_profile"
    elif {"rgb_camera.profile", "depth_module.profile"} <= names:
        color_arg, depth_arg = "rgb_camera.profile", "depth_module.profile"
    else:
        raise RuntimeError("installed driver profile arguments unrecognized")
    required = {"serial_no", "rgb_camera.color_format", "depth_module.depth_format",
                "enable_sync"}
    if not required <= names:
        # Older drivers without explicit formats do not guarantee the same
        # baseline format. Their untouched launch remains the safe fallback.
        raise RuntimeError("installed driver cannot bind native formats and synchronization")
    if any(not re.fullmatch(r"0\s*[,xX]\s*0\s*[,xX]\s*0", defaults[name])
           for name in (color_arg, depth_arg)):
        raise RuntimeError("installed launch profile defaults are not native SDK defaults")
    color_default = defaults["rgb_camera.color_format"]
    depth_default = defaults["depth_module.depth_format"]
    if not all(re.fullmatch(r"[A-Z][A-Z0-9_]*", value)
               for value in (color_default, depth_default)):
        raise RuntimeError("installed launch format defaults unrecognized")
    fields = query([PROBE, str(requested), color_default, depth_default],
                   deadline).strip().split("|")
    if len(fields) != 8:
        raise ValueError("profile probe returned a malformed record")
    serial, cw, ch, dw, dh, fps, color_format, depth_format = fields
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", serial):
        raise ValueError("invalid profile serial")
    for value in (cw, ch, dw, dh, fps):
        if not re.fullmatch(r"[0-9]+", value) or not 0 < int(value) <= 2147483647:
            raise ValueError("invalid profile dimensions/FPS")
    if int(fps) not in {requested, *[rate for rate in (60, 30) if rate <= requested]}:
        raise ValueError("profile probe returned an unrequested FPS")
    if not all(re.fullmatch(r"[A-Z][A-Z0-9_]*", value)
               for value in (color_format, depth_format)):
        raise ValueError("invalid profile formats")
    if (color_format, depth_format) != (color_default, depth_default):
        raise ValueError("profile probe changed the launch-default pixel formats")
    print(f"RealSense selected RGB {cw}x{ch}/{color_format}, native depth "
          f"{dw}x{dh}/{depth_format}, target {fps} FPS; actual rate requires measurement",
          file=sys.stderr)
    # An underscore tells the ROS driver to keep a numeric serial as a string.
    return [f"serial_no:=_{serial}", f"{color_arg}:={cw},{ch},{fps}",
            f"{depth_arg}:={dw},{dh},{fps}",
            f"rgb_camera.color_format:={color_format}",
            f"depth_module.depth_format:={depth_format}", "enable_sync:=true"]


def main(argv):
    try:
        if len(argv) != 1 or not re.fullmatch(r"[0-9]+", argv[0]):
            raise ValueError("REALSENSE_TARGET_FPS must be a nonnegative integer")
        requested = int(argv[0])
        if requested == 0:
            return 0
        if requested > 2147483647:
            raise ValueError("REALSENSE_TARGET_FPS exceeds the SDK integer range")
        arguments = profile_arguments(requested, time.monotonic() + QUERY_TIMEOUT_S)
    except ProbeInterrupted as error:
        print(f"RealSense profile query interrupted (signal {error.signum}); "
              "camera startup cancelled", file=sys.stderr)
        return 128 + error.signum
    except (OSError, RuntimeError, TimeoutError, ValueError) as error:
        print(f"RealSense retaining original launch configuration: {error}", file=sys.stderr)
        return 0
    print("\n".join(arguments))
    return 0


if __name__ == "__main__":
    for stop_signal in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(stop_signal, interrupt_query)
    sys.exit(main(sys.argv[1:]))
