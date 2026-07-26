from __future__ import annotations

import datetime as dt
import hashlib
import json
import math
import os
import re
import statistics
import subprocess
import time
import xml.etree.ElementTree as ET
from pathlib import Path


PROJECT = Path(__file__).resolve().parents[1]
WORKSPACE = PROJECT.parents[1]
SERIAL = "127.0.0.1:7555"


class PerformanceFailure(RuntimeError):
    pass


def run(
    command: list[str],
    *,
    timeout: int = 60,
    env: dict[str, str] | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        cwd=PROJECT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        encoding="utf-8",
        errors="replace",
        text=True,
        timeout=timeout,
        check=False,
    )
    if check and result.returncode != 0:
        raise PerformanceFailure("external performance step failed")
    return result


def read_local_properties() -> dict[str, str]:
    properties: dict[str, str] = {}
    for line in (PROJECT / "android" / "local.properties").read_text(
        encoding="utf-8"
    ).splitlines():
        if "=" not in line or line.lstrip().startswith("#"):
            continue
        key, value = line.split("=", 1)
        properties[key.strip()] = value.strip().replace("\\\\", "\\")
    return properties


PROPERTIES = read_local_properties()
FLUTTER = Path(PROPERTIES["flutter.sdk"]) / "bin" / "flutter.bat"
ANDROID_SDK = Path(PROPERTIES["sdk.dir"])
ADB = ANDROID_SDK / "platform-tools" / "adb.exe"
CORE = WORKSPACE / "project" / "LanzouYOU" / "native" / "lanzouyou_core"


def adb(*arguments: str, timeout: int = 60, check: bool = True) -> str:
    return run(
        [str(ADB), "-s", SERIAL, *arguments], timeout=timeout, check=check
    ).stdout


def find_aapt() -> Path:
    def key(path: Path) -> tuple[int, ...]:
        values = re.findall(r"\d+", path.parent.name)
        return tuple(map(int, values)) if values else (0,)

    candidates = sorted((ANDROID_SDK / "build-tools").glob("*/aapt.exe"), key=key)
    if not candidates:
        raise PerformanceFailure("aapt is unavailable")
    return candidates[-1]


def artifact_metadata(apk: Path) -> dict[str, str]:
    raw = run([str(find_aapt()), "dump", "badging", str(apk)]).stdout
    package_match = re.search(r"package: name='([^']+)'", raw)
    activity_match = re.search(r"launchable-activity: name='([^']+)'", raw)
    if not package_match or not activity_match:
        raise PerformanceFailure("profile package metadata is incomplete")
    package = package_match.group(1)
    activity = activity_match.group(1)
    if activity.startswith("."):
        activity = package + activity
    elif "." not in activity:
        activity = f"{package}.{activity}"
    return {
        "package": package,
        "activity": activity,
        "component": f"{package}/{activity}",
    }


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_int(raw: str, pattern: str) -> int | None:
    match = re.search(pattern, raw, re.MULTILINE | re.IGNORECASE)
    return int(match.group(1).replace(",", "")) if match else None


def parse_float(raw: str, pattern: str) -> float | None:
    match = re.search(pattern, raw, re.MULTILINE | re.IGNORECASE)
    return float(match.group(1)) if match else None


def ui_xml() -> str:
    remote = "/data/local/tmp/library_shell_profile_ui.xml"
    adb("shell", "uiautomator", "dump", remote, timeout=30, check=False)
    raw = adb("shell", "cat", remote, timeout=30, check=False)
    adb("shell", "rm", "-f", remote, timeout=30, check=False)
    start = raw.find("<?xml")
    end = raw.rfind("</hierarchy>")
    if start < 0 or end < start:
        return ""
    return raw[start : end + len("</hierarchy>")]


def wait_for_ui(predicate, timeout_seconds: float = 15.0) -> str:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        xml = ui_xml()
        if predicate(xml):
            return xml
        time.sleep(0.25)
    raise PerformanceFailure("profile UI did not reach the required state")


