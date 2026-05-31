import contextlib
import base64
import json
import os
import re
import runpy
import sys
import traceback
import html as html_lib
from urllib.parse import parse_qs, urlencode, urljoin, urlparse
from urllib.request import Request, urlopen

from .args import (
    build_preset_args,
    has_custom_output_template,
    parse_custom_args,
    parse_extra_args,
    parse_preset_args_map,
    strip_checkbox_owned_download_args,
)
from .ffmpeg_bridge import (
    SwiftFFmpegBridge,
    YTDLPFFmpegBridgeAdapter,
    is_cancel_requested,
    patch_ytdlp_for_swiftffmpeg,
)
from .files import cleanup_temp_download_files, detect_downloaded_files, has_primary_media_file
from .packages import (
    build_package_install_plan,
    check_package_updates,
    cleanup_target_package,
    collect_versions,
    ensure_pip_entrypoint,
    fetch_package_index_versions,
    is_package_installed,
)
from .shared import TRACKED_PACKAGES, TailBuffer, Tee, open_live_log_stream
from .webkit_jsi import ensure_safe_webkit_jsi_runtime

PLAYLIST_PROGRESS_PREFIX = "[palladium][playlist-progress] "
MIN_YTDLP_VERSION = "2026.03.17"
DEFAULT_BROWSER_USER_AGENT = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 "
    "Mobile/15E148 Safari/604.1"
)
XHAMSTER_PAGE_HOSTS = (
    "xhamster.com",
    "xhamster.desi",
    "xhamster.xxx",
)
YOUTUBE_HOSTS = (
    "youtube.com",
    "m.youtube.com",
    "music.youtube.com",
    "youtu.be",
)
GENZ3X_PAGE_HOSTS = (
    "genz3x.com",
    "clipphimsex3x.net",
    "clipsexsub3x.net",
)
GENZ3X_PLAYER_HOSTS = (
    "play2.cdn-xvideos-xnxx.xyz",
    "xcdnx.cdn-xvideos-xnxx.xyz",
)
SEXTOP1_PAGE_HOSTS = (
    "sextop1.cl",
)
AVPLE_PAGE_HOSTS = (
    "avple.tv",
)
AVPLE_ASSERT_HOSTS = (
    "d862cp1.cdnedge.live",
    "q2cyl71.cdnedge.live",
    "u89ey1.cdnedge.live",
    "zo3921.cdnedge.live",
    "wo8801.cdnedge.live",
    "6m7d1.cdnedge.live",
    "8bb881.cdnedge.live",
    "fa6781.cdnedge.live",
    "pg2z71.cdnedge.live",
    "1xp601.cdnedge.live",
)
KUBHD_PAGE_HOSTS = (
    "kubhd24.net",
)
KUBHD_PLAYER_HOSTS = (
    "hplay.hdplayfull.xyz",
)
ANIME108_PAGE_HOSTS = (
    "anime108.com",
)
ANIME108_PLAYER_HOSTS = (
    "main.108player.com",
)
CLOUDBETA_PLAYER_HOSTS = (
    "cloudbeta.win",
)
MEEPLAYER_HOSTS = (
    "meeplayer.com",
    "player2.meeplayer.com",
)


class PlaylistProgressCollector:
    playlist_title_pattern = re.compile(r"^\[download\] Downloading playlist: (?P<title>.+)$")
    playlist_count_pattern = re.compile(
        r"^\[(?:youtube:tab|download)\].*Downloading (?P<count>\d+) items? of (?P<total>\d+)$"
    )
    playlist_item_pattern = re.compile(r"^\[download\] Downloading item (?P<index>\d+) of (?P<total>\d+)$")
    item_url_pattern = re.compile(r"^\[[^\]]+\] Extracting URL: (?P<url>.+)$")
    destination_pattern = re.compile(r"^\[(?:download|ExtractAudio)\] Destination: (?P<path>.+)$")

    def __init__(self, live_log_stream=None):
        self.live_log_stream = live_log_stream
        self.pending_line = ""
        self.playlist_title = None
        self.playlist_expected_count = None
        self.playlist_completed_count = 0
        self.playlist_failed_count = 0
        self.playlist_failed_items = []
        self.failed_item_records = []
        self.current_item_index = None
        self.current_item_title = None
        self.current_item_url = None
        self.current_item_paths = set()
        self.current_item_had_error = False
        self.current_item_error_line = None
        self.is_playlist_run = False
        self.last_emitted_payload = None
        self.suspend_tracking = False

    def write(self, data):
        text = str(data)
        if not text:
            return 0

        if self.suspend_tracking:
            return len(text)

        normalized = text.replace("\r\n", "\n").replace("\r", "\n")
        combined = self.pending_line + normalized
        lines = combined.split("\n")
        if normalized.endswith("\n"):
            self.pending_line = ""
        else:
            self.pending_line = lines.pop() if lines else combined

        for line in lines:
            self._handle_line(line.strip())

        return len(text)

    def flush(self):
        return None

    def finalize(self, cancelled=False):
        if self.pending_line:
            self._handle_line(self.pending_line.strip())
            self.pending_line = ""
        self._finalize_current_item(aborted=cancelled)

    def result_kind(self, success, cancelled):
        if cancelled:
            return "cancelled"

        if not self.is_playlist_run:
            return "success" if success else "error"

        completed = self.playlist_completed_count
        failed = self.playlist_failed_count

        if completed > 0 and failed > 0:
            return "partial"
        if completed > 0 and failed == 0:
            return "success"
        return "error"

    def snapshot(self, result_kind=None):
        return {
            "playlist_title": self.playlist_title,
            "playlist_expected_count": self.playlist_expected_count,
            "playlist_completed_count": self.playlist_completed_count,
            "playlist_failed_count": self.playlist_failed_count,
            "playlist_failed_items": list(self.playlist_failed_items),
            "current_item_index": self.current_item_index,
            "current_item_title": self.current_item_title,
            "result_kind": result_kind,
        }

    def _handle_line(self, line):
        if not line:
            return

        playlist_title_match = self.playlist_title_pattern.match(line)
        if playlist_title_match:
            self.is_playlist_run = True
            self.playlist_title = playlist_title_match.group("title").strip() or None
            self._emit()
            return

        playlist_count_match = self.playlist_count_pattern.match(line)
        if playlist_count_match:
            self.is_playlist_run = True
            self.playlist_expected_count = int(playlist_count_match.group("total"))
            self._emit()
            return

        playlist_item_match = self.playlist_item_pattern.match(line)
        if playlist_item_match:
            self._finalize_current_item()
            self.is_playlist_run = True
            self.current_item_index = int(playlist_item_match.group("index"))
            self.playlist_expected_count = int(playlist_item_match.group("total"))
            self.current_item_title = None
            self.current_item_url = None
            self.current_item_paths = set()
            self.current_item_had_error = False
            self.current_item_error_line = None
            self._emit()
            return

        item_url_match = self.item_url_pattern.match(line)
        if item_url_match and self.current_item_index is not None:
            self.current_item_url = item_url_match.group("url").strip() or None
            return

        destination_match = self.destination_pattern.match(line)
        if destination_match and self.current_item_index is not None:
            path = destination_match.group("path").strip()
            if path:
                self.current_item_paths.add(path)
                guessed_title = self._title_from_path(path)
                if guessed_title:
                    self.current_item_title = guessed_title
                    self._emit()
            return

        if line.startswith("ERROR:") and self.current_item_index is not None:
            self.current_item_had_error = True
            self.current_item_error_line = line
            self._emit()

    def _finalize_current_item(self, aborted=False):
        if self.current_item_index is None:
            return

        if not aborted:
            has_output = any(self._path_exists(path) for path in self.current_item_paths)
            if has_output:
                self.playlist_completed_count += 1
            else:
                self._record_failed_item()

        self.current_item_index = None
        self.current_item_title = None
        self.current_item_url = None
        self.current_item_paths = set()
        self.current_item_had_error = False
        self.current_item_error_line = None
        self._emit()

    def retry_candidates(self):
        return [dict(record) for record in self.failed_item_records if self._is_thumbnail_failure(record.get("error_line"))]

    def mark_retry_success(self, item_index):
        updated_records = []
        removed_count = 0
        for record in self.failed_item_records:
            if record.get("index") == item_index:
                removed_count += 1
                continue
            updated_records.append(record)

        if removed_count == 0:
            return

        self.failed_item_records = updated_records
        self.playlist_failed_count = max(0, self.playlist_failed_count - removed_count)
        self.playlist_completed_count += removed_count
        self._rebuild_failed_items()
        self._emit()

    def mark_retry_failed(self, item_index, error_line):
        for record in self.failed_item_records:
            if record.get("index") != item_index:
                continue
            if error_line:
                record["error_line"] = error_line
            break
        self._rebuild_failed_items()
        self._emit()

    def _record_failed_item(self):
        self.playlist_failed_count += 1
        failed_label = self.current_item_title or f"Item {self.current_item_index}"
        if self.current_item_error_line:
            failed_label = f"{failed_label}: {self.current_item_error_line}"
        self.playlist_failed_items.append(failed_label)
        self.failed_item_records.append({
            "index": self.current_item_index,
            "title": self.current_item_title,
            "url": self.current_item_url,
            "error_line": self.current_item_error_line,
        })

    def _rebuild_failed_items(self):
        labels = []
        for record in self.failed_item_records:
            failed_label = record.get("title") or f"Item {record.get('index')}"
            if record.get("error_line"):
                failed_label = f"{failed_label}: {record['error_line']}"
            labels.append(failed_label)
        self.playlist_failed_items = labels

    def _is_thumbnail_failure(self, error_line):
        if not error_line:
            return False
        lower = error_line.lower()
        return (
            "thumbnail" in lower
            or "thumbnails" in lower
            or "embed-thumbnail" in lower
            or "convert-thumbnails" in lower
            or ".webp" in lower
            or ".png" in lower
        )

    def set_tracking_suspended(self, suspended):
        self.suspend_tracking = bool(suspended)

    def _emit(self):
        if self.live_log_stream is None:
            return

        payload = self.snapshot()
        encoded_payload = json.dumps(payload, ensure_ascii=False, sort_keys=True)
        if encoded_payload == self.last_emitted_payload:
            return

        self.last_emitted_payload = encoded_payload
        try:
            self.live_log_stream.write(f"{PLAYLIST_PROGRESS_PREFIX}{encoded_payload}\n")
            self.live_log_stream.flush()
        except Exception:
            pass

    def _path_exists(self, path):
        try:
            return os.path.isfile(path) and os.path.getsize(path) > 0
        except Exception:
            return False

    def _title_from_path(self, path):
        file_name = os.path.splitext(os.path.basename(path))[0].strip()
        if not file_name:
            return None

        cleaned = re.sub(r"^\d+\s+-\s+", "", file_name).strip()
        return cleaned or file_name


