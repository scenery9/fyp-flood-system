# Test plan: app screens and navigation (TP43–TP62)

Continues the numbering in the main README (TP1–TP42). **Auto** cases run with
`flutter test` (app) or `dart test` (flood_core). **Manual** cases need a real Android
phone because they use the fingerprint prompt, the phone dialer, SMS, Google Maps or
TalkBack. All data is SAMPLE data (Segamat stations, made-up relief centres, practice
forecast).

How to run:

    cd packages/flood_core
    dart test test/preparedness_test.dart test/forecast_fields_test.dart   # TP44-TP46, TP60
    cd ../../app
    flutter pub get
    flutter test                                 # TP43, TP47-TP59, TP57b, TP61, TP62

Test household used by the app tests: 4 people, someone 60+, daily medicine, lift
from family or neighbour (no own car). Saved areas: Kg. Awat (Danger), Buloh Kasap
(Alert), Kajang (Normal).

## Summary

| Plan | What it checks | File | Auto | Manual |
|---|---|---|---|---|
| TP43 | Household lock screens (reached from More) | app/test/widget_test.dart | 6 | M1–M3 |
| TP44 | Household profile model | flood_core/test/preparedness_test.dart | 5 | – |
| TP45 | Personalised checklist rules | flood_core/test/preparedness_test.dart | 8 | – |
| TP46 | Checklist progress and saving | flood_core/test/preparedness_test.dart | 8 | – |
| TP47 | First launch: household form | app/test/ui_test.dart | 3 | – |
| TP48 | Bottom menu (4 tabs) | app/test/ui_test.dart | 3 | M4 |
| TP49 | Home area card: arrows, dots, swipe | app/test/ui_test.dart | 4 | – |
| TP50 | Saved areas: change, remove, add, limit | app/test/ui_test.dart | 4 | – |
| TP51 | AI forecast and "Why does the AI say this?" | app/test/ui_test.dart | 3 | – |
| TP52 | Station detail: save, copy to share | app/test/ui_test.dart | 1 | M5 |
| TP53 | Prepare checklist: levels, ticks, clear | app/test/ui_test.dart | 4 | – |
| TP54 | Step by step (one page per item) | app/test/ui_test.dart | 3 | – |
| TP55 | Household details hidden until unlocked | app/test/ui_test.dart | 3 | M1 |
| TP56 | Household form: limits and choices | app/test/ui_test.dart | 2 | – |
| TP57 | Centres: map, layers, directions | app/test/ui_test.dart | 3 | M6 |
| TP58 | SOS: hold, tap sheet, SMS location | app/test/ui_test.dart | 5 | M7, M8 |
| TP57b | Route inside the app (street map, steps) | app/test/ui_test.dart | 3 | M13, M14 |
| TP59 | More: text size, contrast, language, alerts, info pages | app/test/ui_test.dart | 6 | M9–M12 |
| TP60 | Forecast fields for translated AI text | flood_core/test/forecast_fields_test.dart | 2 | – |
| TP61 | Read aloud for the AI forecast | app/test/ui_test.dart | 4 | M15 |
| TP62 | Phone location with sample fallback | app/test/ui_test.dart | 3 | M16 |

## Cases

### TP43 Household lock screens
| ID | Steps | Expected |
|---|---|---|
| 43.1 | More > Household and transport (first visit) > Not now | Question shown, then details; no phone prompt |
| 43.2 | Turn on, go back, open again | One phone prompt only, details both times |
| 43.3 | Lock on, prompt fails, then Unlock with prompt passing | "Household details are locked", then details |
| 43.4 | Tick "Don't ask me again" > Not now; restart app | Not asked again |
| 43.5 | Lock on, phone has no screen lock > Skip for now | Set-up message, then details |
| 43.6 | More > Lock switch off with failed prompt, then passing prompt, then on | Stays on with message; turns off; turns on |

### TP44 Household profile
| ID | Steps | Expected |
|---|---|---|
| 44.1 | New profile | 1 person, own car, no needs |
| 44.2 | Save and read back | Same values |
| 44.3 | Damaged saved values | Defaults used |
| 44.4 | People 0, 31, 30 | 0 and 31 fall back to 1; 30 kept |
| 44.5 | Transport lift / none / motorcycle | Lift and none need help to leave |

### TP45 Personalised checklist
| ID | Steps | Expected |
|---|---|---|
| 45.1 | Each level, no profile | Every level has items |
| 45.2 | Household with every need | Ids unique, start with the level name |
| 45.3 | No profile | No personal items, no reasons |
| 45.4 | Daily medicine | Medicine items with "Because someone needs daily medicine" |
| 45.5 | No own transport | Driver items and "Leave early"; no "Move your vehicle" |
| 45.6 | Own car | "Move your vehicle"; no driver items |
| 45.7 | Older adult, child, mobility aid, pet | Each adds its items |
| 45.8 | Malay / Chinese, household with every need | Every item, how-to and reason has its own Malay and Chinese text |