def node_bounds(raw: str) -> tuple[int, int, int, int] | None:
    match = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", raw)
    return tuple(map(int, match.groups())) if match else None


def first_source_center(xml: str, width: int, height: int) -> tuple[int, int]:
    try:
        root = ET.fromstring(xml)
    except ET.ParseError as error:
        raise PerformanceFailure("profile UI tree is invalid") from error
    candidates: list[tuple[int, int, int, int]] = []
    for node in root.iter("node"):
        if node.attrib.get("clickable") != "true":
            continue
        value = node_bounds(node.attrib.get("bounds", ""))
        if value is None:
            continue
        left, top, right, bottom = value
        if (
            right - left >= width * 0.35
            and bottom - top >= height * 0.07
            and top > height * 0.04
            and bottom < height * 0.86
        ):
            candidates.append(value)
    if not candidates:
        raise PerformanceFailure("profile source entry is unavailable")
    left, top, right, bottom = min(candidates, key=lambda item: (item[1], item[0]))
    return (left + right) // 2, (top + bottom) // 2


def visible_indices(xml: str) -> list[int]:
    return sorted({int(value) - 1 for value in re.findall(r"性能项目\s*(\d{4})", xml)})


def process_sample(pid: int) -> tuple[int, float]:
    raw = adb("shell", "cat", f"/proc/{pid}/stat")
    close = raw.rfind(")")
    if close < 0:
        raise PerformanceFailure("profile process accounting is unavailable")
    fields = raw[close + 2 :].split()
    ticks = int(fields[11]) + int(fields[12])
    uptime = float(adb("shell", "cat", "/proc/uptime").split()[0])
    return ticks, uptime


def current_pid(package: str) -> int:
    raw = adb("shell", "pidof", package, check=False).strip()
    match = re.match(r"\d+", raw)
    if not match:
        raise PerformanceFailure("profile process is not alive")
    return int(match.group(0))


def renderer(package: str, pid: int) -> str:
    raw = adb("logcat", "-d", f"--pid={pid}", timeout=30, check=False)
    relevant = "\n".join(
        line for line in raw.splitlines() if package in line or "flutter" in line.lower()
    ).lower()
    if "impeller" in relevant and "vulkan" in relevant:
        return "impeller_vulkan"
    if "impeller" in relevant and ("opengles" in relevant or "open gl" in relevant):
        return "impeller_opengles"
    if "impeller" in relevant:
        return "impeller_unspecified"
    if "skia" in relevant:
        return "skia"
    return "not_reported"


def parse_memory(raw: str) -> dict[str, int | None]:
    return {
        "totalPssKb": parse_int(raw, r"^\s*TOTAL PSS:\s*([\d,]+)"),
        "javaHeapKb": parse_int(raw, r"^\s*Java Heap:\s*([\d,]+)"),
        "nativeHeapKb": parse_int(raw, r"^\s*Native Heap:\s*([\d,]+)"),
        "graphicsKb": parse_int(raw, r"^\s*Graphics:\s*([\d,]+)"),
    }


def parse_gfx(raw: str) -> dict[str, int | float | None]:
    return {
        "totalFrames": parse_int(raw, r"^\s*Total frames rendered:\s*([\d,]+)"),
        "jankyFrames": parse_int(raw, r"^\s*Janky frames:\s*([\d,]+)"),
        "jankyPercent": parse_float(
            raw, r"^\s*Janky frames:\s*[\d,]+\s*\(([\d.]+)%\)"
        ),
        "p50Ms": parse_int(raw, r"^\s*50th percentile:\s*(\d+)ms"),
        "p90Ms": parse_int(raw, r"^\s*90th percentile:\s*(\d+)ms"),
        "p95Ms": parse_int(raw, r"^\s*95th percentile:\s*(\d+)ms"),
        "p99Ms": parse_int(raw, r"^\s*99th percentile:\s*(\d+)ms"),
        "missedVsync": parse_int(raw, r"^\s*Number Missed Vsync:\s*([\d,]+)"),
        "slowUiThread": parse_int(raw, r"^\s*Number Slow UI thread:\s*([\d,]+)"),
        "slowBitmapUploads": parse_int(
            raw, r"^\s*Number Slow bitmap uploads:\s*([\d,]+)"
        ),
    }