def raise_if_cancel_requested(cancel_file_path, message):
    if is_cancel_requested(cancel_file_path):
        print(message)
        raise KeyboardInterrupt("cancel requested")


def without_thumbnail_download_args(download_behavior_args):
    result = []
    skip_next = False
    for arg in download_behavior_args:
        if skip_next:
            skip_next = False
            continue
        if arg == "--convert-thumbnails":
            skip_next = True
            continue
        if arg == "--embed-thumbnail":
            continue
        result.append(arg)
    return result


def extract_last_error_line(output):
    lines = [line.strip() for line in str(output).splitlines() if line.strip().startswith("ERROR:")]
    return lines[-1] if lines else None


def sanitize_output_title_hint(value):
    text = str(value or "").strip()
    if not text:
        return None

    text = re.sub(r"\s+", " ", text)
    text = re.sub(r"[\x00-\x1f/\\?%*:|\"<>]", " ", text)
    text = re.sub(r"\.(m3u8|mpd|mp4|m4v|mov|webm|ts)$", "", text, flags=re.IGNORECASE)
    text = re.sub(r"\s+", " ", text).strip(" ._-")
    if not text:
        return None

    blocked_titles = {
        "video",
        "download",
        "untitled",
        "document",
        "home",
    }
    if text.lower() in blocked_titles:
        return None

    return text[:160].strip(" ._-") or None


def run_retry_without_thumbnails(
    retry_candidate,
    download_url,
    run_output_dir,
    cache_dir,
    download_playlist,
    output_args,
    download_behavior_args,
    site_specific_args,
    preset_args,
    extra_args,
    bridge_adapter,
):
    item_index = retry_candidate.get("index")
    if item_index is None:
        return False, "ERROR: retry skipped because playlist item index was missing"

    retry_behavior_args = without_thumbnail_download_args(download_behavior_args)
    retry_url = download_url
    retry_args = [
        "yt-dlp",
        "-v",
        "--no-check-certificate",
        "--remote-components",
        "ejs:github",
        "--cache-dir",
        cache_dir if cache_dir else os.path.join(".", ".cache"),
        "--continue",
        "-P",
        run_output_dir if run_output_dir else ".",
        *output_args,
        *retry_behavior_args,
        *site_specific_args,
        *preset_args,
        *extra_args,
    ]

    if download_playlist:
        retry_args.extend(["--playlist-items", str(item_index)])
    retry_args.append(retry_url)

    sys.argv = retry_args
    try:
        with patch_ytdlp_for_swiftffmpeg(bridge_adapter):
            runpy.run_module("yt_dlp", run_name="__main__", alter_sys=True)
        return True, None
    except SystemExit as exc:
        if exc.code in (None, 0):
            return True, None
        return False, f"ERROR: retry without thumbnails failed with exit code {exc.code}"
    except Exception:
        traceback.print_exc()
        return False, extract_last_error_line(traceback.format_exc()) or "ERROR: retry without thumbnails failed"


def has_generic_impersonation_arg(extra_args_text):
    if not extra_args_text:
        return False
    return "generic:impersonate" in str(extra_args_text)


def normalized_url_host(value):
    try:
        host = urlparse(str(value or "").strip()).hostname or ""
    except Exception:
        return ""
    return host.lower().removeprefix("www.")


def is_xhamster_page_url(value):
    host = normalized_url_host(value)
    if not host:
        return False
    return any(host == domain or host.endswith(f".{domain}") for domain in XHAMSTER_PAGE_HOSTS)


def is_youtube_url(value):
    host = normalized_url_host(value)
    if not host:
        return False
    return any(host == domain or host.endswith(f".{domain}") for domain in YOUTUBE_HOSTS)


def is_genz3x_page_url(value):
    host = normalized_url_host(value)
    if not host:
        return False
    return any(host == domain or host.endswith(f".{domain}") for domain in GENZ3X_PAGE_HOSTS)


def is_genz3x_player_url(value):
    host = normalized_url_host(value)
    if not host:
        return False
    return any(host == domain or host.endswith(f".{domain}") for domain in GENZ3X_PLAYER_HOSTS)


def is_sextop1_page_url(value):
    host = normalized_url_host(value)
    if not host:
        return False
    return any(host == domain or host.endswith(f".{domain}") for domain in SEXTOP1_PAGE_HOSTS)


def is_avple_page_url(value):
    host = normalized_url_host(value)
    if not host:
        return False
    return any(host == domain or host.endswith(f".{domain}") for domain in AVPLE_PAGE_HOSTS)


def is_kubhd_page_url(value):
    host = normalized_url_host(value)
    if not host:
        return False
    return any(host == domain or host.endswith(f".{domain}") for domain in KUBHD_PAGE_HOSTS)


def is_kubhd_player_url(value):
    host = normalized_url_host(value)
    if not host:
        return False
    path = urlparse(str(value or "")).path.lower()
    return (
        any(host == domain or host.endswith(f".{domain}") for domain in KUBHD_PLAYER_HOSTS)
        or (("hplay" in host or "hdplayfull" in host) and "/embed/" in path)
    )


def is_anime108_page_url(value):
    host = normalized_url_host(value)
    if not host:
        return False
    return any(host == domain or host.endswith(f".{domain}") for domain in ANIME108_PAGE_HOSTS)


def is_anime108_player_url(value):
    host = normalized_url_host(value)
    if not host:
        return False
    return any(host == domain or host.endswith(f".{domain}") for domain in ANIME108_PLAYER_HOSTS)


def is_cloudbeta_player_url(value):
    host = normalized_url_host(value)
    if not host:
        return False
    path = urlparse(str(value or "")).path.lower()
    return any(host == domain or host.endswith(f".{domain}") for domain in CLOUDBETA_PLAYER_HOSTS) and "/embed/" in path


def is_meeplayer_url(value):
    host = normalized_url_host(value)
    if not host:
        return False
    path = urlparse(str(value or "")).path.lower()
    return any(host == domain or host.endswith(f".{domain}") for domain in MEEPLAYER_HOSTS) and (
        "/play/" in path or "/p2p/" in path or "/p2p-hls/" in path
    )


def argv_contains_option(args, option):
    for arg in args:
        text = str(arg)
        if text == option or text.startswith(f"{option}="):
            return True
    return False


def argv_contains_text(args, needle):
    needle_text = str(needle)
    return any(needle_text in str(arg) for arg in args)


def fetch_site_text(url, referer=None):
    headers = {
        "User-Agent": DEFAULT_BROWSER_USER_AGENT,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9,vi;q=0.8",
    }
    if referer:
        headers["Referer"] = referer

    request = Request(url, headers=headers)
    with urlopen(request, timeout=30) as response:
        body = response.read()
        charset = response.headers.get_content_charset() or "utf-8"
    return body.decode(charset, errors="replace")


def post_site_text(url, data, referer=None):
    headers = {
        "User-Agent": DEFAULT_BROWSER_USER_AGENT,
        "Accept": "application/json,text/javascript,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9,vi;q=0.8",
        "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        "X-Requested-With": "XMLHttpRequest",
    }
    if referer:
        headers["Referer"] = referer

    request = Request(url, data=urlencode(data).encode("utf-8"), headers=headers, method="POST")
    with urlopen(request, timeout=30) as response:
        body = response.read()
        charset = response.headers.get_content_charset() or "utf-8"
    return body.decode(charset, errors="replace")


def fetch_site_text_impersonated(url, referer=None):
    headers = {
        "User-Agent": DEFAULT_BROWSER_USER_AGENT,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "en-US,en;q=0.9,vi;q=0.8",
    }
    if referer:
        headers["Referer"] = referer

    try:
        from curl_cffi import requests as curl_requests
        curl_headers = {key: value for key, value in headers.items() if key.lower() != "user-agent"}
        response = curl_requests.get(url, headers=curl_headers, impersonate="chrome120", timeout=30)
        response.raise_for_status()
        return response.text
    except Exception as error:
        print(f"[palladium] impersonated fetch fallback: {error}")
        return fetch_site_text(url, referer=referer)


def first_matching_url(candidates, base_url=None, predicate=None):
    for raw_candidate in candidates:
        candidate = html_lib.unescape(str(raw_candidate or "").strip()).replace("\\/", "/")
        if not candidate or candidate == "about:blank":
            continue
        if base_url:
            candidate = urljoin(base_url, candidate)
        if predicate is None or predicate(candidate):
            return candidate
    return None


def unescape_js_text(value):
    text = str(value or "")
    text = (
        text.replace("\\/", "/")
        .replace("\\u0026", "&")
        .replace("\\u003d", "=")
        .replace("\\u003f", "?")
        .replace("\\u002f", "/")
        .replace("\\u002F", "/")
    )

    def replace_unicode(match):
        try:
            return chr(int(match.group(1), 16))
        except Exception:
            return match.group(0)

    text = re.sub(r"\\u([0-9a-fA-F]{4})", replace_unicode, text)
    text = re.sub(r"\\x([0-9a-fA-F]{2})", replace_unicode, text)
    return text


def maybe_decode_base64_text(value):
    text = str(value or "").strip().replace("-", "+").replace("_", "/")
    if len(text) < 16 or len(text) > 12000:
        return None
    remainder = len(text) % 4
    if remainder == 1:
        return None
    if remainder:
        text += "=" * (4 - remainder)
    try:
        decoded = base64.b64decode(text, validate=False).decode("utf-8", errors="replace")
    except Exception:
        return None
    if re.search(r"(https?:)?//|m3u8|mpd|iframe|source|file|playlist|manifest|player|embed", decoded, re.IGNORECASE):
        return decoded
    return None


def add_text_variant(variants, seen, value):
    text = str(value or "")
    if not text.strip():
        return
    if len(text) > 3000000:
        text = text[:3000000]
    if text in seen:
        return
    seen.add(text)
    variants.append(text)


def text_scan_variants(text):
    variants = []
    seen = set()
    add_text_variant(variants, seen, text)
    try:
        add_text_variant(variants, seen, html_lib.unescape(str(text or "")))
    except Exception:
        pass
    add_text_variant(variants, seen, unescape_js_text(text))
    try:
        from urllib.parse import unquote
        add_text_variant(variants, seen, unquote(str(text or "")))
    except Exception:
        pass

    for scan in list(variants):
        try:
            add_text_variant(variants, seen, unescape_js_text(html_lib.unescape(scan)))
        except Exception:
            pass
        try:
            from urllib.parse import unquote
            add_text_variant(variants, seen, unescape_js_text(unquote(scan)))
        except Exception:
            pass

        joined = re.sub(
            r'(["\'])([^"\']{1,500})\1\s*\+\s*(["\'])([^"\']{1,500})\3',
            lambda match: f'"{match.group(2)}{match.group(4)}"',
            scan,
        )
        add_text_variant(variants, seen, joined)

        for match in re.finditer(r'decodeURIComponent\s*\(\s*["\']([^"\']+)["\']\s*\)', scan, flags=re.IGNORECASE):
            try:
                from urllib.parse import unquote
                add_text_variant(variants, seen, unquote(match.group(1)))
            except Exception:
                pass

        for match in re.finditer(r'atob\s*\(\s*["\']([A-Za-z0-9+/_=-]{16,})["\']\s*\)', scan, flags=re.IGNORECASE):
            decoded = maybe_decode_base64_text(match.group(1))
            if decoded:
                add_text_variant(variants, seen, decoded)

    base64_count = 0
    for scan in list(variants):
        for match in re.finditer(r"(?<![A-Za-z0-9+/_=-])([A-Za-z0-9+/_=-]{40,12000})(?![A-Za-z0-9+/_=-])", scan):
            if base64_count >= 12 or len(variants) >= 24:
                break
            decoded = maybe_decode_base64_text(match.group(1))
            if decoded:
                base64_count += 1
                add_text_variant(variants, seen, decoded)

    return variants


