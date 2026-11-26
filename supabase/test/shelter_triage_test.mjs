// Tests supabase/shelter.sql (family allocation, supplies needed) and
// supabase/report_triage.sql (anti-spam, credibility, clusters) on a local
// Postgres (PGlite), after every earlier file.
// Run:  npm install && npm test
import { makeDb, harness, U, q } from './_db.mjs';

const db = await makeDb('report_triage.sql');
const { pub, as, check, done } = harness(db);
const one = (r) => r.rows?.[0] && Object.values(r.rows[0])[0];

const [ADMIN, COORD, FIELD, OTHER_COORD] = [1, 2, 3, 9].map(U);
const FAMS = [4, 5, 6, 7, 8].map(U);
const RP = U(100), RP_S = U(101), A = U(200), B = U(201), C = U(202), FAR = U(203);
await db.exec(`
  insert into auth.users select ('00000000-0000-0000-0000-' || lpad(g::text, 12, '0'))::uuid from generate_series(1, 60) g;
  insert into public.resource_points (id, name, lat, lon, district) values
    ('${RP}', 'Depot Klang', 3.04, 101.45, 'KLANG'), ('${RP_S}', 'Depot Sepang', 2.7, 101.7, 'SEPANG');
  insert into public.staff_profiles (id, full_name, username, role, assigned_district, assigned_resource_point_id, active) values
    ('${ADMIN}', 'Admin', 'admin', 'super_admin', null, null, true),
    ('${COORD}', 'Coord', 'coord', 'coordinator', 'KLANG', null, true),
    ('${FIELD}', 'Field', 'field', 'field_officer', null, '${RP}', true),
    ('${OTHER_COORD}', 'Coord S', 'coords', 'coordinator', 'SEPANG', null, true);
  -- One site, three halls: A at the family's door but nearly full, no ramp;
  -- C 0.6 km, roomy, no ramp, takes pets; B 1.7 km, roomy, ramp.
  insert into public.evacuation_points (id, name, hall_group, lat, lon, capacity, occupancy, district, resource_point_id,
      has_wheelchair_ramp, pet_friendly) values
    ('${A}', 'PPS Sri Muda Dewan A', 'PPS Sri Muda', 3.040, 101.450, 20, 18, 'KLANG', '${RP}', false, false),
    ('${B}', 'PPS Sri Muda Dewan B', 'PPS Sri Muda', 3.050, 101.461, 50, 10, 'KLANG', '${RP}', true, false),
    ('${C}', 'PPS Sri Muda Dewan C', 'PPS Sri Muda', 3.045, 101.452, 40, 5, 'KLANG', '${RP}', false, true),
    ('${FAR}', 'Far Hall', null, 2.7, 101.7, 500, 0, 'SEPANG', '${RP_S}', true, true);
  insert into public.jps_stations (station_code, name, district, lat, lon, has_river_level, wl_normal, wl_alert, wl_warning, wl_danger) values
    ('T-RIVER', 'Test river', 'KLANG', 3.041, 101.451, true, 1.0, 2.0, 2.5, 3.0),
    ('T-RAIN', 'Test rain', 'KLANG', 2.90, 101.30, false, null, null, null, null);
`);
const [ALICE, BOB, CAROL, DAN, EVE] = FAMS;
async function family(who, members) {
  const f = (await pub(who, `select public.create_family_group(${q({ display_name: 'Me', age_category: 'adult' })}) as j`)).rows[0].j;
  const ids = [f.me];
  for (const m of members) ids.push((await pub(who, `select public.add_family_member(${q(m)}) as id`)).rows[0].id);
  return ids;
}
const register = (who, ids, extra = {}) =>
  pub(who, `select public.submit_family_headcount(${q({ member_ids: ids, lat: 3.040, lon: 101.450, ...extra })}) as j`);

// =====================================================================
console.log('SH1 a family with a wheelchair user, kept together');
const aliceFam = await family(ALICE, [
  { display_name: 'Grandma', age_category: 'elderly', mobility_aid: true, common_sickness: ['fever'] },
  { display_name: 'Kid', age_category: 'child', common_sickness: ['asthma'] }]);