def surface_history(surface: str) -> str:
    return adb(
        "shell", "dumpsys", "SurfaceFlinger", "--latency", surface,
        timeout=30, check=False,
    )


def current_flutter_surface(package: str) -> str | None:
    raw = adb("shell", "dumpsys", "SurfaceFlinger", "--list", check=False)
    candidates = [
        line.strip()
        for line in raw.splitlines()
        if package in line and "SurfaceView" in line
    ]
    ranked: list[tuple[int, str]] = []
    for candidate in candidates:
        sample_count = sum(
            len(line.split()) >= 3
            and all(value.isdigit() for value in line.split()[:3])
            for line in surface_history(candidate).splitlines()
        )
        ranked.append((sample_count, candidate))
    return max(ranked, default=(0, None), key=lambda item: item[0])[1]


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    weight = position - lower
    return ordered[lower] * (1 - weight) + ordered[upper] * weight


def surface_metrics(surface: str | None) -> dict[str, int | float | None]:
    empty = {
        "frameIntervals": None,
        "longIntervals": None,
        "longIntervalPercent": None,
        "p95IntervalMs": None,
    }
    if surface is None:
        return empty
    rows = [line.split() for line in surface_history(surface).splitlines() if line.strip()]
    if not rows or len(rows[0]) != 1:
        return empty
    try:
        refresh_ns = int(rows[0][0])
    except ValueError:
        return empty
    timestamps: list[int] = []
    for row in rows[1:]:
        if len(row) < 3:
            continue
        try:
            value = int(row[1])
        except ValueError:
            continue
        if 0 < value < 9_000_000_000_000_000_000:
            timestamps.append(value)
    deltas = [
        (right - left) / 1_000_000
        for left, right in zip(timestamps, timestamps[1:])
        if right > left
    ]
    long_count = sum(value > refresh_ns / 1_000_000 * 1.5 for value in deltas)
    return {
        "frameIntervals": len(deltas),
        "longIntervals": long_count,
        "longIntervalPercent": round(long_count * 100 / len(deltas), 3)
        if deltas
        else None,
        "p95IntervalMs": round(percentile(deltas, 0.95), 3) if deltas else None,
    }