def is_crawler_blocked_url(value):
    text = str(value or "").lower()
    if not text:
        return True
    blocked = (
        r"wp-json/oembed|/oembed|__cf_chl_|google-analytics|googletagmanager|doubleclick|"
        r"facebook\.com|twitter\.com|x\.com/|telegram|t\.me/|line\.me|cdn-cgi/rum|"
        r"/ads?|banner|popunder|histats|yandex\.ru/metrika|"
        r"\.(css|js|png|jpe?g|gif|webp|svg|ico|woff2?|ttf|otf|eot)(\?|#|$)"
    )
    return re.search(blocked, text, flags=re.IGNORECASE) is not None


def generic_media_kind(value, content_type=""):
    url = str(value or "").lower()
    ctype = str(content_type or "").lower()
    if url.startswith("blob:"):
        return "blob"
    if re.search(r"https?://[^/]*(hplay|hdplayfull)[^/]*/embed/", url):
        return "player"
    if re.search(r"https?://[^/]*cloudbeta\.win/embed/", url):
        return "player"
    if is_anime108_player_url(value) or is_meeplayer_url(value) or is_genz3x_player_url(value):
        return "player"
    if re.search(r"/(?:hlsr2|hls|m3u8|m3u8_g|newplaylist|newplaylist_g)/.*(?:/master|/playlist|/index)(\?|#|$)", url):
        return "hls"
    if re.search(r"\.m3u8(\?|#|$)", url) or "mpegurl" in ctype:
        return "hls"
    if re.search(r"\.mpd(\?|#|$)", url) or "dash" in ctype:
        return "dash"
    match = re.search(r"\.(mp4|m4v|webm|mkv|mov|avi|wmv|flv|f4v|3gp|3g2|ts|m2ts|mts|ogv|aac|mp3)(\?|#|$)", url)
    if match:
        return match.group(1)
    if ctype.startswith("video/"):
        return ctype[6:].split(";", 1)[0]
    if ctype.startswith("audio/"):
        return "audio-" + ctype[6:].split(";", 1)[0]
    if "octet-stream" in ctype or "attachment" in ctype or "filename=" in ctype:
        return "file"
    return ""


def is_likely_media_candidate(value, content_type=""):
    if not value or is_crawler_blocked_url(value):
        return False
    if re.search(r"googleads|doubleclick|googlesyndication|pagead|adservice|adnxs|taboola|outbrain", str(value), re.IGNORECASE):
        return False
    kind = generic_media_kind(value, content_type)
    return bool(kind and not kind.startswith("audio-") and kind != "blob")


def is_likely_player_page(value, content_type=""):
    if not value or is_crawler_blocked_url(value) or is_likely_media_candidate(value, content_type):
        return False
    lower = str(value or "").lower()
    return (
        re.search(r"\.(html?|php|aspx?)(\?|#|$)", lower) and re.search(r"player|embed|iframe|source|server|stream|watch|play|video", lower)
    ) or re.search(r"^https?://[^/]*(player|embed|stream|video|watch|play|hls|cdn)[^/]*/", lower) or re.search(
        r"/(?:player|embed|iframe|source|server|stream|watch|play|video)(?:/|\?|#|$)", lower
    )


def normalize_candidate_url(value, base_url):
    candidate = html_lib.unescape(str(value or "").strip())
    candidate = unescape_js_text(candidate).strip().strip('"\'')
    candidate = candidate.rstrip(",)]};")
    if not candidate or candidate == "about:blank":
        return ""
    if candidate.startswith("//"):
        scheme = urlparse(base_url).scheme or "https"
        candidate = f"{scheme}:{candidate}"
    elif not re.match(r"^[a-zA-Z][a-zA-Z0-9+\-.]*:", candidate):
        candidate = urljoin(base_url, candidate)
    if not candidate.startswith(("http://", "https://")):
        return ""
    return candidate


def extract_scan_candidates(text, base_url):
    candidates = []
    seen = set()
    if not text:
        return candidates
    if len(str(text)) > 3000000:
        text = str(text)[:3000000]

    patterns = [
        r"(?:https?:)?//[^\s'\"<>\\]+",
        r"(?:src|href|file|url|source|sources|playlist|manifest|hls|dash|mpd|m3u8|video_url|videoUrl|manifestUrl|data-file|data-url|data-src|data-href|data-item|data-config|data-fv|data-options|iframe|embed|player|server|html)\s*[:=]\s*[\"']([^\"']+)[\"']",
        r"[\"'](/[^\"'<>\s\\]*(?:m3u8|mpd|hls|playlist|manifest|newplaylist|embed|player|stream|video|api/get\.php|zip|rar|7z|tar|gz|tgz|bz2|xz|pdf|docx?|xlsx?|pptx?|rtf|txt|csv|exe|msi|apk|ipa|dmg|pkg|deb|rpm|iso|img|bin|torrent|epub|mobi|srt|vtt|ass|ssa|nfo)[^\"'<>\s\\]*)[\"']",
    ]
    for scan in text_scan_variants(text):
        for pattern in patterns:
            for match in re.finditer(pattern, scan, flags=re.IGNORECASE):
                raw = match.group(1) if match.groups() else match.group(0)
                candidate = normalize_candidate_url(raw, base_url)
                if not candidate or candidate in seen:
                    continue
                if is_likely_media_candidate(candidate) or is_likely_player_page(candidate):
                    seen.add(candidate)
                    candidates.append(candidate)
    return candidates


def candidate_score(value):
    lower = str(value or "").lower()
    if re.search(r"\.m3u8(\?|#|$)|/newplaylist|/m3u8|/hlsr2|/hls/", lower):
        return 100
    if re.search(r"\.mp4(\?|#|$)", lower):
        return 90
    if generic_media_kind(value) == "player":
        return 80
    if is_likely_media_candidate(value):
        return 70
    if is_likely_player_page(value):
        return 40
    return 0


def resolve_known_player_candidate(candidate, referer):
    resolvers = (
        resolve_genz3x_download_url,
        resolve_kubhd_download_url,
        resolve_anime108_download_url,
        resolve_cloudbeta_download_url,
        resolve_meeplayer_download_url,
    )
    for resolver in resolvers:
        resolved_url, resolved_args, profile = resolver(candidate)
        if profile and resolved_url and resolved_url != candidate:
            return resolved_url, resolved_args, profile
    return None, [], None


def extract_genz3x_embed_url(page_html, page_url):
    patterns = [
        r'<meta[^>]+itemprop=["\']embedURL["\'][^>]+content=["\']([^"\']+)["\']',
        r'<meta[^>]+content=["\']([^"\']+)["\'][^>]+itemprop=["\']embedURL["\']',
        r'<iframe[^>]+data-src=["\']([^"\']+)["\']',
        r'<iframe[^>]+src=["\']([^"\']+)["\']',
    ]
    candidates = []
    for pattern in patterns:
        candidates.extend(re.findall(pattern, page_html, flags=re.IGNORECASE))
    return first_matching_url(
        candidates,
        base_url=page_url,
        predicate=lambda candidate: is_genz3x_player_url(candidate) or "embed" in urlparse(candidate).path.lower(),
    )


def extract_first_m3u8_url(player_html):
    normalized_html = str(player_html or "").replace("\\/", "/")
    matches = re.findall(r'https?://[^"\'<>\s]+?\.m3u8(?:\?[^"\'<>\s]+)?', normalized_html, flags=re.IGNORECASE)
    return first_matching_url(matches)


def extract_first_media_url(player_html):
    normalized_html = str(player_html or "").replace("\\/", "/")
    patterns = [
        r'https?://[^"\'<>\s]+?\.m3u8(?:\?[^"\'<>\s]+)?',
        r'https?://[^"\'<>\s]+?\.mp4(?:\?[^"\'<>\s]+)?',
        r'["\']file["\']\s*:\s*["\']([^"\']+)["\']',
        r'file\s*:\s*["\']([^"\']+)["\']',
    ]
    candidates = []
    for pattern in patterns:
        candidates.extend(re.findall(pattern, normalized_html, flags=re.IGNORECASE))
    return first_matching_url(candidates)


def resolve_genz3x_download_url(download_url):
    if not (is_genz3x_page_url(download_url) or is_genz3x_player_url(download_url)):
        return download_url, [], None

    try:
        if is_genz3x_player_url(download_url):
            embed_url = download_url
            page_url = download_url
        else:
            print("[palladium] site profile resolving: genz3x page")
            page_url = download_url
            page_html = fetch_site_text_impersonated(page_url)
            embed_url = extract_genz3x_embed_url(page_html, page_url)
            if not embed_url:
                print("[palladium] genz3x resolver: no embed iframe found")
                return download_url, [], "genz3x"

        print(f"[palladium] genz3x resolver iframe: {embed_url}")
        player_html = fetch_site_text_impersonated(embed_url, referer=page_url)
        media_url = extract_first_media_url(player_html)
        if not media_url:
            print("[palladium] genz3x resolver: no media URL found in iframe")
            return download_url, [], "genz3x"

        print(f"[palladium] genz3x resolver media: {media_url}")
        return media_url, ["--referer", embed_url, "--user-agent", DEFAULT_BROWSER_USER_AGENT], "genz3x"
    except Exception as error:
        print(f"[palladium] genz3x resolver failed: {error}")
        return download_url, [], "genz3x"


def extract_sextop1_post_id(page_html):
    patterns = [
        r'<div[^>]+id=["\']video["\'][^>]+data-id=["\'](\d+)["\']',
        r'<div[^>]+data-id=["\'](\d+)["\'][^>]+id=["\']video["\']',
        r'postid-(\d+)',
    ]
    for pattern in patterns:
        match = re.search(pattern, page_html, flags=re.IGNORECASE)
        if match:
            return match.group(1)
    return None