let r = await register(ALICE, aliceFam);
let h = one(r)?.headcount;
check('Dewan A (full) and Dewan C (no ramp) are passed over; all 3 go to Dewan B', h?.centre_id === B && h.total === 3, r);
check('the reason is given', /^Assigned to PPS Sri Muda Dewan B \(1\.7 km\)/.test(h?.allocation_note ?? '')
  && /Dewan A: full \(18 of 20/.test(h.allocation_note) && /Dewan C: no wheelchair ramp/.test(h.allocation_note)
  && /Dewan B has wheelchair ramp access/.test(h.allocation_note), h?.allocation_note);

console.log('SH2 a centre that would be over 90% full is used only if nothing else fits');
const bobFam = await family(BOB, [{ display_name: 'Wife', age_category: 'adult' }]);
r = await register(BOB, bobFam);
h = one(r)?.headcount;
check('2 people fit Dewan A exactly (20/20) but go to Dewan C', h?.centre_id === C, h);
check('... and the note says why', /Dewan A: would be 100% full/.test(h?.allocation_note ?? ''), h?.allocation_note);

console.log('SH3 the family\'s own choice');
const carolFam = await family(CAROL, []);
r = await register(CAROL, carolFam, { centre_id: B });
check('a choice that fits stands', one(r)?.headcount?.centre_id === B && /^Your choice/.test(one(r)?.headcount?.allocation_note), r);
await pub(CAROL, `select public.set_family_headcount_status('left')`);
r = await register(CAROL, carolFam, { centre_id: A });
h = one(r)?.headcount;
check('a choice that is nearly full is redirected, with the reason', h?.centre_id !== A && /Dewan A: would be 95% full/.test(h?.allocation_note ?? ''), h);

console.log('SH4 people on the way count against capacity');
await db.exec(`update public.evacuation_points set occupancy = 46 where id = '${B}'`); // + Alice's 3 on the way = 49 of 50
const danFam = await family(DAN, [{ display_name: 'Dad', age_category: 'elderly', mobility_aid: true }]);
r = await register(DAN, danFam);
h = one(r)?.headcount;
check('Dewan B now too full (49 + 2 > 50): the next hall with a ramp is used, even 45 km away',
  h?.centre_id === FAR && /Dewan B: full \(49 of 50/.test(h.allocation_note), h);
await db.exec(`update public.evacuation_points set is_open = false where id = '${FAR}'`);
r = await pub(DAN, `select public.allocate_family_shelter(3.040, 101.450) as j`);
check('no hall with a ramp and space within 150 km: none assigned, and it says so', one(r)?.centre_id === null
  && /No open centre within 150 km has space for 2 people with wheelchair access/.test(one(r)?.allocation_note), r);
await db.exec(`update public.evacuation_points set occupancy = 10 where id = '${B}'`);
r = await pub(DAN, `select public.allocate_family_shelter(3.040, 101.450) as j`);
check('"Try again" after space frees up assigns Dewan B', one(r)?.centre_id === B, r);
r = await pub(DAN, `select public.assign_family_centre('${ALICE}', null, 3.0, 101.0)`);
check('the app cannot run the allocation for another household', !!r.error, r);

console.log('SH5 flood hazard near a centre');
await db.exec(`insert into public.jps_river_levels values ('T-RIVER', now() - interval '20 minutes', 3.2)`);
r = await as('postgres', null, `select private.centre_hazard(3.040, 101.450) as z`);
check('river at Danger within 5 km: hazard 1', Number(one(r)) === 1, r);
r = await as('postgres', null, `select private.centre_hazard(2.7, 101.7) as z`);
check('no gauge within 5 km: hazard 0', Number(one(r)) === 0, r);
await db.exec(`delete from public.jps_river_levels; insert into public.jps_river_levels values ('T-RIVER', now() - interval '4 hours', 3.2)`);
r = await as('postgres', null, `select private.centre_hazard(3.040, 101.450) as z`);
check('a reading older than 3 hours is not used', Number(one(r)) === 0, r);

console.log('SH6 supplies needed vs in stock');
await db.exec(`insert into public.inventory_items (resource_point_id, name, quantity, supply_kind) values
  ('${RP}', 'Bottled water (L)', 5, 'water_l'), ('${RP}', 'Blankets', 100, 'blanket'),
  ('${RP}', 'Wheelchair', 1, 'wheelchair'), ('${RP}', 'Rice (kg)', 50, null)`);
r = await pub(COORD, `select kind, required::float, in_stock::float, deficit::float from public.shelter_supply_demand where resource_point_id = '${RP}' order by kind`);
const need = Object.fromEntries((r.rows ?? []).map((x) => [x.kind, x]));
// Active: Alice 3 (1 elderly+wheelchair+fever, 1 child asthma, 1 adult), Bob 2 adults, Carol 1 adult, Dan 2 (1 elderly+wheelchair)
check('water = people x 3 (8 people: 24 L), 19 L short', need.water_l?.required === 24 && need.water_l.deficit === 19, need.water_l);
check('blankets = people, enough in stock', need.blanket?.required === 8 && need.blanket.deficit === 0, need.blanket);
check('sanitary packs = ceil(children and adults x 0.5) = ceil(6 x 0.5) = 3', need.sanitary_pack?.required === 3, need.sanitary_pack);
check('wheelchairs = people using one (2), 1 short', need.wheelchair?.required === 2 && need.wheelchair.deficit === 1, need.wheelchair);
check('first-aid kits = common sickness count (2), none in stock', need.first_aid_kit?.required === 2 && need.first_aid_kit.deficit === 2, need.first_aid_kit);
r = await pub(OTHER_COORD, `select count(*)::int as n from public.shelter_supply_demand where resource_point_id = '${RP}'`);
check('staff in another district do not see it', one(r) === 0, r);
r = await pub(ALICE, `select count(*)::int as n from public.shelter_supply_demand`);
check('the public does not see it', one(r) === 0, r);
r = await pub(FIELD, `update public.evacuation_points set has_wheelchair_ramp = true where id = '${A}'`);
check('field officers cannot change access details', /only change occupancy/.test(r.error ?? ''), r);

// =====================================================================
console.log('TR1 credibility: JPS fact support and crowd consensus');
await db.exec(`delete from public.jps_river_levels; insert into public.jps_river_levels values ('T-RIVER', now() - interval '30 minutes', 2.4)`);
const R = [20, 21, 22, 23, 24, 25, 26].map(U);
const ago = (m) => new Date(Date.now() - m * 60e3).toISOString();
let n = 0;
const report = (who, extra = {}) => pub(who, `select public.submit_flood_report(${q({ kind: 'damage', type: 'road', severity: 'severe',
  lat: 3.0412, lon: 101.4512, occurred_at: ago(10), client_ref: `triage-${++n}-ref`, description: '', ...extra })}) as id`);
const score = async (id) => (await as('postgres', null,
  `select fact_support, consensus, credibility_score, corroborated, reporter_distance_km from public.damage_reports where id = '${id}'`)).rows[0];
let s = await score(one(await report(R[0], { reporter_lat: 3.0420, reporter_lon: 101.4520 })));
check('river above Alert within 5 km, reporter near: 50 fact, no others yet', s.fact_support === 50 && s.consensus === 0 && !s.corroborated, s);
check('only the distance to the pin is kept', s.reporter_distance_km > 0 && s.reporter_distance_km < 0.2, s);
s = await score(one(await report(R[1], { lat: 3.0440, lon: 101.4530, reporter_lat: 3.0441, reporter_lon: 101.4531 })));
check('a second phone, same type within 1 km: 75, CORROBORATED', s.credibility_score === 75 && s.corroborated, s);
s = await score(one(await report(R[2], { type: 'house', description: 'water entering houses on Jalan Sri Muda',
  reporter_lat: 3.0412, reporter_lon: 101.4512 })));
check('different type and no similar text: no consensus', s.consensus === 0, s);
s = await score(one(await report(R[3], { type: 'vehicle', description: 'Water entering the houses at Jalan Sri Muda!',
  reporter_lat: 3.0412, reporter_lon: 101.4512 })));
check('different type but similar description (pg_trgm): counts', s.consensus === 25, s);
s = await score(one(await report(R[4], { reporter_lat: 3.5, reporter_lon: 101.9 })));
check('reporter ~60 km away: no official points, never CORROBORATED', s.fact_support === 0 && s.consensus === 50 && !s.corroborated, s);
s = await score(one(await report(R[5])));
check('no reporter location: no official points', s.fact_support === 0 && s.reporter_distance_km === null, s);
await db.exec(`insert into public.jps_rainfall (station_code, observed_at, hourly_mm) values
  ('T-RAIN', now() - interval '5 minutes', 10), ('T-RAIN', now() - interval '65 minutes', 8), ('T-RAIN', now() - interval '125 minutes', 6)`);
s = await score(one(await report(R[6], { lat: 2.901, lon: 101.301, occurred_at: ago(1), reporter_lat: 2.901, reporter_lon: 101.301 })));
check('24 mm in 3 hours at the nearest rain gauge: 50 fact', s.fact_support === 50, s);

console.log('TR2 anti-spam and tamper guards');
for (let i = 0; i < 2; i++) await report(R[0]);
r = await report(R[0]);
check('a 4th report in an hour from one phone is refused', /up to 3 reports an hour/.test(r.error ?? ''), r);
r = await pub(R[5], `insert into public.damage_reports (lat, lon, incident_date, kind, depth_band, credibility_score, corroborated, fact_support)
  values (3.04, 101.45, current_date, 'sighting', 'knee', 100, true, 50) returning credibility_score, corroborated`);
check('a score sent by the client is ignored', r.rows?.[0]?.credibility_score < 100 && r.rows[0].corroborated === false, r);
const r4 = (await as('postgres', null, `select id from public.damage_reports where reporter_id = '${R[4]}'`)).rows[0].id;
await pub(COORD, `update public.damage_reports set status = 'verified', credibility_score = 100, corroborated = true where id = '${r4}'`);
s = await score(r4);
check('a review cannot change the score', s.credibility_score === 50 && !s.corroborated, s);

console.log('TR3 clusters for staff');
r = await pub(COORD, `select reports::int, reporters::int, severe::int, corroborated::int, priority::int, district from public.report_clusters()`);
const top = r.rows?.[0];
check('reports at the same place and half hour form one cluster, top of the list', top?.reports >= 5 && top.district === 'KLANG', r);
r = await pub(R[0], `select count(*)::int as n from public.report_clusters()`);
check('the public gets no clusters', one(r) === 0, r);

console.log('TR4 10,000 reports: clustering stays fast');
await db.exec(`set session_replication_role = replica;  -- bulk load without the per-report triggers
  insert into public.damage_reports (reporter_id, lat, lon, incident_date, occurred_at, kind, type, severity, depth_band, district, credibility_score)
  select ('00000000-0000-0000-0000-' || lpad((30 + g % 30)::text, 12, '0'))::uuid,
         3.0 + (g % 40) * 0.004 + random() * 0.002, 101.4 + (g % 25) * 0.004 + random() * 0.002,
         current_date, now() - make_interval(mins => (g % 600)), 'damage', 'road',
         (array['minor', 'moderate', 'severe'])[1 + g % 3], 'knee', 'KLANG', (g % 101)
  from generate_series(1, 10000) g;
  set session_replication_role = origin;
  analyze public.damage_reports;`);
const t0 = performance.now();
r = await pub(COORD, `select count(*)::int as n from public.report_clusters(now() - interval '12 hours', 1000)`);
const ms = performance.now() - t0;
console.log(`      10,000 reports -> ${one(r)} clusters in ${ms.toFixed(0)} ms (PGlite/WASM; a real server is faster)`);
check('10,000 reports collapse into far fewer clusters', one(r) > 0 && one(r) < 2500, r);
check('in under 2 seconds even on PGlite', ms < 2000, ms);

done();