def collect_adb_workload(
    apk: Path, metadata: dict[str, str]
) -> dict[str, object]:
    package = metadata["package"]
    install = adb("install", "-r", "-t", str(apk), timeout=180, check=False)
    if "Success" not in install:
        raise PerformanceFailure("profile APK installation failed")
    adb("logcat", "-c", check=False)
    adb("shell", "am", "force-stop", package, check=False)
    launch_raw = adb(
        "shell", "am", "start", "-S", "-W", "-n", metadata["component"],
        timeout=90,
    )
    time.sleep(2)
    pid = current_pid(package)
    renderer_mode = renderer(package, pid)
    size_raw = adb("shell", "wm", "size")
    density_raw = adb("shell", "wm", "density")
    size_match = re.search(r"(\d+)x(\d+)", size_raw)
    density_match = re.search(r"(\d+)", density_raw)
    if not size_match or not density_match:
        raise PerformanceFailure("profile display metrics are unavailable")
    width, height = map(int, size_match.groups())
    density = int(density_match.group(1))

    home_xml = wait_for_ui(lambda value: "目录" in value and "首页" in value)
    adb("shell", "input", "tap", str(round(width * 0.75)), str(round(height * 0.94)))
    overview_xml = wait_for_ui(lambda value: "全部来源" in value)
    source_center = first_source_center(overview_xml, width, height)
    adb("shell", "input", "tap", str(source_center[0]), str(source_center[1]))
    directory_xml = wait_for_ui(lambda value: "已显示 1000 个项目" in value)
    before = visible_indices(directory_xml)
    if not before:
        raise PerformanceFailure("profile list items are not observable")

    surface = current_flutter_surface(package)
    if surface:
        adb(
            "shell", "dumpsys", "SurfaceFlinger", "--latency-clear", surface,
            check=False,
        )
    adb("shell", "dumpsys", "gfxinfo", package, "reset", check=False)
    clock_raw = adb("shell", "getconf", "CLK_TCK", check=False).strip()
    clock_ticks = int(clock_raw) if clock_raw.isdigit() else 100
    core_raw = adb("shell", "nproc", check=False).strip()
    cores = int(core_raw) if core_raw.isdigit() else 1
    ticks_before, uptime_before = process_sample(pid)
    for _ in range(10):
        adb(
            "shell", "input", "swipe",
            str(round(width * 0.55)), str(round(height * 0.76)),
            str(round(width * 0.55)), str(round(height * 0.30)), "520",
        )
        time.sleep(0.08)
    time.sleep(0.5)
    ticks_after, uptime_after = process_sample(pid)
    elapsed = max(uptime_after - uptime_before, 0.001)
    single_core_cpu = max(ticks_after - ticks_before, 0) / clock_ticks / elapsed * 100
    after_xml = ui_xml()
    after = visible_indices(after_xml)
    if not after or after[0] <= before[0] or after[-1] <= before[-1]:
        raise PerformanceFailure("profile list did not move after repeated swipes")

    memory = parse_memory(adb("shell", "dumpsys", "meminfo", package, timeout=45))
    gfx = parse_gfx(
        adb("shell", "dumpsys", "gfxinfo", package, "framestats", timeout=45)
    )
    surface_data = surface_metrics(surface)
    return {
        "device": {
            "profile": "local_android_emulator",
            "serialAlias": "mumu_local_only",
            "resolutionPx": [width, height],
            "densityDpi": density,
            "cpuCores": cores,
        },
        "launch": {
            "statusOk": bool(
                re.search(r"^Status:\s*ok", launch_raw, re.MULTILINE | re.IGNORECASE)
            ),
            "totalTimeMs": parse_int(launch_raw, r"^TotalTime:\s*(\d+)"),
            "waitTimeMs": parse_int(launch_raw, r"^WaitTime:\s*(\d+)"),
        },
        "renderer": renderer_mode,
        "cpu": {
            "singleCoreEquivalentPercent": round(single_core_cpu, 3),
            "deviceNormalizedPercent": round(single_core_cpu / max(cores, 1), 3),
            "sampleSeconds": round(elapsed, 3),
        },
        "memory": memory,
        "uiFlow": {
            "homeReady": bool(home_xml),
            "sourceOverviewReady": bool(overview_xml),
            "itemCount": 1000,
            "beforeFirstIndex": before[0],
            "beforeLastIndex": before[-1],
            "afterFirstIndex": after[0],
            "afterLastIndex": after[-1],
            "visibleRangeChanged": True,
            "swipeCount": 10,
        },
        "androidHostGfx": gfx,
        "surfaceFlingerCadence": surface_data,
    }


def build_profile(environment: dict[str, str]) -> Path:
    build = run(
        [
            str(FLUTTER),
            "build",
            "apk",
            "--profile",
            "--target",
            "tool/library_shell_performance_harness.dart",
        ],
        timeout=900,
        env=environment,
    )
    if "Built" not in build.stdout:
        raise PerformanceFailure("profile build did not report an artifact")
    apk = PROJECT / "build" / "app" / "outputs" / "flutter-apk" / "app-profile.apk"
    if not apk.is_file():
        raise PerformanceFailure("profile artifact is missing")
    return apk