def resolve_sextop1_download_url(download_url):
    if not is_sextop1_page_url(download_url):
        return download_url, [], None

    try:
        print("[palladium] site profile resolving: sextop1 page")
        page_html = fetch_site_text(download_url)
        post_id = extract_sextop1_post_id(page_html)
        if not post_id:
            print("[palladium] sextop1 resolver: no post id found")
            return download_url, [], "sextop1"

        player_url = urljoin(download_url, f"/wp-json/sextop1/player/?id={post_id}&server=1")
        print(f"[palladium] sextop1 resolver api: {player_url}")
        player_json_text = fetch_site_text(player_url, referer=download_url)
        try:
            player_payload = json.loads(player_json_text)
            player_html = str(player_payload.get("data", ""))
        except Exception:
            player_html = player_json_text

        media_url = extract_first_m3u8_url(player_html)
        if not media_url:
            print("[palladium] sextop1 resolver: no m3u8 found in API response")
            return download_url, [], "sextop1"

        print(f"[palladium] sextop1 resolver media: {media_url}")
        return media_url, ["--referer", download_url, "--user-agent", DEFAULT_BROWSER_USER_AGENT], "sextop1"
    except Exception as error:
        print(f"[palladium] sextop1 resolver failed: {error}")
        return download_url, [], "sextop1"


def extract_next_data_json(page_html):
    match = re.search(
        r'<script[^>]+id=["\']__NEXT_DATA__["\'][^>]*>(.*?)</script>',
        page_html,
        flags=re.IGNORECASE | re.DOTALL,
    )
    if not match:
        return None
    text = html_lib.unescape(match.group(1)).strip()
    if not text:
        return None
    return json.loads(text)


def avple_media_url(play_source_type, play_path):
    play_path = str(play_path or "").strip().lstrip("/")
    if not play_path:
        return None

    try:
        source_type = int(play_source_type)
    except Exception:
        source_type = None

    if source_type == 5 or play_path.startswith("http://") or play_path.startswith("https://"):
        return play_path
    if source_type in (12, 13, 14, 17, 18):
        return f"https://{AVPLE_ASSERT_HOSTS[0]}/file/avple-asserts/{play_path}"
    return f"https://{AVPLE_ASSERT_HOSTS[0]}/file/avple-asserts/{play_path}"


def resolve_avple_download_url(download_url):
    if not is_avple_page_url(download_url):
        return download_url, [], None

    try:
        print("[palladium] site profile resolving: avple page")
        page_html = fetch_site_text_impersonated(download_url)
        next_data = extract_next_data_json(page_html)
        page_props = (((next_data or {}).get("props") or {}).get("pageProps") or {})
        instance = page_props.get("instance")
        data = page_props.get("data")
        video_record = instance if isinstance(instance, dict) else data[0] if isinstance(data, list) and data else data if isinstance(data, dict) else {}
        media_url = avple_media_url(video_record.get("play_source_type"), video_record.get("play"))
        if not media_url:
            print("[palladium] avple resolver: no playable source found")
            return download_url, [], "avple"

        print(f"[palladium] avple resolver media: {media_url}")
        return media_url, ["--referer", download_url, "--user-agent", DEFAULT_BROWSER_USER_AGENT], "avple"
    except Exception as error:
        print(f"[palladium] avple resolver failed: {error}")
        return download_url, [], "avple"


def extract_kubhd_uni_config(page_html):
    script_candidates = []
    for encoded in re.findall(
        r'<script[^>]+id=["\']uni-js-player-js-extra["\'][^>]+src=["\']data:text/javascript;base64,([^"\']+)["\']',
        page_html,
        flags=re.IGNORECASE,
    ):
        try:
            script_candidates.append(base64.b64decode(encoded).decode("utf-8", errors="replace"))
        except Exception:
            continue
    script_candidates.append(page_html)

    for script_text in script_candidates:
        match = re.search(r"var\s+_uni\s*=\s*(\{.*?\})\s*;?", script_text, flags=re.IGNORECASE | re.DOTALL)
        if not match:
            continue
        try:
            return json.loads(match.group(1))
        except Exception:
            continue
    return {}


def extract_kubhd_player_url(player_html, page_url):
    patterns = [
        r'<iframe[^>]+src=["\']([^"\']+)["\']',
        r'<button[^>]+data-src=["\']([^"\']+)["\']',
        r'data-src=["\']([^"\']+)["\']',
    ]
    candidates = []
    for pattern in patterns:
        candidates.extend(re.findall(pattern, player_html, flags=re.IGNORECASE))
    return first_matching_url(candidates, base_url=page_url, predicate=is_kubhd_player_url)


def extract_kubhd_player_config(player_html):
    match = re.search(
        r"window\.playerConfig\s*=\s*(\{.*?\})\s*;\s*</script>",
        player_html,
        flags=re.IGNORECASE | re.DOTALL,
    )
    if not match:
        return {}
    try:
        return json.loads(match.group(1))
    except Exception:
        return {}


def kubhd_embed_id(embed_url):
    path_parts = [part for part in urlparse(embed_url).path.split("/") if part]
    if len(path_parts) >= 2 and path_parts[-2].lower() == "embed":
        candidate = path_parts[-1]
        if re.fullmatch(r"[A-Za-z0-9_-]{1,100}", candidate):
            return candidate
    return None


def resolve_kubhd_download_url(download_url):
    if not (is_kubhd_page_url(download_url) or is_kubhd_player_url(download_url)):
        return download_url, [], None

    try:
        if is_kubhd_player_url(download_url):
            page_url = download_url
            embed_url = download_url
        else:
            print("[palladium] site profile resolving: kubhd page")
            page_url = download_url
            page_html = fetch_site_text(page_url)
            config = extract_kubhd_uni_config(page_html)
            ajax_url = str(config.get("ajax_url") or urljoin(page_url, "/wp-admin/admin-ajax.php"))
            post_id = str(config.get("post_id") or "").strip()
            nonce = str(config.get("nonce") or "").strip()
            if not post_id or not nonce:
                print("[palladium] kubhd resolver: no ajax post id/nonce found")
                return download_url, [], "kubhd"

            print(f"[palladium] kubhd resolver ajax: {ajax_url}")
            player_response = post_site_text(
                ajax_url,
                {"action": "mix_get_player", "post_id": post_id, "nonce": nonce},
                referer=page_url,
            )
            try:
                player_payload = json.loads(player_response)
                player_html = str(player_payload.get("player", ""))
            except Exception:
                player_html = player_response

            embed_url = extract_kubhd_player_url(player_html, page_url)
            if not embed_url:
                print("[palladium] kubhd resolver: no hplay iframe found")
                return download_url, [], "kubhd"

        print(f"[palladium] kubhd resolver iframe: {embed_url}")
        player_html = fetch_site_text(embed_url, referer=page_url)
        player_config = extract_kubhd_player_config(player_html)
        asset_host = str(player_config.get("asset") or "media.vdohls.com").strip().strip("/")
        if "://" in asset_host:
            asset_url_base = asset_host
        else:
            asset_url_base = f"https://{asset_host}"
        video_id = kubhd_embed_id(embed_url)
        if not video_id:
            print("[palladium] kubhd resolver: no embed id found")
            return download_url, [], "kubhd"

        media_url = f"{asset_url_base}/{video_id}/playlist.m3u8"
        print(f"[palladium] kubhd resolver media: {media_url}")
        return media_url, ["--referer", embed_url, "--user-agent", DEFAULT_BROWSER_USER_AGENT], "kubhd"
    except Exception as error:
        print(f"[palladium] kubhd resolver failed: {error}")
        return download_url, [], "kubhd"


def extract_anime108_config(page_html):
    match = re.search(r"var\s+halim_cfg\s*=\s*(\{.*?\})\s*;", page_html, flags=re.IGNORECASE | re.DOTALL)
    if not match:
        return {}
    try:
        return json.loads(match.group(1))
    except Exception:
        return {}


def extract_first_html_attr(tag_html, attr_name):
    match = re.search(rf'{re.escape(attr_name)}=["\']([^"\']*)["\']', tag_html or "", flags=re.IGNORECASE)
    return html_lib.unescape(match.group(1)) if match else ""


def extract_anime108_button_config(page_html):
    buttons = re.findall(r"<span[^>]+halim-btn[^>]*>", page_html, flags=re.IGNORECASE)
    if not buttons:
        return {}

    selected = None
    for button in buttons:
        if re.search(r'\bactive\b', button, flags=re.IGNORECASE):
            selected = button
            break
    selected = selected or buttons[0]

    return {
        "post_id": extract_first_html_attr(selected, "data-post-id"),
        "server": extract_first_html_attr(selected, "data-server") or "1",
        "episode": extract_first_html_attr(selected, "data-episode") or "1",
        "title": extract_first_html_attr(selected, "data-title"),
    }


def extract_anime108_lang(page_html):
    select_match = re.search(
        r'<select[^>]+id=["\']Lang_select["\'][^>]*>(.*?)</select>',
        page_html,
        flags=re.IGNORECASE | re.DOTALL,
    )
    if not select_match:
        return "Thai"
    option_match = re.search(r'<option[^>]+value=["\']([^"\']+)["\']', select_match.group(1), flags=re.IGNORECASE)
    return html_lib.unescape(option_match.group(1)).strip() if option_match else "Thai"


def extract_anime108_player_url(player_html, page_url):
    candidates = re.findall(r'<iframe[^>]+src=["\']([^"\']+)["\']', player_html, flags=re.IGNORECASE)
    return first_matching_url(candidates, base_url=page_url, predicate=is_anime108_player_url)


def anime108_media_url_from_player_url(player_url):
    parsed = urlparse(player_url)
    query = parse_qs(parsed.query)
    media_id = (query.get("id") or [""])[0].strip()
    if not media_id or not re.fullmatch(r"[A-Za-z0-9_-]{8,100}", media_id):
        return None

    path = parsed.path.lower()
    backup_value = (query.get("backup") or [""])[0]
    playlist_dir = "newplaylist_g" if "download" in path or backup_value == "1" else "newplaylist"
    return f"https://{ANIME108_PLAYER_HOSTS[0]}/{playlist_dir}/{media_id}/{media_id}.m3u8"


def resolve_anime108_download_url(download_url):
    if not (is_anime108_page_url(download_url) or is_anime108_player_url(download_url)):
        return download_url, [], None

    try:
        if is_anime108_player_url(download_url):
            player_url = download_url
        else:
            print("[palladium] site profile resolving: anime108 page")
            page_html = fetch_site_text(download_url)
            page_config = extract_anime108_config(page_html)
            button_config = extract_anime108_button_config(page_html)
            post_id = str(page_config.get("post_id") or button_config.get("post_id") or "").strip()
            episode = str(page_config.get("episode") or button_config.get("episode") or "1").strip()
            server = str(page_config.get("server") or button_config.get("server") or "1").strip()
            title = str(page_config.get("post_title") or button_config.get("title") or "").strip()
            lang = extract_anime108_lang(page_html)
            if not post_id:
                print("[palladium] anime108 resolver: no post id found")
                return download_url, [], "anime108"

            player_response = post_site_text(
                "https://www.anime108.com/api/get.php",
                {
                    "action": "halim_ajax_player",
                    "nonce": "",
                    "episode": episode,
                    "server": server,
                    "postid": post_id,
                    "lang": lang,
                    "title": title,
                },
                referer=download_url,
            )
            player_url = extract_anime108_player_url(player_response, download_url)
            if not player_url:
                print("[palladium] anime108 resolver: no 108player iframe found")
                return download_url, [], "anime108"

        print(f"[palladium] anime108 resolver iframe: {player_url}")
        media_url = anime108_media_url_from_player_url(player_url)
        if not media_url:
            print("[palladium] anime108 resolver: no media id found")
            return download_url, [], "anime108"

        print(f"[palladium] anime108 resolver media: {media_url}")
        return media_url, ["--referer", player_url, "--user-agent", DEFAULT_BROWSER_USER_AGENT], "anime108"
    except Exception as error:
        print(f"[palladium] anime108 resolver failed: {error}")
        return download_url, [], "anime108"


