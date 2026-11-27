# Plan up to the performance analysis (week 10) and panel demo

The supervisor's requests, turned into dated steps. Week numbers are project weeks: **week 3
is 23-29 Nov 2026** (now).

| Week | Dates | What happens |
|---|---|---|
| Week 3 | 23-29 Nov 2026 | New scores added (done, below) |
| Weeks 4-8 | 30 Nov 2026 - 3 Jan 2027 | Data keeps being collected; the items below are built |
| Week 9 | 4-10 Jan 2027 | **Test week** (held out: the model is never trained on it) |
| Week 10 | 11-17 Jan 2027 | **Performance analysis** (due Fri 15 Jan) and panel preparation |

**Assumption, to confirm with the supervisor:** data collection started on 17 Nov 2026, and the
analysis is in week 10. So the **training data** is **17 Nov 2026 to 3 Jan 2027 (about 7 weeks)** and the
**test data** is **week 9**. Week 10 itself can't be the test week, because it isn't finished by
15 Jan.

---

## Done (week 3)

- [x] **The guessed water level is scored with regression (prediction) metrics only**
      ([metrics.py](../ml/flood_ml/metrics.py)):
  - MAE and RMSE (usual size of a wrong guess)
  - NSE (Nash & Sutcliffe 1970)
  - Willmott's d (Willmott 1981)
  - PI, persistence index (Kitanidis & Bras 1980)
  - bias (too high or too low on average) and peak error (miss at the highest point)

  Classification metrics were removed: accuracy, precision, recall, F1, AUC and the confusion
  matrices. What each score means,
  its source and the first results: [literature.md](literature.md).

## 1. Charts for three areas (weeks 9-10)

For each area, use the station(s) **closest to where people live, or whose flooding affects the
most people**. Final choice in week 9: each station must have at least 90% of its hourly
readings.

| Area | Possible stations | Why |
|---|---|---|
| Shah Alam | **Taman Sri Muda** (Sg. Klang); Batu Tiga or TTDI Jaya (Sg. Damansara) | Taman Sri Muda is a busy housing area next to the Klang River, and was the worst hit in the Dec 2021 floods |
| Klang | **Bandar Klang** (Sg. Klang, town centre); Tugu Keris (Sg. Rasah) | Town centre. Tugu Keris has already gone above Alert in our data |
| Melaka | **Sg. Duyong** (Melaka city); Sg. Melaka at Melaka Pindah | River through the city. Melaka Pindah has already gone above Danger in our data |

For each chosen station, for both **3 hours and 24 hours ahead**:
- [ ] A chart of the real and the guessed water level over week 9, with the Normal, Alert,
      Warning and Danger lines.
- [ ] A scatter plot of each guess against the real value, with the 1:1 line (where a perfect
      guess would sit).
- [ ] A table of all the scores, next to the "no change" (persistence) baseline, so the panel can see how much
      better the model is.
- [ ] One command (a new `flood_ml` script) that makes all the charts and tables for the report.

**"The guessed line must touch the real line."** This is a goal to work towards. It can't be
forced:
- The 3-hour line will follow the real line closely. The 24-hour line is harder and will drift
  more. We show both and explain why.
- We must not adjust the model using the test week. That would make the test unfair, and a panel
  can spot it. Any improvement uses weeks 1-8 only.
- What helps: more weeks of data, and better guesses at the highest points (peak error is now about
  0.5 m).

## 2. Catching floods one day early: simulated floods in week 9 (weeks 9-10)

- [ ] If real floods happen in week 9, use them. A real flood means JKR reports an incident and
      a nearby JPS station reaches Warning.
- [ ] If not, create **two simulated floods** in week 9, clearly labelled as simulations. Each is
      copied from a real heavy-rain event in the past: its rain and river readings are replayed
      at a chosen station (scenario replay).
- [ ] The pass rule is fixed **before** testing: **one day before** each flood, the flood chance
      is 80% or more, and the guessed level reaches Warning. We also record when the warning
      first appeared, and any false alarms that week.
- [ ] If the model misses: say so, improve it using weeks 1-8 only, and test again. Never adjust
      it using the test week.
- [ ] A chart for the panel: river level, rain and flood chance over the days before each flood,
      with the "warned one day early" moment marked.

## 3. Alerts (weeks 5-8)

- [ ] **Alerts at the user's chosen level.** Users already pick Alert, Warning or Danger (or a
      water height) for each station. Check that it works from start to finish: when the river
      reaches that level, the user's phone gets the push notification with the right message.
- [ ] **Flood alerts go to the admin first (new).** When a station's flood chance is 80% or
      more:
  - Staff for that district see it in the staff app: the station, the %, the reasons and a
    water-level chart.
  - Staff either **approve and send** it, or dismiss it and give a reason. Users who follow that
    area, or live in that district, then get the alert, marked as sent by staff. Nothing goes to
    users without staff approving it.
  - A new Supabase table with row-level security (RLS): only staff for that district can approve.
    Every send and every dismissal is recorded (audit log).

## 4. Panel demo (week 10)

- [ ] Week 9 charts for the three areas (3 and 24 hours ahead) and the score table.
- [ ] The two simulated floods, warned one day early.
- [ ] A user getting an alert at the level they chose.
- [ ] The admin getting an 80%+ flood alert, approving it, and the user receiving it.
