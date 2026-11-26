// Tests supabase/security.sql (pgcrypto column encryption) and
// supabase/family.sql (family roster, one registration per family, encrypted
// live location) on a local Postgres (PGlite), after every earlier file.
// Run:  npm install && npm test
import { makeDb, harness, U, q } from './_db.mjs';

const db = await makeDb('family.sql');
const { pub, as, check, done } = harness(db);

const [ADMIN, COORD, OTHER_COORD, ALICE, BOB, CAROL, DAVE, EVE] = [1, 2, 3, 4, 5, 6, 7, 8].map(U);
const RP = U(100), EV = U(200), EV_SEPANG = U(201), RP_SEPANG = U(101);
await db.exec(`
  insert into auth.users select ('00000000-0000-0000-0000-' || lpad(g::text, 12, '0'))::uuid from generate_series(1, 30) g;
  insert into public.resource_points (id, name, lat, lon, district) values
    ('${RP}', 'Depot', 3.04, 101.45, 'KLANG'), ('${RP_SEPANG}', 'Depot S', 2.7, 101.7, 'SEPANG');
  insert into public.evacuation_points (id, name, lat, lon, capacity, occupancy, district, resource_point_id) values
    ('${EV}', 'Hall', 3.041, 101.451, 50, 0, 'KLANG', '${RP}'),
    ('${EV_SEPANG}', 'Sepang Hall', 2.7, 101.7, 50, 0, 'SEPANG', '${RP_SEPANG}');
  insert into public.staff_profiles (id, full_name, username, role, assigned_district, active) values
    ('${ADMIN}', 'Admin', 'admin', 'super_admin', null, true),
    ('${COORD}', 'Coord', 'coord', 'coordinator', 'KLANG', true),
    ('${OTHER_COORD}', 'Coord S', 'coords', 'coordinator', 'SEPANG', true);
`);
const one = (r) => r.rows?.[0] && Object.values(r.rows[0])[0];

// =====================================================================
console.log('SEC1 headcount free text encrypted at rest (pgcrypto)');
const hc = { total: 2, needs: ['other'], other_need: 'halal food, insulin cold box', centre_id: EV, status: 'on_the_way' };
let r = await pub(ALICE, `select public.submit_headcount(${q(hc)}) as j`);
check('the household gets its text back', one(r)?.other_need === 'halal food, insulin cold box', r);
r = await as('postgres', null, `select other_need, other_need_enc is not null as enc,
  position('halal' in encode(other_need_enc, 'escape')) as found from public.headcounts where household_id = '${ALICE}'`);
check('the table holds only ciphertext (plain column empty, no plaintext in the bytes)',
  r.rows?.[0]?.other_need === '' && r.rows[0].enc === true && r.rows[0].found === 0, r);
r = await pub(ALICE, `select public.set_headcount_status('arrived') as j`);
check('"Arrived" keeps the text', one(r)?.other_need === 'halal food, insulin cold box' && one(r)?.status === 'arrived', r);
await pub(ALICE, `update public.headcounts set other_need_enc = '\\xdeadbeef'::bytea where household_id = '${ALICE}'`);
r = await pub(ALICE, `select public.my_headcount() as j`);
check('bytes written by the client into the encrypted column are ignored', one(r)?.other_need === 'halal food, insulin cold box', r);
r = await pub(BOB, `select public.headcount_other_need('${ALICE}') as t`);
check('another household cannot read it', one(r) === null, r);
r = await pub(COORD, `select public.headcount_other_need('${ALICE}') as t`);
check('staff covering the centre can', one(r) === 'halal food, insulin cold box', r);
r = await pub(OTHER_COORD, `select public.headcount_other_need('${ALICE}') as t`);
check('staff in another district cannot', one(r) === null, r);
r = await pub(ALICE, `select private.column_key() as k`);
check('the app cannot call the key function', !!r.error, r);
r = await pub(ALICE, `select decrypted_secret from vault.decrypted_secrets`);
check('the app cannot read Vault', !!r.error, r);
await db.exec(`update vault.decrypted_secrets set decrypted_secret = '${'b'.repeat(64)}'`);
r = await pub(ALICE, `select public.my_headcount() as j`);
check('with a different key the text does not open, and nothing breaks (fails closed)',
  !r.error && one(r)?.other_need === '', r);