def resolve_cloudbeta_download_url(download_url):
    if not is_cloudbeta_player_url(download_url):
        return download_url, [], None

    try:
        parsed = urlparse(download_url)
        parts = [part for part in parsed.path.split("/") if part]
        if len(parts) < 3 or parts[0].lower() != "embed":
            return download_url, [], "cloudbeta"
        user_id = parts[1]
        file_id = parts[2]
        media_url = f"https://play.cloudbeta.win/file/em3u8/{user_id}/{file_id}.m3u8"
        print(f"[palladium] cloudbeta resolver media: {media_url}")
        return media_url, ["--referer", download_url, "--user-agent", DEFAULT_BROWSER_USER_AGENT], "cloudbeta"
    except Exception as error:
        print(f"[palladium] cloudbeta resolver failed: {error}")
        return download_url, [], "cloudbeta"


def resolve_meeplayer_download_url(download_url):
    if not is_meeplayer_url(download_url):
        return download_url, [], None

    try:
        match = re.search(r"/(?:play|p2p|p2p-hls)/([^/?#]+)", urlparse(download_url).path, flags=re.IGNORECASE)
        if not match:
            return download_url, [], "meeplayer"
        video_id = match.group(1)
        api_url = f"https://player2.meeplayer.com/api/video/{video_id}"
        print(f"[palladium] meeplayer resolver api: {api_url}")
        payload = json.loads(fetch_site_text(api_url, referer=download_url))
        video = payload.get("video") if isinstance(payload, dict) else {}
        md5 = str((video or {}).get("md5") or "").strip()
        status = str((video or {}).get("iStatus") or "1").strip()
        if not md5 or status == "0":
            print("[palladium] meeplayer resolver: no playable md5")
            return download_url, [], "meeplayer"
        media_url = f"https://meeplayer.com/hlsr2/{md5}/master"
        print(f"[palladium] meeplayer resolver media: {media_url}")
        return media_url, ["--referer", download_url, "--user-agent", DEFAULT_BROWSER_USER_AGENT], "meeplayer"
    except Exception as error:
        print(f"[palladium] meeplayer resolver failed: {error}")
        return download_url, [], "meeplayer"


def extract_dooplay_options(page_html):
    options = []
    seen = set()
    for tag in re.findall(r"<[^>]*(?:dooplay_player_option|player-option-)[^>]*>", page_html or "", flags=re.IGNORECASE):
        post = extract_first_html_attr(tag, "data-post")
        nume = extract_first_html_attr(tag, "data-nume")
        option_type = extract_first_html_attr(tag, "data-type") or "movie"
        if not post or not nume or str(nume).lower() == "trailer":
            continue
        key = (post, nume, option_type)
        if key not in seen:
            seen.add(key)
            options.append(key)

    for match in re.finditer(
        r'\{[^{}]*["\']post["\']\s*:\s*["\']?(\d+)["\']?[^{}]*["\']nume["\']\s*:\s*["\']?([^"\',}]+)["\']?[^{}]*["\']type["\']\s*:\s*["\']?([^"\',}]+)["\']?[^{}]*\}',
        page_html or "",
        flags=re.IGNORECASE,
    ):
        post, nume, option_type = match.group(1), match.group(2), match.group(3) or "movie"
        if str(nume).lower() == "trailer":
            continue
        key = (post, nume, option_type)
        if key not in seen:
            seen.add(key)
            options.append(key)
    return options


def fetch_dooplay_results(page_html, page_url):
    collected = []
    parsed = urlparse(page_url)
    if not parsed.scheme or not parsed.netloc:
        return collected
    ajax_url = f"{parsed.scheme}://{parsed.netloc}/wp-admin/admin-ajax.php"
    for post, nume, option_type in extract_dooplay_options(page_html):
        try:
            print(f"[palladium] generic scan dooplay: post={post} nume={nume} type={option_type}")
            response = post_site_text(
                ajax_url,
                {"action": "doo_player_ajax", "post": post, "nume": nume, "type": option_type},
                referer=page_url,
            )
            try:
                payload = json.loads(response)
                if isinstance(payload, dict) and payload.get("embed_url"):
                    collected.append(str(payload.get("embed_url")))
                collected.append(json.dumps(payload))
            except Exception:
                collected.append(response)
        except Exception as error:
            print(f"[palladium] generic scan dooplay failed: {error}")
    return collected


def extract_halim_options(page_html):
    options = []
    seen = set()
    page_config = extract_anime108_config(page_html)

    def add(post, episode="1", server="1", lang="Sound Track"):
        post = str(post or "").strip()
        episode = str(episode or "1").strip()
        server = str(server or "1").strip()
        lang = str(lang or "Sound Track").strip()
        if not post or not server:
            return
        key = (post, episode, server, lang)
        if key not in seen:
            seen.add(key)
            options.append(key)

    if page_config.get("post_id"):
        add(
            page_config.get("post_id"),
            page_config.get("episode") or "1",
            page_config.get("server") or "1",
            page_config.get("lang") or extract_anime108_lang(page_html),
        )

    for tag in re.findall(r"<[^>]*(?:halim-btn|data-post-id|data-server)[^>]*>", page_html or "", flags=re.IGNORECASE):
        post = extract_first_html_attr(tag, "data-post-id") or extract_first_html_attr(tag, "data-post") or extract_first_html_attr(tag, "data-id")
        server = extract_first_html_attr(tag, "data-server") or "1"
        episode = extract_first_html_attr(tag, "data-episode") or extract_first_html_attr(tag, "data-ep") or "1"
        add(post, episode, server, extract_anime108_lang(page_html))

    for match in re.finditer(
        r'\{[^{}]*["\']post["\']\s*:\s*["\']?(\d+)["\']?[^{}]*["\']server["\']\s*:\s*["\']?([^"\',}]+)["\']?[^{}]*["\']episode["\']\s*:\s*["\']?([^"\',}]+)["\']?[^{}]*\}',
        page_html or "",
        flags=re.IGNORECASE,
    ):
        add(match.group(1), match.group(3), match.group(2), extract_anime108_lang(page_html))

    return options


def fetch_halim_results(page_html, page_url, title=""):
    collected = []
    parsed = urlparse(page_url)
    if not parsed.scheme or not parsed.netloc:
        return collected
    api_url = f"{parsed.scheme}://{parsed.netloc}/api/get.php"
    for post, episode, server, lang in extract_halim_options(page_html):
        try:
            print(f"[palladium] generic scan halim: post={post} episode={episode} server={server}")
            collected.append(
                post_site_text(
                    api_url,
                    {
                        "action": "halim_ajax_player",
                        "nonce": "",
                        "episode": episode,
                        "server": server,
                        "postid": post,
                        "lang": lang,
                        "title": title,
                    },
                    referer=page_url,
                )
            )
        except Exception as error:
            print(f"[palladium] generic scan halim failed: {error}")
    return collected


def extract_page_title(page_html, fallback_url):
    patterns = [
        r'<meta[^>]+property=["\']og:title["\'][^>]+content=["\']([^"\']+)["\']',
        r"<title[^>]*>(.*?)</title>",
    ]
    for pattern in patterns:
        match = re.search(pattern, page_html or "", flags=re.IGNORECASE | re.DOTALL)
        if match:
            title = html_lib.unescape(re.sub(r"\s+", " ", match.group(1)).strip())
            if title:
                return title
    host = normalized_url_host(fallback_url)
    return host or "Video"


def fetch_script_texts(page_html, page_url, limit=6):
    scripts = []
    for match in re.finditer(r'<script[^>]+src\s*=\s*["\']([^"\']+)["\']', page_html or "", flags=re.IGNORECASE):
        if len(scripts) >= limit:
            break
        script_url = normalize_candidate_url(match.group(1), page_url)
        if not script_url or is_crawler_blocked_url(script_url):
            continue
        if re.search(r"google-analytics|googletagmanager|doubleclick|facebook|twitter|telegram|/ads?|banner|popunder|histats|yandex\.ru/metrika", script_url, flags=re.IGNORECASE):
            continue
        try:
            script_text = fetch_site_text(script_url, referer=page_url)
            scripts.append(script_text[:700000])
        except Exception:
            continue
    return scripts


def select_best_generic_candidate(candidates):
    valid = [candidate for candidate in candidates if candidate and not is_crawler_blocked_url(candidate)]
    valid.sort(key=candidate_score, reverse=True)
    return valid[0] if valid else None


def resolve_generic_scan_candidate(candidate, referer, depth, seen):
    if not candidate or candidate in seen:
        return None, [], None
    seen.add(candidate)

    resolved_url, resolved_args, profile = resolve_known_player_candidate(candidate, referer)
    if profile and resolved_url and resolved_url != candidate:
        return resolved_url, resolved_args, f"generic-{profile}"

    if is_likely_media_candidate(candidate):
        return candidate, ["--referer", referer, "--user-agent", DEFAULT_BROWSER_USER_AGENT], "generic-media"

    if depth >= 2 or not is_likely_player_page(candidate):
        return None, [], None

    try:
        page_html = fetch_site_text_impersonated(candidate, referer=referer)
    except Exception as error:
        print(f"[palladium] generic deep scan fetch failed: {error}")
        return None, [], None

    nested = extract_scan_candidates(page_html, candidate)
    for script_text in fetch_script_texts(page_html, candidate, limit=4):
        nested.extend(extract_scan_candidates(script_text, candidate))

    for nested_candidate in sorted(set(nested), key=candidate_score, reverse=True):
        resolved_url, resolved_args, profile = resolve_generic_scan_candidate(nested_candidate, candidate, depth + 1, seen)
        if profile:
            return resolved_url, resolved_args, profile
    return None, [], None