### TP46 Checklist progress and saving
| ID | Steps | Expected |
|---|---|---|
| 46.1 | Before the form is saved | No profile, not skipped |
| 46.2 | Save, restart | Same profile |
| 46.3 | People 0, 31, 1, 30 | 0 and 31 refused with a message |
| 46.4 | Skip, then save, then skip | Skip remembered until saved; ignored after |
| 46.5 | Tick, untick, restart | Only ticked items kept |
| 46.6 | Unknown item id | Refused |
| 46.7 | Damaged saved list | Unknown ids ignored |
| 46.8 | Clear one level | Other levels kept |

### TP47 First launch
| ID | Steps | Expected |
|---|---|---|
| 47.1 | Start with no household saved | "About your household" form; no menu |
| 47.2 | Save and continue | Profile saved; Home opens |
| 47.3 | Skip for now | Home opens; skip remembered |

### TP48 Bottom menu
| ID | Steps | Expected |
|---|---|---|
| 48.1 | Tap Home, Prepare, Centres, More | Each tab's own screen |
| 48.2 | Measure each tab | At least 48 x 48 |
| 48.3 | Home > Go to relief centre; More > Relief centres | Centres tab opens |

### TP49 Home area card
| ID | Steps | Expected |
|---|---|---|
| 49.1 | Open Home | Kg. Awat: "Danger", 19.97 m, "Danger from 19.95 m" |
| 49.2 | Next arrow, previous arrow, third dot | Area 2, area 1, area 3; no next arrow on the last |
| 49.3 | Swipe left on the card | Next area |
| 49.4 | No saved areas > Add an area | Message, then Saved areas page |

### TP50 Saved areas
| ID | Steps | Expected |
|---|---|---|
| 50.1 | Change area > tap Buloh Kasap | Back on Home showing Buloh Kasap |
| 50.2 | Remove Kajang | Removed from saved list |
| 50.3 | Add an area > search "segamat kecil" > Add | Only matching stations; added |
| 50.4 | 5 areas saved | Add button turned off |

### TP51 AI forecast and explanation
| ID | Steps | Expected |
|---|---|---|
| 51.1 | Home forecast card | Summary, "Likely between 19.90 m and 20.18 m", practice label |
| 51.2 | Why does the AI say this? > How the prediction works | Reasons with up/down meaning; explanation page |
| 51.3 | Area with old data and no forecast | "No recent data"; "No forecast for this area right now" |

### TP52 Station detail
| ID | Steps | Expected |
|---|---|---|
| 52.1 | High risk now > Buloh Kasap > Save > Copy status | 35.0 mm/h shown; saved; clipboard has "Status: Alert (Waspada)" |

### TP53 Prepare checklist
| ID | Steps | Expected |
|---|---|---|
| 53.1 | Open Prepare (area at Danger) | "When river is at Danger", "0 of 2 done" (3 safety cards not counted), household item listed |
| 53.2 | Tap Alert | Alert list, "0 of 7 done", driver item |
| 53.3 | Tick an item; Clear ticks > Clear | "1 of 2 done" and saved; asks first; back to 0 |
| 53.4 | Home checklist card | Same progress; Open checklist goes to Prepare |

### TP54 Step by step
| ID | Steps | Expected |
|---|---|---|
| 54.1 | Item 1 done > Go step by step > Mark as done | Opens on "Step 2 of 2"; summary page; saved |
| 54.2 | Skip, Back, Skip to the end > Back to checklist | Steps 1-2-1; summary "5 still to do"; back to list |
| 54.3 | Tap the third item in the list | Opens on "Step 3 of 5" |

### TP55 Household details on Prepare
| ID | Steps | Expected |
|---|---|---|
| 55.1 | Open Prepare (locked) | "4 people", "Details hidden for privacy", no reasons |
| 55.2 | Show > phone prompt passes > back | Needs, transport and reasons now shown |
| 55.3 | Lock turned off | Details shown, no prompt |

### TP56 Household form
| ID | Steps | Expected |
|---|---|---|
| 56.1 | Minus at 1; plus 29 times | Minus off at 1; stops at 30, plus off |
| 56.2 | Has a pet + No transport > Save | Saved; Warning list gains "Bring your pet" |

### TP57 Centres
| ID | Steps | Expected |
|---|---|---|
| 57.1 | Open Centres > Directions in Google Maps | Nearest open centre (SK Buloh Kasap) chosen; Google Maps link to it |
| 57.2 | Tap Dewan Jementah in list; tap the Kg. Awat pin | Card shows "Opens only if…"; then "No space left…" |
| 57.3 | Rain layer; Highest risk; 30 km; River layer; tap a river pin | Nearest first within 10 km (35.0 mm/h, not 65.0); heaviest first; "8.00 m → 8.52 m ↑" with a % bar; station page |