def run_integration_test(
    environment: dict[str, str], report_path: Path
) -> dict[str, object]:
    drive_environment = dict(environment)
    drive_environment["SHELL_PERF_REPORT"] = str(report_path)
    result = run(
        [
            str(FLUTTER),
            "drive",
            "--no-dds",
            "--profile",
            "--device-id",
            SERIAL,
            "--driver",
            "test_driver/library_shell_performance_driver.dart",
            "--target",
            "integration_test/library_shell_performance_test.dart",
        ],
        timeout=900,
        env=drive_environment,
        check=False,
    )
    if result.returncode != 0 or not report_path.is_file():
        raise PerformanceFailure("profile integration performance gate failed")
    report = json.loads(report_path.read_text(encoding="utf-8"))
    if report.get("thresholdsPassed") is not True:
        raise PerformanceFailure("profile performance thresholds failed")
    return {
        "report": report,
        "drivePassed": "All tests passed." in result.stdout,
        "startMarkerCount": result.stdout.count("SHELL_PERF_SCROLL_START"),
        "endMarkerCount": result.stdout.count("SHELL_PERF_SCROLL_END"),
    }


def summary_markdown(metrics: dict[str, object]) -> str:
    frames = metrics["flutterFrames"]
    adb_data = metrics["adbSupport"]
    workload = metrics["workload"]
    return f"""# Android 软件库壳 Profile 长列表性能

本报告仅包含匿名性能数据；没有记录包名、运行配置链接或业务文件名称。

## 结论

- Profile testHarness 已真实进入 {workload['itemCount']} 项惰性目录；可见范围由 {workload['beforeFirstIndex']}–{workload['beforeLastIndex']} 移动到 {workload['afterFirstIndex']}–{workload['afterLastIndex']}，10 次长滑动成功。
- Flutter FrameTiming 共 {frames['frameCount']} 帧，jank {frames['jankyFrames']} 帧（{frames['jankyPercent']}%）；P50/P90/P95/P99 为 {frames['p50Ms']}/{frames['p90Ms']}/{frames['p95Ms']}/{frames['p99Ms']} ms。
- 帧耗时口径为每帧 `max(buildDuration, rasterDuration)`；P95≤24 ms、P99≤50 ms、采样≥120 帧及 UI/Raster 预算超限率≤10% 的机器阈值全部通过。
- ADB 旁证：启动 {adb_data['launch']['totalTimeMs']} ms，单核等效 CPU {adb_data['cpu']['singleCoreEquivalentPercent']}%，设备归一 CPU {adb_data['cpu']['deviceNormalizedPercent']}%，Total PSS {adb_data['memory']['totalPssKb']} KB，renderer={adb_data['renderer']}。

## 边界

- 这是 Profile testHarness 的本地 1000 项压力负载，包含每项唯一 HTTPS 占位图标路径与同一合法小 PNG 的异步解码；不联网、不使用正式数据。
- 正式 production Rust 数据链路由 contract/release smoke 单独证明；Android host gfxinfo 与 SurfaceFlinger 仅作旁证，性能结论以 Flutter FrameTiming 为准。
"""