def resolve_generic_page_download_url(download_url):
    if not str(download_url or "").startswith(("http://", "https://")) or is_youtube_url(download_url):
        return download_url, [], None

    try:
        print("[palladium] generic page scan: started")
        resolved_url, resolved_args, profile = resolve_known_player_candidate(download_url, download_url)
        if profile and resolved_url and resolved_url != download_url:
            return resolved_url, resolved_args, f"generic-{profile}"
        if is_likely_media_candidate(download_url):
            return download_url, [], "generic-direct"

        page_html = fetch_site_text_impersonated(download_url)
        page_title = extract_page_title(page_html, download_url)
        candidates = extract_scan_candidates(page_html, download_url)
        for body in fetch_dooplay_results(page_html, download_url):
            candidates.extend(extract_scan_candidates(body, download_url))
        for body in fetch_halim_results(page_html, download_url, title=page_title):
            candidates.extend(extract_scan_candidates(body, download_url))
        for script_text in fetch_script_texts(page_html, download_url):
            candidates.extend(extract_scan_candidates(script_text, download_url))

        print(f"[palladium] generic page scan candidates: {len(set(candidates))}")
        seen = set()
        for candidate in sorted(set(candidates), key=candidate_score, reverse=True):
            resolved_url, resolved_args, profile = resolve_generic_scan_candidate(candidate, download_url, 0, seen)
            if profile:
                print(f"[palladium] generic page scan resolved: {profile} -> {resolved_url}")
                return resolved_url, resolved_args, "generic-scan"

        best = select_best_generic_candidate(candidates)
        if best:
            print(f"[palladium] generic page scan fallback candidate: {best}")
            return best, ["--referer", download_url, "--user-agent", DEFAULT_BROWSER_USER_AGENT], "generic-scan"
    except Exception as error:
        print(f"[palladium] generic page scan failed: {error}")
    return download_url, [], None


def build_site_specific_download_args(download_url, existing_args):
    if is_youtube_url(download_url):
        args = []
        if not argv_contains_text(existing_args, "youtube:player_client"):
            args.extend(["--extractor-args", "youtube:player_client=android,web"])
        return args, "youtube" if args else None

    if not is_xhamster_page_url(download_url):
        return [], None

    args = []
    if not argv_contains_option(existing_args, "--impersonate"):
        args.extend(["--impersonate", "chrome"])
    if not argv_contains_option(existing_args, "--referer"):
        args.extend(["--referer", download_url])
    if not argv_contains_option(existing_args, "--user-agent"):
        args.extend(["--user-agent", DEFAULT_BROWSER_USER_AGENT])
    return args, "xhamster"


def requires_impersonation_support(extra_args_text, download_url):
    return (
        has_generic_impersonation_arg(extra_args_text)
        or is_xhamster_page_url(download_url)
        or is_genz3x_page_url(download_url)
        or is_genz3x_player_url(download_url)
        or is_avple_page_url(download_url)
    )


def curl_cffi_supported_version(curl_cffi_module):
    try:
        version = tuple(map(int, re.split(r"[^\d]+", curl_cffi_module.__version__)[:3]))
    except Exception:
        return False
    return version == (0, 5, 10) or (0, 10) <= version < (0, 15)


def version_tuple(value):
    parts = []
    for piece in re.split(r"[^\d]+", str(value or "")):
        if not piece:
            continue
        try:
            parts.append(int(piece))
        except Exception:
            break
        if len(parts) >= 4:
            break
    return tuple(parts)


def package_version_at_least(current, minimum):
    current_tuple = version_tuple(current)
    minimum_tuple = version_tuple(minimum)
    if not current_tuple or not minimum_tuple:
        return False
    width = max(len(current_tuple), len(minimum_tuple))
    return current_tuple + (0,) * (width - len(current_tuple)) >= minimum_tuple + (0,) * (width - len(minimum_tuple))


def unload_imported_modules(module_name):
    prefix = f"{module_name}."
    for name in list(sys.modules.keys()):
        if name == module_name or name.startswith(prefix):
            sys.modules.pop(name, None)


def ensure_curl_cffi_if_needed(pip_main, install_target, extra_args_text, download_url=None):
    if not requires_impersonation_support(extra_args_text, download_url):
        print("[palladium] cloudflare/site impersonation: disabled")
        return False, False, None

    if is_xhamster_page_url(download_url):
        print("[palladium] site profile enabled: xhamster browser impersonation")
    elif is_genz3x_page_url(download_url) or is_genz3x_player_url(download_url):
        print("[palladium] site profile enabled: genz3x browser impersonation")
    elif is_avple_page_url(download_url):
        print("[palladium] site profile enabled: avple browser impersonation")
    elif has_generic_impersonation_arg(extra_args_text):
        print("[palladium] cloudflare mode: enabled (generic impersonation)")

    try:
        import curl_cffi  # noqa: F401
        if not curl_cffi_supported_version(curl_cffi):
            print(f"[palladium] impersonation dependency unsupported: curl_cffi {curl_cffi.__version__}")
            raise ImportError("unsupported curl_cffi version")
        print("[palladium] impersonation dependency ready: curl_cffi")
        return True, False, 0
    except Exception as import_error:
        print(f"[palladium] impersonation dependency missing: curl_cffi ({import_error})")
        unload_imported_modules("curl_cffi")

    if pip_main is None:
        print("[palladium] impersonation dependency install skipped: pip unavailable")
        return True, False, 1

    try:
        removed = cleanup_target_package(install_target, "curl_cffi")
        if removed:
            print(f"[palladium] removed stale curl_cffi target entries: {removed}")
        unload_imported_modules("curl_cffi")
        pip_args = [
            "install",
            "--upgrade",
            "--disable-pip-version-check",
            "--no-cache-dir",
            "--progress-bar",
            "off",
            "--no-color",
            "curl_cffi>=0.10,<0.15",
        ]
        if install_target:
            pip_args[1:1] = ["--target", install_target]
        print("[palladium] installing impersonation dependency: curl_cffi>=0.10,<0.15")
        pip_result = pip_main(pip_args)
        pip_exit_code = 0 if pip_result is None else int(pip_result)
        print(f"[palladium] impersonation dependency pip exit code: {pip_exit_code}")
        if pip_exit_code != 0:
            return True, True, pip_exit_code
        import curl_cffi  # noqa: F401
        if not curl_cffi_supported_version(curl_cffi):
            print(f"[palladium] impersonation dependency still unsupported: curl_cffi {curl_cffi.__version__}")
            return True, True, 1
        print("[palladium] impersonation dependency ready after install: curl_cffi")
        return True, True, pip_exit_code
    except Exception:
        print("[palladium] impersonation dependency install failed")
        traceback.print_exc()
        return True, True, 1