### TP57b Route inside the app
| ID | Steps | Expected |
|---|---|---|
| 57b.1 | Centres > Show route > Open in Google Maps | "6.2 km · about 12 min by car", next step and all steps with distances; Google Maps link |
| 57b.2 | Route service fails > Try again | "Could not get the road route…"; route shows after retry |
| 57b.3 | No openrouteservice key > Prepare > Show route | "Road route inside the app is not set up yet." and Google Maps button |

### TP58 SOS
| ID | Steps | Expected |
|---|---|---|
| 58.1 | Tap SOS > Call 999 now | Dialer opened with 999; "Add emergency contact" offered |
| 58.2 | Hold SOS 2 seconds | Dialer opened with 999 |
| 58.3 | Hold under 1 second | Nothing called |
| 58.4 | Contact saved > SOS > Text my location | SMS to contact with Google Maps link |
| 58.5 | Dialer cannot open | Message to dial 999 yourself |

### TP59 More and settings
| ID | Steps | Expected |
|---|---|---|
| 59.1 | Text size Large | Text 1.3x; saved |
| 59.2 | High contrast on | White background theme |
| 59.3 | Default; Bahasa Melayu; 中文 | English by default; menu in Malay; menu, AI summary and checklist in Chinese |
| 59.4 | Notify me from > Danger only | Saved |
| 59.5 | Emergency numbers > call 994; contact "abc"; contact "012-345 6789" | Dialer with 994; refused; saved |
| 59.6 | How the prediction works, Where the data comes from, About, Saved areas | Each page opens and goes back |

### TP60 Forecast fields
| ID | Steps | Expected |
|---|---|---|
| 60.1 | Forecast file with 3 factors, one tiny | Current level given; kept factors in the same order as the reasons; tiny one dropped |
| 60.2 | No factors | Empty list |

### TP61 Read aloud
| ID | Steps | Expected |
|---|---|---|
| 61.1 | Home forecast card > Read aloud | Speaks name, summary, range, reasons and disclaimer in the app language |
| 61.2 | More > Slower speech on > Why page > Read aloud | Spoken slowly; setting saved |
| 61.3 | More > Read aloud off | No speaker buttons; saved |
| 61.4 | Phone has no voice for the language | Message on how to add a voice |

### TP62 Location
| ID | Steps | Expected |
|---|---|---|
| 62.1 | Phone location available | No notice; distances from the phone |
| 62.2 | Permission refused > Use my location (now allowed) | Notice with sample point; asks again; notice goes |
| 62.3 | Location blocked for the app > Open settings | Phone's app settings open |

### TP75 Alerts without setup
| ID | Steps | Expected |
|---|---|---|
| 75.1 | Open the app (sample data) | "FloodReady" at the top; no alert banner |
| 75.2 | More > Alerts near you now | Now: Kg. Awat and Segamat Kecil; expected: Buloh Kasap "Warning expected"; tap a row opens the station |
| 75.3 | Notify me from Danger | Only Kg. Awat listed |

### TP76 Route kept on the phone
| ID | Steps | Expected |
|---|---|---|
| 76.1 | Open the app; route service then fails; Centres > Show route > Update route | Route saved after Home loaded; "No internet: showing the route saved…" with the same route |
| 76.2 | Bahasa Melayu; Show route | Next step "Mula di Jalan Awat"; steps in Malay; Read aloud reads from the next step |
| 76.3 | Centres list | "6.2 km · 12 min drive" once the route is known |
| 76.4 | Open with space only | Full and closed centres hidden |

### TP77 Report flooding
| ID | Steps | Expected |
|---|---|---|
| 77.1 | Home > Report flooding > Knee > Send report | "Near Kg. Awat, Segamat"; saved; My reports shows "Flooding seen · Being checked" |
| 77.2 | Damage | Send off until what and how bad are chosen; time "1 hour ago" kept |
| 77.3 | Location off > Send report | Asks to pick the place on the map |

### TP78 Headcount
| ID | Steps | Expected |
|---|---|---|
| 78.1 | Centres > Tell this centre we're coming > Not now > Adults + > Oxygen or machine on > Send | 4 people, 1 aged 60+, 1 adult, daily medicine and machine; "1 of 4 counted" before; sent to SK Buloh Kasap; Arrived; Remove asks first |
| 78.2 | 2 people: +60+, +baby; then People − | Every group + stops at the total; lowering the total gives "1 of 1 counted" |