await db.exec(`delete from vault.decrypted_secrets`);
r = await pub(BOB, `select public.submit_headcount(${q({ ...hc, other_need: 'x' })})`);
check('with no key, saving secret text is refused', /Column key missing/.test(r.error ?? ''), r);
await db.exec(`insert into vault.decrypted_secrets values ('column_encryption_key', '${'a'.repeat(64)}')`);
r = await pub(ALICE, `select public.submit_headcount(${q({ ...hc, needs: ['power'] })}) as j`);
r = await as('postgres', null, `select other_need_enc from public.headcounts where household_id = '${ALICE}'`);
check('unticking "Other" deletes the stored text', r.rows?.[0]?.other_need_enc === null, r);

console.log('SEC2 staff phone numbers encrypted at rest');
await db.exec(`update public.staff_profiles set phone = '+60 12-345 6789' where id = '${COORD}'`);
r = await as('postgres', null, `select phone, phone_enc is not null as enc from public.staff_profiles where id = '${COORD}'`);
check('stored only encrypted', r.rows?.[0]?.phone === null && r.rows[0].enc, r);
r = await pub(COORD, `select public.staff_phone('${COORD}') as p`);
check('the staff member sees their own (spaces and dashes removed)', one(r) === '+60123456789', r);
r = await pub(ADMIN, `select public.staff_phone('${COORD}') as p`);
check('a Super Admin sees it', one(r) === '+60123456789', r);
r = await pub(OTHER_COORD, `select public.staff_phone('${COORD}') as p`);
check('another coordinator does not', one(r) === null, r);
await db.exec(`update public.staff_profiles set active = active where id = '${COORD}'`);
r = await pub(COORD, `select public.staff_phone('${COORD}') as p`);
check('other updates keep the number', one(r) === '+60123456789', r);
r = await as('postgres', null, `update public.staff_profiles set phone = '12ab' where id = '${COORD}'`);
check('a bad number is refused', /not valid/.test(r.error ?? ''), r);

// =====================================================================
console.log('FAM1 creating a family and adding people');
r = await pub(ALICE, `select public.create_family_group(${q({ name: 'Tan family', display_name: 'Sam', age_category: 'adult', phone_e164: '+60123456789' })}) as j`);
let fam = one(r);
const G = fam?.id, CODE = fam?.invite_code, ME_ALICE = fam?.me;
check('created; Alice is admin; invite code is 12 characters', fam?.members?.[0]?.role === 'admin' && /^[A-Za-z0-9_-]{12}$/.test(CODE), r);
const add = (who, m) => pub(who, `select public.add_family_member(${q(m)}) as id`);
const GRANDMA = one(await add(ALICE, { display_name: 'Grandma Lim', age_category: 'elderly', mobility_aid: true, common_sickness: ['fever'] }));
const AINA = one(await add(ALICE, { display_name: 'Aina', age_category: 'child', phone_e164: '+60111111111', common_sickness: ['asthma'] }));
const KEVIN = one(await add(ALICE, { display_name: 'Kevin', age_category: 'adult', phone_e164: '+60122222222', is_outstation: true }));
check('people with and without a phone are added', !!GRANDMA && !!AINA && !!KEVIN);
r = await add(ALICE, { display_name: 'Aina again', age_category: 'child', phone_e164: '+60111111111' });
check('the same phone number twice is refused', /already in the family/.test(r.error ?? ''), r);
r = await add(ALICE, { display_name: 'Pak Ali', age_category: 'elderly', common_sickness: ['power_machine'] });
check('only everyday sickness can be chosen (no machines or prescriptions)', /Unknown sickness/.test(r.error ?? ''), r);
r = await add(ALICE, { display_name: 'X', age_category: 'teen' });
check('an unknown age group is refused', !!r.error, r);
r = await add(ALICE, { display_name: 'X', age_category: 'adult', phone_e164: '0123456789' });
check('a phone not in +60... form is refused', /\+60123456789/.test(r.error ?? ''), r);