def run_yt_dlp_flow(
    download_url_override=None,
    download_preset_override=None,
    preset_args_json_override=None,
    extra_args_override=None,
    output_title_hint_override=None,
    allow_resume_override=None,
    download_playlist_override=None,
    download_subtitles_override=None,
    embed_thumbnail_override=None,
    auto_retry_failed_downloads_override=None,
    concurrent_fragments_override=None,
    http_chunk_size_override=None,
    subtitle_language_pattern_override=None,
    cookie_file_path_override=None,
    run_output_dir_override=None,
    live_log_fd_override=None,
):
    output = TailBuffer()
    console_stdout = sys.__stdout__ if sys.__stdout__ is not None else None
    console_stderr = sys.__stderr__ if sys.__stderr__ is not None else None
    pip_attempted = False
    pip_exit_code = None
    yt_exit_code = None
    downloaded_paths = []
    primary_downloaded_path = None
    cancelled = False
    success = False
    if download_url_override is None:
        download_url = os.environ.get("PALLADIUM_DOWNLOAD_URL", "").strip()
    else:
        download_url = str(download_url_override).strip()

    if download_preset_override is None:
        download_preset = os.environ.get("PALLADIUM_DOWNLOAD_PRESET", "auto_video").strip()
    else:
        download_preset = str(download_preset_override).strip()
    if preset_args_json_override is None:
        preset_args_json = os.environ.get("PALLADIUM_PRESET_ARGS_JSON", "").strip()
    else:
        preset_args_json = str(preset_args_json_override).strip()
    if extra_args_override is None:
        extra_args_text = os.environ.get("PALLADIUM_EXTRA_ARGS", "").strip()
    else:
        extra_args_text = str(extra_args_override).strip()
    if output_title_hint_override is None:
        output_title_hint = os.environ.get("KDOWNLOADER_OUTPUT_TITLE_HINT", "").strip()
    else:
        output_title_hint = str(output_title_hint_override).strip()
    if allow_resume_override is None:
        allow_resume = os.environ.get("KDOWNLOADER_ALLOW_RESUME", "").strip().lower() in ("1", "true", "yes", "on")
    else:
        allow_resume = bool(allow_resume_override)
    if download_playlist_override is None:
        download_playlist = os.environ.get("PALLADIUM_DOWNLOAD_PLAYLIST", "").strip().lower() in ("1", "true", "yes", "on")
    else:
        download_playlist = bool(download_playlist_override)
    if download_subtitles_override is None:
        download_subtitles = os.environ.get("PALLADIUM_DOWNLOAD_SUBTITLES", "").strip().lower() in ("1", "true", "yes", "on")
    else:
        download_subtitles = bool(download_subtitles_override)
    if embed_thumbnail_override is None:
        embed_thumbnail = os.environ.get("PALLADIUM_EMBED_THUMBNAIL", "").strip().lower() in ("1", "true", "yes", "on")
    else:
        embed_thumbnail = bool(embed_thumbnail_override)
    if auto_retry_failed_downloads_override is None:
        auto_retry_failed_downloads = os.environ.get("PALLADIUM_AUTO_RETRY_FAILED_DOWNLOADS", "").strip().lower() in ("1", "true", "yes", "on")
    else:
        auto_retry_failed_downloads = bool(auto_retry_failed_downloads_override)
    if concurrent_fragments_override is None:
        raw_concurrent_fragments = os.environ.get("KDOWNLOADER_CONCURRENT_FRAGMENTS", "").strip()
    else:
        raw_concurrent_fragments = str(concurrent_fragments_override).strip()
    try:
        concurrent_fragments = min(max(int(raw_concurrent_fragments or "8"), 1), 16)
    except Exception:
        concurrent_fragments = 8
    if http_chunk_size_override is None:
        http_chunk_size = os.environ.get("KDOWNLOADER_HTTP_CHUNK_SIZE", "10M").strip() or "10M"
    else:
        http_chunk_size = str(http_chunk_size_override).strip() or "10M"
    if subtitle_language_pattern_override is None:
        subtitle_language_pattern = os.environ.get("PALLADIUM_SUBTITLE_LANGUAGE_PATTERN", "en").strip() or "en"
    else:
        subtitle_language_pattern = str(subtitle_language_pattern_override).strip() or "en"
    if subtitle_language_pattern == "en.*":
        subtitle_language_pattern = "en"
    if cookie_file_path_override is None:
        cookie_file_path = os.environ.get("PALLADIUM_COOKIE_FILE_PATH", "").strip()
    else:
        cookie_file_path = str(cookie_file_path_override).strip()
    downloads_dir = os.environ.get("PALLADIUM_DOWNLOADS", "").strip()
    if run_output_dir_override is None:
        run_output_dir = os.environ.get("PALLADIUM_RUN_OUTPUT_DIR", "").strip() or downloads_dir
    else:
        run_output_dir = str(run_output_dir_override).strip() or downloads_dir
    install_target = os.environ.get("PALLADIUM_PYTHON_PACKAGES")
    cache_dir = os.environ.get("PALLADIUM_CACHE_DIR", "").strip()
    cancel_file_path = os.environ.get("PALLADIUM_CANCEL_FILE", "").strip()
    live_log_stream = open_live_log_stream(live_log_fd_override)
    playlist_progress = PlaylistProgressCollector(live_log_stream=live_log_stream)

    with contextlib.redirect_stdout(Tee(output, console_stdout, live_log_stream, playlist_progress)), contextlib.redirect_stderr(Tee(output, console_stderr, live_log_stream, playlist_progress)):
        argv_backup = sys.argv[:]
        cwd_backup = os.getcwd()
        try:
            os.environ["PYTHONIOENCODING"] = "utf-8"
            if install_target:
                os.makedirs(install_target, exist_ok=True)
                if install_target not in sys.path:
                    sys.path.insert(0, install_target)
                print(f"[palladium] package install target: {install_target}")
            if downloads_dir:
                os.makedirs(downloads_dir, exist_ok=True)
                print(f"[palladium] download target: {downloads_dir}")
            if run_output_dir:
                os.makedirs(run_output_dir, exist_ok=True)
                print(f"[palladium] run output target: {run_output_dir}")
            if cache_dir:
                os.makedirs(cache_dir, exist_ok=True)
                print(f"[palladium] cache target: {cache_dir}")

            needs_yt_dlp_install = False
            needs_webkit_jsi_install = False

            print("[palladium] checking yt-dlp package metadata")
            yt_dlp_installed, yt_dlp_version, yt_dlp_source = is_package_installed(
                "yt-dlp",
                install_target=install_target,
            )
            if yt_dlp_installed:
                print(f"[palladium] yt-dlp already installed ({yt_dlp_version} via {yt_dlp_source})")
                if not package_version_at_least(yt_dlp_version, MIN_YTDLP_VERSION):
                    needs_yt_dlp_install = True
                    print(
                        "[palladium] yt-dlp version below supported minimum: "
                        f"{yt_dlp_version} < {MIN_YTDLP_VERSION}"
                    )
            else:
                needs_yt_dlp_install = True
                print("[palladium] yt-dlp package missing")

            print("[palladium] checking yt-dlp-apple-webkit-jsi package metadata")
            webkit_jsi_installed, webkit_jsi_version, webkit_jsi_source = is_package_installed(
                "yt-dlp-apple-webkit-jsi",
                install_target=install_target,
            )
            if webkit_jsi_installed:
                print(f"[palladium] yt-dlp-apple-webkit-jsi already installed ({webkit_jsi_version} via {webkit_jsi_source})")
            else:
                needs_webkit_jsi_install = True
                print("[palladium] yt-dlp-apple-webkit-jsi missing")

            if needs_yt_dlp_install or needs_webkit_jsi_install:
                raise_if_cancel_requested(cancel_file_path, "[palladium] cancellation requested before pip install")
                pip_attempted = True
                pip_main = ensure_pip_entrypoint(install_target)
                if pip_main is not None:
                    packages = []
                    if needs_yt_dlp_install:
                        packages.append(f"yt-dlp>={MIN_YTDLP_VERSION}")
                        removed = cleanup_target_package(install_target, "yt-dlp")
                        if removed:
                            print(f"[palladium] removed stale yt-dlp target entries: {removed}")
                    if needs_webkit_jsi_install:
                        packages.append("yt-dlp-apple-webkit-jsi")

                    try:
                        raise_if_cancel_requested(cancel_file_path, "[palladium] cancellation requested before pip install")
                        pip_args = ["install", "--upgrade", "--no-cache-dir", "--progress-bar", "off", "--no-color", *packages]
                        if install_target:
                            pip_args[1:1] = ["--target", install_target]
                        pip_args[1:1] = ["--disable-pip-version-check"]
                        pip_result = pip_main(pip_args)
                        pip_exit_code = 0 if pip_result is None else int(pip_result)
                        print(f"[palladium] pip exit code: {pip_exit_code}")
                    except Exception:
                        pip_exit_code = 1
                        print("[palladium] pip install failed")
                        traceback.print_exc()
                else:
                    pip_exit_code = 1

                installed_versions = collect_versions(install_target=install_target, allow_cache_fallback=False)
                print(f"[palladium] yt-dlp after install: {installed_versions.get('yt-dlp', 'not installed')}")
                print(
                    "[palladium] yt-dlp-apple-webkit-jsi after install: "
                    f"{installed_versions.get('yt-dlp-apple-webkit-jsi', 'not installed')}"
                )

            pip_main_for_cloudflare = ensure_pip_entrypoint(install_target)
            cloudflare_enabled, curl_cffi_install_attempted, curl_cffi_pip_exit_code = ensure_curl_cffi_if_needed(
                pip_main_for_cloudflare,
                install_target,
                extra_args_text,
                download_url,
            )
            if curl_cffi_install_attempted:
                pip_attempted = True
                pip_exit_code = curl_cffi_pip_exit_code

            raise_if_cancel_requested(cancel_file_path, "[palladium] cancellation requested before webkit patch")
            ensure_safe_webkit_jsi_runtime(install_target)

            if not download_url:
                print("[palladium] no URL provided")
                yt_exit_code = 1
            elif is_cancel_requested(cancel_file_path):
                print("[palladium] cancellation requested before run")
                cancelled = True
                yt_exit_code = 130
            else:
                print(f"[palladium] running yt-dlp -v {download_url}")

            if download_url:
                raise_if_cancel_requested(cancel_file_path, "[palladium] cancellation requested before bridge startup")
                bridge = None
                bridge_adapter = None
                try:
                    bridge = SwiftFFmpegBridge()
                    bridge_adapter = YTDLPFFmpegBridgeAdapter(bridge, cancel_file_path=cancel_file_path)
                    print("[palladium][ffmpeg-bridge] bridge loaded")
                    print("[palladium][ffmpeg-bridge] startup probes skipped")
                except Exception as bridge_error:
                    print(f"[palladium] swift ffmpeg bridge error: {bridge_error}")
                    traceback.print_exc()
                    yt_exit_code = 1

                if yt_exit_code != 1:
                    if run_output_dir:
                        os.chdir(run_output_dir)
                    if allow_resume:
                        print("[palladium] resume enabled: preserving partial download files")
                    else:
                        raise_if_cancel_requested(cancel_file_path, "[palladium] cancellation requested before download cleanup")
                        cleanup_temp_download_files(run_output_dir)

                    if is_cancel_requested(cancel_file_path):
                        print("[palladium] cancellation requested before yt-dlp start")
                        cancelled = True
                        yt_exit_code = 130

                    if yt_exit_code is None:
                        preset_args_map = parse_preset_args_map(preset_args_json)
                        selected_args = preset_args_map.get(download_preset, "")
                        if selected_args:
                            preset_args = parse_custom_args(selected_args)
                            print(f"[palladium] preset args override: {download_preset}")
                        elif download_preset == "custom":
                            preset_args = []
                            print("[palladium] preset: custom (no args)")
                        else:
                            preset_args = build_preset_args(download_preset)
                        preset_args = strip_checkbox_owned_download_args(preset_args)
                        extra_args = strip_checkbox_owned_download_args(parse_extra_args(extra_args_text))
                        raise_if_cancel_requested(cancel_file_path, "[palladium] cancellation requested before yt-dlp invocation")
                        output_args = []
                        download_behavior_args = []
                        if has_custom_output_template(preset_args) or has_custom_output_template(extra_args):
                            print("[palladium] custom output template detected")
                        else:
                            if download_playlist:
                                output_args = ["-o", "%(playlist_index)03d - %(title).180B.%(ext)s"]
                            else:
                                sanitized_title_hint = sanitize_output_title_hint(output_title_hint)
                                if sanitized_title_hint:
                                    print(f"[palladium] output title hint: {sanitized_title_hint}")
                                    output_args = ["-o", f"{sanitized_title_hint}.%(ext)s"]
                                else:
                                    output_args = ["-o", "%(title).180B.%(ext)s"]

                        if not download_playlist:
                            download_behavior_args.append("--no-playlist")

                        if download_subtitles:
                            download_behavior_args.extend(["--write-subs", "--write-auto-subs"])
                            if subtitle_language_pattern == "all":
                                download_behavior_args.append("--all-subs")
                            else:
                                download_behavior_args.extend(["--sub-langs", subtitle_language_pattern])

                        if embed_thumbnail:
                            download_behavior_args.extend(["--convert-thumbnails", "png", "--embed-thumbnail"])

                        if cookie_file_path:
                            if os.path.isfile(cookie_file_path):
                                print(f"[palladium] using cookie file: {cookie_file_path}")
                                download_behavior_args.extend(["--cookies", cookie_file_path])
                            else:
                                print(f"[palladium] cookie file missing, ignoring: {cookie_file_path}")

                        existing_args = [
                            *download_behavior_args,
                            *preset_args,
                            *extra_args,
                        ]
                        effective_download_url, resolved_site_args, resolved_site_profile_name = resolve_genz3x_download_url(download_url)
                        if not resolved_site_profile_name:
                            effective_download_url, resolved_site_args, resolved_site_profile_name = resolve_sextop1_download_url(download_url)
                        if not resolved_site_profile_name:
                            effective_download_url, resolved_site_args, resolved_site_profile_name = resolve_avple_download_url(download_url)
                        if not resolved_site_profile_name:
                            effective_download_url, resolved_site_args, resolved_site_profile_name = resolve_kubhd_download_url(download_url)
                        if not resolved_site_profile_name:
                            effective_download_url, resolved_site_args, resolved_site_profile_name = resolve_anime108_download_url(download_url)
                        if not resolved_site_profile_name:
                            effective_download_url, resolved_site_args, resolved_site_profile_name = resolve_cloudbeta_download_url(download_url)
                        if not resolved_site_profile_name:
                            effective_download_url, resolved_site_args, resolved_site_profile_name = resolve_meeplayer_download_url(download_url)
                        if not resolved_site_profile_name:
                            effective_download_url, resolved_site_args, resolved_site_profile_name = resolve_generic_page_download_url(download_url)
                        if resolved_site_profile_name:
                            print(f"[palladium] site profile resolved: {resolved_site_profile_name}")
                        existing_args.extend(resolved_site_args)
                        site_specific_args, site_profile_name = build_site_specific_download_args(
                            download_url,
                            existing_args,
                        )
                        site_specific_args = [*resolved_site_args, *site_specific_args]
                        if site_profile_name:
                            print(f"[palladium] site profile args applied: {site_profile_name}")

                        sys.argv = [
                            "yt-dlp",
                            "-v",
                            "--no-check-certificate",
                            "--remote-components",
                            "ejs:github",
                            "--cache-dir",
                            cache_dir if cache_dir else os.path.join(downloads_dir if downloads_dir else ".", ".cache"),
                            "-N",
                            str(concurrent_fragments),
                            "--http-chunk-size",
                            http_chunk_size,
                            "--throttled-rate",
                            "100K",
                            *(["--continue"] if allow_resume else ["--force-overwrites", "--no-continue"]),
                            "-P",
                            run_output_dir if run_output_dir else ".",
                            *output_args,
                            *download_behavior_args,
                            *site_specific_args,
                            *preset_args,
                            *extra_args,
                            effective_download_url,
                        ]

                        try:
                            with patch_ytdlp_for_swiftffmpeg(bridge_adapter):
                                runpy.run_module("yt_dlp", run_name="__main__", alter_sys=True)
                            yt_exit_code = 0
                        except KeyboardInterrupt:
                            cancelled = True
                            yt_exit_code = 130
                            print("[palladium] yt-dlp cancelled by user")
                        except SystemExit as exc:
                            if exc.code is None:
                                yt_exit_code = 0
                            elif isinstance(exc.code, int):
                                yt_exit_code = exc.code
                            else:
                                print(f"[palladium] unexpected SystemExit code: {exc.code}")
                                yt_exit_code = 1
                        except Exception:
                            print("[palladium] yt-dlp execution failed")
                            traceback.print_exc()
                            yt_exit_code = 1

                        if (
                            not cancelled
                            and auto_retry_failed_downloads
                            and embed_thumbnail
                            and download_playlist
                            and playlist_progress.failed_item_records
                        ):
                            retry_candidates = playlist_progress.retry_candidates()
                            for candidate in retry_candidates:
                                item_index = candidate.get("index")
                                item_title = candidate.get("title") or f"item {item_index}"
                                print(f"[palladium] retrying playlist item without thumbnails: {item_title}")
                                playlist_progress.set_tracking_suspended(True)
                                retry_success, retry_error = run_retry_without_thumbnails(
                                    retry_candidate=candidate,
                                    download_url=effective_download_url,
                                    run_output_dir=run_output_dir,
                                    cache_dir=cache_dir,
                                    download_playlist=download_playlist,
                                    output_args=output_args,
                                    download_behavior_args=download_behavior_args,
                                    site_specific_args=site_specific_args,
                                    preset_args=preset_args,
                                    extra_args=extra_args,
                                    bridge_adapter=bridge_adapter,
                                )
                                playlist_progress.set_tracking_suspended(False)
                                if retry_success:
                                    print(f"[palladium] retry without thumbnails succeeded: {item_title}")
                                    playlist_progress.mark_retry_success(item_index)
                                else:
                                    print(f"[palladium] retry without thumbnails failed: {item_title}")
                                    if retry_error:
                                        print(retry_error)
                                    playlist_progress.mark_retry_failed(item_index, retry_error)

            if not cancelled and yt_exit_code is not None:
                try:
                    scan_dir = run_output_dir if run_output_dir else downloads_dir if downloads_dir else os.getcwd()
                    downloaded_paths, primary_downloaded_path = detect_downloaded_files(scan_dir)
                    if downloaded_paths:
                        print(f"[palladium] downloaded files detected: {len(downloaded_paths)}")
                        if primary_downloaded_path:
                            print(f"[palladium] primary downloaded file: {primary_downloaded_path}")
                        if yt_exit_code != 0:
                            if has_primary_media_file(downloaded_paths):
                                print(f"[palladium] overriding yt-dlp exit code {yt_exit_code} because a media file exists")
                                yt_exit_code = 0
                            else:
                                print(f"[palladium] keeping yt-dlp exit code {yt_exit_code} because only sidecar files were downloaded")
                    else:
                        print("[palladium] downloaded files not detected")
                except Exception:
                    print("[palladium] unable to detect downloaded files")
                    traceback.print_exc()
        except KeyboardInterrupt:
            cancelled = True
            if yt_exit_code is None:
                yt_exit_code = 130
            print("[palladium] download flow cancelled by user")
        except BaseException:
            print("[palladium] unable to execute yt_dlp as __main__")
            traceback.print_exc()
            yt_exit_code = 1
        finally:
            sys.argv = argv_backup
            try:
                os.chdir(cwd_backup)
            except Exception:
                pass
            if live_log_stream is not None:
                try:
                    live_log_stream.flush()
                except Exception:
                    pass

        playlist_progress.finalize(cancelled=cancelled)
        success = (pip_exit_code in (None, 0)) and (yt_exit_code == 0) and not cancelled
        result_kind = playlist_progress.result_kind(success, cancelled)
        if result_kind == "partial":
            success = True
        print(f"[palladium] flow success: {success}")

    final_result_kind = playlist_progress.result_kind(success, cancelled)
    return json.dumps({
        "pip_attempted": pip_attempted,
        "pip_exit_code": pip_exit_code,
        "yt_exit_code": yt_exit_code,
        "cancelled": cancelled,
        "success": success,
        "downloaded_paths": downloaded_paths,
        "primary_downloaded_path": primary_downloaded_path,
        "downloaded_path": primary_downloaded_path,
        "output": output.getvalue(),
        **playlist_progress.snapshot(result_kind=final_result_kind),
    })


