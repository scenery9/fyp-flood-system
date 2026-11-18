# Relief centres and resource points

Two files, one row per place. Open them in Excel (save as **CSV UTF-8**) or any text editor.

| File | What it holds |
|---|---|
| `centres.csv` | Relief centres (PPS) shown to the public on the Centres tab |
| `resource_points.csv` | Supply depots for the staff portal (the two now are **DEMO only**) |

**Add** a place: add a row. **Remove** one: delete its row. **Change** one: edit its row
but keep its `code`. Then commit and push to `main`. GitHub Actions
(*Upload relief centres and resource points*) checks every row first and only then makes
Supabase match the files. If a row is wrong, the run fails, names the line, and nothing changes.

Check on your laptop before pushing: `cd logger` then `python -m jps_logger.places check`.

## Columns

| Column | Rule |
|---|---|
| `code` | Unique, capitals, digits and `-` only (e.g. `PPS-SGR-SMK-P-KAPAR`). Never reuse an old code for a different place. |
| `name` | Unique. Shown in the app. |
| `state` | `Selangor` or `Melaka` |
| `district` | Selangor: GOMBAK, HULU LANGAT, HULU SELANGOR, KLANG, KUALA LANGAT, KUALA SELANGOR, PETALING, SABAK BERNAM, SEPANG. Melaka: ALOR GAJAH, JASIN, MELAKA TENGAH. Any letter case. |
| `lat`, `lon` | Decimal degrees. Copy them from Google Maps (right-click the building, click the numbers). A position outside the state is refused. |
| `capacity` | Whole number above 0. A guess is fine if `capacity_is_estimate` is `yes`. |
| `capacity_is_estimate` | `yes` or `no`. With `yes` the app says "about N spaces (estimate)". |
| `location_checked` | `yes` once you have looked at the position on a map. With `no` the centre is listed but gets no map pin and no in-app route, is never suggested as the nearest centre, and Google Maps searches for it by name. |
| `resource_point_code` | Optional: the `code` of the depot in `resource_points.csv` that supplies this centre. |
| `notes` | For you only (where the data came from). Not uploaded. |

## Good to know

- Occupancy and open/closed are not in the files: staff set those, and the upload never changes them.
- A centre that still has people recorded is not removed; the run shows a warning instead.
- Staff cannot change a place from these files in the app (name, position, capacity);
  change it here instead. Places staff add themselves (no code) are never touched by the upload.
- Sources: the five centres are the ones the FloodWatch app showed in November 2026; their
  capacities are FloodWatch's estimates, not official figures.