console.log('FAM2 joining by invite: no duplicate people');
r = await pub(BOB, `select public.join_family_group(${q({ code: CODE, phone_e164: '+60111111111', display_name: 'Bob', age_category: 'adult' })}) as j`);
fam = one(r);
check('joining with a number already on the list links that person (no new row)',
  fam?.members?.length === 4 && fam.members.find((m) => m.id === AINA)?.linked === true && fam.me === AINA, r);
check('... and keeps the details the admin entered', fam?.members?.find((m) => m.id === AINA)?.name === 'Aina', fam);
check('a member does not see the invite code', fam?.invite_code === null, fam);
r = await pub(CAROL, `select public.join_family_group(${q({ code: CODE, display_name: 'Carol', age_category: 'adult' })}) as j`);
const ME_CAROL = one(r)?.me;
check('joining without a known number adds a new person', one(r)?.members?.length === 5, r);
r = await pub(DAVE, `select public.join_family_group(${q({ code: 'WRONGCODE123', display_name: 'Dave', age_category: 'adult' })})`);
check('a wrong code is refused', /not valid/.test(r.error ?? ''), r);
await pub(DAVE, `select public.create_family_group(${q({ display_name: 'Dave', age_category: 'adult' })})`);
r = await pub(DAVE, `select public.join_family_group(${q({ code: CODE, display_name: 'Dave', age_category: 'adult' })})`);
check('someone already in another family must leave it first', /Leave your current family/.test(r.error ?? ''), r);
r = await pub(EVE, `select public.join_family_group(${q({ code: CODE, phone_e164: '+60111111111', display_name: 'Eve', age_category: 'adult' })})`);
check('a number already linked cannot be taken by another phone', /already linked/.test(r.error ?? ''), r);

console.log('FAM3 who can change what, and who can see the family');
r = await add(BOB, { display_name: 'Y', age_category: 'adult' });
check('only the admin adds people', /Only the family admin/.test(r.error ?? ''), r);
r = await pub(BOB, `select public.update_family_member('${GRANDMA}', ${q({ display_name: 'Nenek' })})`);
check('a member cannot change someone else', /only change your own/.test(r.error ?? ''), r);
r = await pub(BOB, `select public.update_family_member('${AINA}', ${q({ common_sickness: ['asthma', 'cough'] })}) as j`);
check('a member can change their own details', one(r)?.members?.find((m) => m.id === AINA)?.common_sickness?.join() === 'asthma,cough', r);
r = await pub(DAVE, `select count(*)::int as n from public.family_members where group_id = '${G}'`);
check('outsiders see none of the family', one(r) === 0, r);
r = await pub(BOB, `select count(*)::int as n from public.family_members`);
check('a member sees their own family only', one(r) === 5, r);
r = await pub(BOB, `select invite_code from public.family_groups`);
check('the invite code column cannot be read directly', /permission denied/.test(r.error ?? ''), r);
r = await pub(BOB, `insert into public.family_members (group_id, display_name, age_category) values ('${G}', 'Z', 'adult')`);
check('the tables cannot be written directly', !!r.error, r);
for (let i = 0; i < 5; i++) await add(ALICE, { display_name: `Cousin ${i}`, age_category: 'adult' });
r = await add(ALICE, { display_name: 'One too many', age_category: 'adult' });
check('up to 10 people', /up to 10/.test(r.error ?? ''), r);
const cousins = (await pub(ALICE, `select id from public.family_members where display_name like 'Cousin%'`)).rows.map((x) => x.id);
for (const c of cousins) await pub(ALICE, `select public.remove_family_member('${c}')`);