def run_package_maintenance(action, custom_versions_json=None, live_log_fd_override=None):
    output = TailBuffer()
    console_stdout = sys.__stdout__ if sys.__stdout__ is not None else None
    console_stderr = sys.__stderr__ if sys.__stderr__ is not None else None
    pip_attempted = False
    pip_exit_code = None
    success = False
    updates_available = False
    updates_summary = "Not checked yet."
    available_versions = {}
    versions = {}
    cancelled = False
    install_target = os.environ.get("PALLADIUM_PYTHON_PACKAGES")
    cancel_file_path = os.environ.get("PALLADIUM_CANCEL_FILE", "").strip()
    live_log_stream = open_live_log_stream(live_log_fd_override)

    with contextlib.redirect_stdout(Tee(output, console_stdout, live_log_stream)), contextlib.redirect_stderr(Tee(output, console_stderr, live_log_stream)):
        os.environ["PYTHONIOENCODING"] = "utf-8"
        if install_target:
            os.makedirs(install_target, exist_ok=True)
            if install_target not in sys.path:
                sys.path.insert(0, install_target)
            print(f"[palladium] package install target: {install_target}")

        try:
            raise_if_cancel_requested(cancel_file_path, "[palladium] package action cancelled before start")
            print(f"[palladium] package action: {action}")
            if action == "versions":
                updates_available = False
                updates_summary = "Skipped update check."
                print("[palladium] quick version refresh only")
            elif action == "index_versions":
                updates_available = False
                updates_summary = "Skipped update check."
                available_versions = fetch_package_index_versions(install_target)
                print("[palladium] fetched package index versions")
            else:
                updates_available, updates_summary = check_package_updates(install_target)
                print(f"[palladium] updates available: {updates_available}")
                print(f"[palladium] updates summary: {updates_summary}")

            custom_versions = {}
            if custom_versions_json:
                try:
                    parsed_versions = json.loads(custom_versions_json)
                    if isinstance(parsed_versions, dict):
                        for package_name in TRACKED_PACKAGES:
                            raw_value = parsed_versions.get(package_name)
                            if raw_value is None:
                                continue
                            requested_version = str(raw_value).strip()
                            if requested_version:
                                custom_versions[package_name] = requested_version
                except Exception:
                    print("[palladium] failed to parse custom version payload")
                    traceback.print_exc()
            if custom_versions:
                print(f"[palladium] custom package versions requested: {custom_versions}")

            if action == "update":
                if updates_available or bool(custom_versions):
                    raise_if_cancel_requested(cancel_file_path, "[palladium] package action cancelled before pip startup")
                    pip_main = ensure_pip_entrypoint(install_target)
                    if pip_main is not None:
                        try:
                            installed_versions = collect_versions(install_target=install_target, allow_cache_fallback=False)
                            indexed_versions = fetch_package_index_versions(install_target=install_target, pip_main=pip_main)
                            packages, cleanup_packages = build_package_install_plan(
                                installed_versions,
                                indexed_versions,
                                custom_versions=custom_versions,
                            )

                            if not packages:
                                print("[palladium] no package installs required")
                                pip_exit_code = 0
                            else:
                                pip_attempted = True
                                if install_target:
                                    stale_removed = 0
                                    for package_name in cleanup_packages:
                                        raise_if_cancel_requested(cancel_file_path, "[palladium] package action cancelled during cleanup")
                                        stale_removed += cleanup_target_package(install_target, package_name)
                                    print(f"[palladium] removed stale target package entries: {stale_removed}")
                                raise_if_cancel_requested(cancel_file_path, "[palladium] package action cancelled before pip install")
                                pip_args = [
                                    "install",
                                    "--upgrade",
                                    "--disable-pip-version-check",
                                    "--no-cache-dir",
                                    "--progress-bar",
                                    "off",
                                    "--no-color",
                                    *packages,
                                ]
                                if install_target:
                                    pip_args[1:1] = ["--target", install_target]
                                pip_result = pip_main(pip_args)
                                pip_exit_code = 0 if pip_result is None else int(pip_result)
                                print(f"[palladium] pip exit code: {pip_exit_code}")
                        except Exception:
                            pip_exit_code = 1
                            print("[palladium] pip update failed")
                            traceback.print_exc()
                    else:
                        pip_exit_code = 1
                else:
                    print("[palladium] no updates available; skipping update")

                raise_if_cancel_requested(cancel_file_path, "[palladium] package action cancelled before post-update check")
                updates_available, updates_summary = check_package_updates(install_target)
                print(f"[palladium] post-update updates available: {updates_available}")
                print(f"[palladium] post-update updates summary: {updates_summary}")

            raise_if_cancel_requested(cancel_file_path, "[palladium] package action cancelled before webkit patch")
            ensure_safe_webkit_jsi_runtime(install_target)

            raise_if_cancel_requested(cancel_file_path, "[palladium] package action cancelled before version collection")
            versions = collect_versions(install_target=install_target)
            print(f"[palladium] yt-dlp version: {versions.get('yt-dlp')}")
            print(f"[palladium] yt-dlp-apple-webkit-jsi version: {versions.get('yt-dlp-apple-webkit-jsi')}")
            print(f"[palladium] pip version: {versions.get('pip')}")

            success = (pip_exit_code in (None, 0))
            print(f"[palladium] package flow success: {success}")
        except KeyboardInterrupt:
            cancelled = True
            success = False
            print("[palladium] package action cancelled by user")

    return json.dumps({
        "pip_attempted": pip_attempted,
        "pip_exit_code": pip_exit_code,
        "success": success,
        "cancelled": cancelled,
        "updates_available": updates_available,
        "updates_summary": updates_summary,
        "versions": versions,
        "available_versions": available_versions,
        "output": output.getvalue(),
    })
