#!/usr/bin/env python3
"""Cache thumbnails for all public Search result pages.

Run after publishing new public links when the static preview must display
external images without network access.
"""

import json
import mimetypes
import re
import urllib.request
from pathlib import Path

SUPABASE_URL = "https://vsafwjlosvbuonjuazxc.supabase.co"
SUPABASE_KEY = "sb_publishable_awYVK41RO6Wjq065B03S4w_qxAf8Qdn"
OUTPUT = Path(__file__).parent / "assets" / "search-thumbnails"


def fetch_page(page: int) -> dict:
    request = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/rpc/public_search_links",
        data=json.dumps(
            {"p_query": "", "p_sort": "trending", "p_page": page}
        ).encode(),
        method="POST",
        headers={
            "apikey": SUPABASE_KEY,
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def main() -> None:
    first_page = fetch_page(1)
    total_pages = max(1, int(first_page.get("total_pages", 1)))
    rows = list(first_page.get("results", []))
    for page in range(2, total_pages + 1):
        rows.extend(fetch_page(page).get("results", []))

    OUTPUT.mkdir(parents=True, exist_ok=True)
    manifest: dict[str, str] = {}
    for row in rows:
        code = str(row.get("code", ""))
        url = row.get("thumbnail_url")
        if not re.fullmatch(r"\d{6}", code) or not url:
            continue
        try:
            image_request = urllib.request.Request(
                url, headers={"User-Agent": "Mozilla/5.0", "Referer": ""}
            )
            with urllib.request.urlopen(image_request, timeout=30) as response:
                content = response.read()
                content_type = response.headers.get_content_type()
            extension = mimetypes.guess_extension(content_type) or ".jpg"
            if extension == ".jpe":
                extension = ".jpg"
            path = OUTPUT / f"{code}{extension}"
            path.write_bytes(content)
            manifest[code] = f"./assets/search-thumbnails/{path.name}"
        except Exception as error:
            print(f"Skipped {code}: {error}")

    (OUTPUT / "manifest.json").write_text(
        json.dumps(manifest, indent=2), encoding="utf-8"
    )
    print(
        f"Cached {len(manifest)} thumbnails from "
        f"{len(rows)} results across {total_pages} pages"
    )


if __name__ == "__main__":
    main()