// =====================================================================
console.log('FAM4 shelter check-in: any linked member, one registration per family');
await pub(CAROL, `select public.submit_headcount(${q({ total: 1, centre_id: EV, status: 'on_the_way' })})`);
const reg = (who, extra) => pub(who, `select public.submit_family_headcount(${q({ lat: 3.04, lon: 101.45, ...extra })}) as j`);
r = await reg(BOB, { member_ids: [ME_ALICE, AINA, KEVIN] });
check('an outstation member cannot be ticked', /Kevin is marked outstation/.test(r.error ?? ''), r);
r = await reg(BOB, { member_ids: [ME_ALICE, AINA, GRANDMA, ME_CAROL], extra_people: 1, pets: 1 });
let h = one(r)?.headcount;
check('a child with the app can register the family', one(r)?.status === 'registered' && h?.registered_by === 'Aina', r);
check('counts come from the roster: 5 people = 2 adults, 1 child, 1 elderly + 1 extra',
  h?.total === 5 && h.adults === 2 && h.children === 1 && h.elderly === 1 && h.babies === 0 && h.extra_people === 1, h);
check('wheelchair and sickness tallied from the people ticked', h?.reduced_mobility === 1
  && h.common_sickness?.fever === 1 && h.common_sickness?.asthma === 1 && h.common_sickness?.cough === 1, h);
check('a centre is assigned', h?.centre_id === EV, h);
r = await pub(CAROL, `select public.my_headcount() as j`);
check('Carol\'s own earlier headcount is closed (she is counted in the family now)', one(r)?.status === 'left', r);
r = await reg(ALICE, { member_ids: [ME_ALICE] });
check('a second member sees the existing registration instead of making another',
  one(r)?.status === 'already_registered' && one(r)?.existing?.registered_by === 'Aina' && one(r)?.existing?.total === 5, r);
r = await as('postgres', null, `select count(*)::int as n from public.headcounts where family_group_id = '${G}' and status in ('on_the_way', 'arrived')`);
check('... and nothing was added', one(r) === 1, r);
r = await reg(ALICE, { member_ids: [ME_ALICE, AINA, GRANDMA], force_update: true });
h = one(r)?.headcount;
check('"Edit existing" updates the same registration', one(r)?.status === 'registered' && h?.total === 3 && h.registered_by === 'Sam', r);
r = await as('postgres', null, `select count(*)::int as n from public.headcounts where family_group_id = '${G}' and status in ('on_the_way', 'arrived')`);
check('still one active registration', one(r) === 1, r);
r = await as('postgres', null, `insert into public.headcounts (household_id, total, family_group_id, status) values ('${EVE}', 1, '${G}', 'on_the_way')`);
check('the database itself refuses a second active registration for a family', /headcounts_one_active_per_family/.test(r.error ?? ''), r);
r = await pub(CAROL, `select public.set_family_headcount_status('arrived') as j`);
check('any member can mark the family arrived', one(r)?.status === 'arrived', r);
r = await pub(DAVE, `select public.my_family_headcount() as j`);
check('another family sees nothing', one(r) === null, r);
r = await pub(DAVE, `select count(*)::int as n from public.headcounts where family_group_id = '${G}'`);
check('... not even through the table', one(r) === 0, r);