### TP79 Fewer things to type
| ID | Steps | Expected |
|---|---|---|
| 79.1 | Household form: 2 people > Adults + > Babies + > Pets + > machine on > Save | "2 of 2 counted"; Children + off; saved 1 baby, 1 adult, 1 pet, machine |
| 79.4 | Prepare at Danger | Three tinted safety cards with no tick box; Call 999 opens the phone app with 999 |
| 79.5 | Prepare > Warning | Go-bag item shows "What to bring" including medicine for 7 days |
| 79.2 | Emergency numbers > Choose from contacts | Number from the phone's contacts saved |
| 79.3 | Add an area; Centres > River > star | Distances shown, nearest first; star saves the station |

### TP88 Location when the app opens
| ID | Steps | Expected |
|---|---|---|
| 88.1 | First launch, location not allowed > Allow location | "Use your location?" first; phone pop-up only after Allow; used from then on |
| 88.2 | Not now; reopen; tick Don't ask me again > Not now; reopen | Asked again on the second launch; not on the third |
| 88.3 | Agreed before, Android "Only this time" ended; reopen | Only the phone pop-up, no FloodReady screen |
| 88.4 | Pull to refresh with location not allowed | No pop-up |
| 88.5 | Blocked for good; Centres > Open settings | No question at launch; button opens the phone settings |
| 88.6 | More > Use my location automatically off, then on | Off: "You chose not to use your location", GPS not used; on: phone asked |

### TP89 Forecast as now and later
| ID | Steps | Expected |
|---|---|---|
| 89.1 | Home forecast card | "Now 19.97 m → By (time) 20.04 m"; "Rising slowly (+7 cm)" with "2 cm above the Danger line" smaller on the next line; Read aloud says the same |

## Manual checks on a real phone

| ID | Steps | Expected | Pass / fail |
|---|---|---|---|
| M1 | Prepare > Show with real fingerprint; then with wrong finger | Opens after real fingerprint; stays hidden after a failed one | |
| M2 | Close the app fully and reopen; Prepare | Details hidden again until checked | |
| M3 | Phone with no screen lock; lock turned on | Set-up message explains Settings > Security | |
| M4 | TalkBack on: swipe through Home and the menu | Each tab read as "Home, selected", etc.; risk word and icon read; SOS read with its hint | |
| M5 | Station detail > Share status > WhatsApp | WhatsApp opens with the status text, then pick a chat | |
| M6 | Centres > Directions | Google Maps opens with the route to the centre | |
| M7 | SOS hold 2 s (use a test phone with no SIM, or cancel before connecting) | Dialer shows 999 | |
| M8 | SOS > Text my location | SMS app opens with number and map link | |
| M9 | Text size Large, phone font size largest | No text cut off on Home, Prepare, Centres, More | |
| M10 | High contrast on | All text readable outdoors in sunlight | |
| M11 | Turn on "Remove animations" in Android settings | Menu highlight and step pages change without sliding | |
| M12 | Airplane mode, reopen app; tap Open in Google Maps | Sample data still shows; Google Maps opens (it may say it is offline) | |
| M13 | Run with SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY in secrets.json (README Round 6) > Centres > Show route | Real road line on the street map; steps match the road | |
| M14 | Street map | Tiles load; "© OpenStreetMap contributors" visible and opens the copyright page | |
| M15 | Read aloud in English, Malay and 中文 | Each speaks in its language; if a voice is missing, the message shows | |
| M16 | First launch: allow location; then deny in phone settings and reopen | Real distances; then the sample-point notice | |
| M17 | Live build: More > Notify me from > Turn on phone notifications > Allow | Note says notifications are on; Supabase table device_tokens has one row | |
| M18 | Station page > Alert me at a river level > pick the level the river is already above; close the app; wait up to 30 min | A phone notification arrives with the station, the level and your alert level | |
| M19 | Turn notifications off for the app in phone settings, reopen More > Notify me from | Note says notifications are blocked and how to turn them on | |
| M20 | Staff accounts: a Coordinator for KLANG signs in (SQL or staff screens later) | Sees only KLANG centres, depots, stock and damage reports | |
| M21 | Live build, first launch | Asked once to allow notifications; More > Notify me from shows Warning | |
| M22 | Show route online; airplane mode; reopen the route | Same route shows with "No internet: showing the route saved…" | |
| M23 | Report flooding > Somewhere else > tap the map > Use this place > Send | Report appears in My reports; Supabase damage_reports has kind "sighting" | |
| M24 | Emergency numbers > Choose from contacts | Phone's contact list opens; the number tapped is saved | |
| M25 | Tell this centre we're coming > Send > Arrived; Supabase headcounts | One row with the needs and status "arrived" | |
| M26 | Fresh install > Allow location > "Only this time"; close the app fully; reopen | Only Android's pop-up shows again (no FloodReady screen) | |
| M27 | Fresh install > "Don't allow" twice on Android's pop-up; reopen | No pop-up; Centres button opens the app's permission page | |
| M28 | Allow with "Approximate" (Android 12+) | App still works; nearest station from the rough position | |
