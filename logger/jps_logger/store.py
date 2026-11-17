"""Writing to and reading from Supabase through its REST API (PostgREST).

The secret key goes ONLY in the "apikey" header: Supabase's new sb_secret_ keys
are refused in an "Authorization: Bearer" header. Never print the key.
"""
import os

import requests

CHUNK = 500
PAGE = 1000  # Supabase returns at most 1000 rows per request by default


class Store:
    def __init__(self, url=None, key=None, session=None):
        self.url = (url or os.environ.get("SUPABASE_URL", "")).rstrip("/")
        # Logging needs the secret key. Exporting can use the publishable key (readings are public).
        self.key = key or os.environ.get("SUPABASE_SECRET_KEY") or os.environ.get("SUPABASE_PUBLISHABLE_KEY", "")
        if not self.url.startswith("https://") or not self.key:
            raise SystemExit("Set SUPABASE_URL (https://...) and SUPABASE_SECRET_KEY (or SUPABASE_PUBLISHABLE_KEY to export)")
        self.http = session or requests.Session()

    def _headers(self, extra=None):
        h = {"apikey": self.key, "Content-Type": "application/json"}
        h.update(extra or {})
        return h

    def insert(self, table, rows, conflict_cols, update_existing=False):
        """Adds rows in chunks. Rows already stored (same key) are left alone,
        or overwritten when update_existing is True. Returns rows sent."""
        prefer = "resolution=merge-duplicates" if update_existing else "resolution=ignore-duplicates"
        for i in range(0, len(rows), CHUNK):
            r = self.http.post(
                f"{self.url}/rest/v1/{table}",
                params={"on_conflict": ",".join(conflict_cols)},
                headers=self._headers({"Prefer": f"{prefer},return=minimal"}),
                json=rows[i:i + CHUNK], timeout=60)
            if r.status_code >= 300:
                raise RuntimeError(f"Supabase refused {table} rows: HTTP {r.status_code} {r.text[:300]}")
        return len(rows)

    def select_all(self, table, columns, filters):
        """All matching rows, page by page, oldest first.
        filters: list of (column, condition), e.g. [("observed_at", "gte.2026-11-17T00:00:00Z")]."""
        out, offset = [], 0
        while True:
            params = [("select", columns), ("order", "observed_at.asc,station_code.asc"),
                      ("limit", PAGE), ("offset", offset), *list(filters)]
            r = self.http.get(f"{self.url}/rest/v1/{table}", params=params, headers=self._headers(), timeout=60)
            if r.status_code >= 300:
                raise RuntimeError(f"Supabase read of {table} failed: HTTP {r.status_code} {r.text[:300]}")
            page = r.json()
            out.extend(page)
            if len(page) < PAGE:
                return out
            offset += PAGE

    def first_time(self, table):
        """Earliest observed_at in a table, or None if it is empty."""
        r = self.http.get(f"{self.url}/rest/v1/{table}",
                          params=[("select", "observed_at"), ("order", "observed_at.asc"), ("limit", 1)],
                          headers=self._headers(), timeout=60)
        if r.status_code >= 300:
            raise RuntimeError(f"Supabase read of {table} failed: HTTP {r.status_code} {r.text[:300]}")
        rows = r.json()
        return rows[0]["observed_at"] if rows else None

    def delete_between(self, table, start, end):
        """Deletes rows with start <= observed_at < end (UTC ISO strings)."""
        r = self.http.delete(f"{self.url}/rest/v1/{table}",
                             params=[("observed_at", f"gte.{start}"), ("observed_at", f"lt.{end}")],
                             headers=self._headers({"Prefer": "return=minimal"}), timeout=120)
        if r.status_code >= 300:
            raise RuntimeError(f"Supabase delete from {table} failed: HTTP {r.status_code} {r.text[:300]}")

    def storage_mb(self):
        """Database size in MB (needs the jps_storage_mb function from readings.sql)."""
        r = self.http.post(f"{self.url}/rest/v1/rpc/jps_storage_mb", headers=self._headers(), json={}, timeout=60)
        if r.status_code >= 300:
            raise RuntimeError(f"Supabase size check failed: HTTP {r.status_code} {r.text[:300]}")
        return float(r.json())