// =====================================================================
console.log('FAM5 live location: consent, chosen viewers, ciphertext only');
const ct = Buffer.from('opaque ciphertext and tag bytes here').toString('base64');
const iv = Buffer.alloc(12, 7).toString('base64');
const put = (who, extra = {}) => pub(who, `select public.put_family_location(${q({ ciphertext: ct, iv, key_version: 1, ...extra })})`);
r = await put(BOB);
check('nothing is uploaded before sharing is turned on', /sharing is off/.test(r.error ?? ''), r);
r = await pub(BOB, `select public.set_location_sharing(${q({ enabled: true, hours: 24, viewer_ids: [GRANDMA] })})`);
check('a person without the app cannot be a viewer', /other family members with the app/.test(r.error ?? ''), r);
r = await pub(BOB, `select public.set_location_sharing(${q({ enabled: true, hours: 48, viewer_ids: [ME_ALICE] })})`);
check('at most 24 hours', /1 to 24 hours/.test(r.error ?? ''), r);
r = await pub(BOB, `select public.set_location_sharing(${q({ enabled: true, hours: 24, viewer_ids: [ME_ALICE, ME_CAROL] })}) as j`);
check('sharing on, to Sam and Carol', one(r)?.members?.find((m) => m.id === AINA)?.sharing === true, r);
r = await put(BOB);
check('encrypted location uploaded', !r.error, r);
r = await put(BOB, { key_version: 2 });
check('a location under another key version is refused', /key has changed/.test(r.error ?? ''), r);
r = await put(BOB, { iv: 'short' });
check('a malformed IV is refused', !!r.error, r);
r = await pub(ALICE, `select count(*)::int as n from public.family_locations`);
check('a chosen viewer gets the pin', one(r) === 1, r);
r = await pub(DAVE, `select count(*)::int as n from public.family_locations`);
check('another family does not', one(r) === 0, r);
r = await as('postgres', null, `select string_agg(column_name, ',' order by column_name) as c from information_schema.columns where table_name = 'family_locations'`);
check('the table has no place for coordinates: only ciphertext, IV and bookkeeping',
  one(r) === 'ciphertext,expires_at,group_id,iv,key_version,member_id,updated_at', r);
await pub(CAROL, `select public.update_family_member('${ME_CAROL}', ${q({ is_outstation: true })})`);
r = await pub(CAROL, `select public.set_location_sharing(${q({ enabled: true, viewer_ids: [ME_ALICE] })})`);
check('outstation: location paused', /outstation/.test(r.error ?? ''), r);
r = await pub(BOB, `select public.set_location_sharing(${q({ enabled: false })})`);
r = await pub(ALICE, `select count(*)::int as n from public.family_locations`);
check('turning sharing off deletes the stored pin', one(r) === 0, r);

console.log('FAM6 new invite, removing and leaving');
await pub(BOB, `select public.set_location_sharing(${q({ enabled: true, viewer_ids: [ME_ALICE, ME_CAROL] })})`);
await put(BOB);
r = await pub(BOB, `select public.regenerate_family_invite()`);
check('only the admin renews the invite', /Only the family admin/.test(r.error ?? ''), r);
r = await pub(ALICE, `select public.regenerate_family_invite() as j`);
check('new code and key version', one(r)?.invite_code !== CODE && one(r)?.key_version === 2, r);
r = await as('postgres', null, `select count(*)::int as n from public.family_locations where group_id = '${G}'`);
check('locations under the old key are deleted', one(r) === 0, r);
r = await pub(EVE, `select public.join_family_group(${q({ code: CODE, display_name: 'Eve', age_category: 'adult' })})`);
check('the old code no longer works', /not valid/.test(r.error ?? ''), r);
r = await pub(ALICE, `select public.remove_family_member('${ME_CAROL}') as j`);
check('the admin removes Carol', one(r)?.members?.length === 4, r);
r = await as('postgres', null, `select allowed_viewer_ids from public.family_members where id = '${AINA}'`);
check('... and she is taken off every viewer list', !r.rows?.[0]?.allowed_viewer_ids?.includes(ME_CAROL), r);
r = await pub(CAROL, `select public.my_family() as j`);
check('Carol is no longer in a family', one(r) === null, r);
await pub(ALICE, `select public.leave_family_group()`);
r = await pub(BOB, `select public.my_family() as j`);
check('when the admin leaves, a member with the app becomes admin',
  one(r)?.members?.find((m) => m.is_me)?.role === 'admin' && typeof one(r)?.invite_code === 'string', r);
await pub(BOB, `select public.leave_family_group()`);
r = await as('postgres', null, `select count(*)::int as n from public.family_groups where id = '${G}'`);
check('when nobody with the app is left, the family is deleted', one(r) === 0, r);

done();