def main() -> None:
    if not all(path.exists() for path in (FLUTTER, ADB, CORE)):
        raise PerformanceFailure("profile prerequisites are incomplete")
    if adb("get-state", check=False).strip() != "device":
        raise PerformanceFailure("the required MuMu target is unavailable")

    timestamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    output_dir = (
        WORKSPACE / "verification" / "performance" / f"shell-android-profile-{timestamp}"
    )
    output_dir.mkdir(parents=True, exist_ok=False)
    frame_report = output_dir / ".frame-report.json"
    environment = dict(os.environ)
    environment["LANZOUYOU_CORE_DIR"] = str(CORE)
    package: str | None = None
    cleanup = {"forceStopped": False, "uninstalled": False}
    try:
        apk = build_profile(environment)
        metadata = artifact_metadata(apk)
        package = metadata["package"]
        adb_support = collect_adb_workload(apk, metadata)
        integration = run_integration_test(environment, frame_report)
        adb("shell", "am", "force-stop", package, check=False)
        cleanup["forceStopped"] = not bool(
            adb("shell", "pidof", package, check=False).strip()
        )
        adb("uninstall", package, timeout=90, check=False)
        cleanup["uninstalled"] = not bool(
            adb("shell", "pm", "path", package, check=False).strip()
        )

        frame_report_data = integration["report"]
        metrics: dict[str, object] = {
            "schemaVersion": 1,
            "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
            "buildMode": "profile",
            "artifact": {
                "bytes": apk.stat().st_size,
                "sha256": sha256(apk),
                "runtimeProfileModeProven": True,
            },
            "device": adb_support.pop("device"),
            "methodology": {
                "primaryFrames": "Flutter IntegrationTest watchPerformance FrameTiming",
                "frameTimeDefinition": "max(buildDuration,rasterDuration)",
                "flow": "home -> directory -> one source -> 1000-item lazy grid -> ten timed long swipes",
                "assets": "unique placeholder HTTPS icon URLs with one local valid PNG payload",
                "networkUsed": False,
                "adbSerialPolicy": "mumu_local_only",
            },
            "workload": frame_report_data["workload"],
            "flutterFrames": frame_report_data["flutterFrames"],
            "rawFrameTiming": frame_report_data["rawFrameTiming"],
            "thresholdsPassed": frame_report_data["thresholdsPassed"],
            "adbSupport": adb_support,
            "integrationDriver": {
                "passed": integration["drivePassed"],
                "startMarkerCount": integration["startMarkerCount"],
                "endMarkerCount": integration["endMarkerCount"],
            },
            "cleanup": cleanup,
            "scope": {
                "profileTestHarness": True,
                "productionRuntimeData": False,
            },
        }
        json_text = json.dumps(metrics, ensure_ascii=False, indent=2) + "\n"
        markdown = summary_markdown(metrics)
        if package in json_text or package in markdown or re.search(
            r"https?://", json_text + markdown, re.IGNORECASE
        ):
            raise PerformanceFailure("profile evidence anonymization failed")
        (output_dir / "metrics.json").write_text(
            json_text, encoding="utf-8", newline="\n"
        )
        (output_dir / "summary.md").write_text(
            markdown, encoding="utf-8", newline="\n"
        )
        (output_dir / "profile-run.log").write_text(
            "\n".join(
                [
                    "target=mumu_local_only",
                    "build_mode=profile",
                    "standalone_adb_workload=pass",
                    "integration_frame_timing=pass",
                    "threshold_gate=pass",
                    f"force_stopped={str(cleanup['forceStopped']).lower()}",
                    f"uninstalled={str(cleanup['uninstalled']).lower()}",
                ]
            )
            + "\n",
            encoding="utf-8",
            newline="\n",
        )
        print(
            json.dumps(
                {
                    "evidenceDirectory": str(output_dir.relative_to(WORKSPACE)),
                    "flutterFrames": metrics["flutterFrames"],
                    "launch": adb_support["launch"],
                    "cpu": adb_support["cpu"],
                    "memory": adb_support["memory"],
                    "renderer": adb_support["renderer"],
                    "cleanup": cleanup,
                },
                ensure_ascii=False,
                indent=2,
            )
        )
    finally:
        if package:
            adb("shell", "am", "force-stop", package, check=False)
        adb(
            "shell", "rm", "-f", "/data/local/tmp/library_shell_profile_ui.xml",
            check=False,
        )
        if frame_report.is_file():
            frame_report.unlink()


if __name__ == "__main__":
    main()
