-- =====================================================================
-- Security pack (database part): column encryption with pgcrypto.
-- How to use: Supabase dashboard -> SQL Editor -> paste this whole file -> Run.
-- Run it once, AFTER reading_problems.sql.
--
-- FIRST, once per project, make the column key in Supabase Vault (SQL Editor):
--   select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'),
--                              'column_encryption_key');
-- Never paste the key anywhere else. Without it, saving an encrypted field
-- fails with "Column key missing".
--
-- What is encrypted at rest (AES-256 inside OpenPGP, with an integrity check):
--   headcounts.other_need   free text a household types about its needs
--   staff_profiles.phone    staff phone numbers
-- The plain columns stay (always empty) so older app versions keep working.
-- Reading them back goes through functions that apply the same "who may see
-- this row" rules as the row level security in staff_districts.sql.
--
-- Why: a leaked backup, a stolen database dump or a careless table export
-- shows only ciphertext; the key lives in Vault, which is encrypted separately.
-- It does not hide data from someone who can run SQL as the database owner
-- (they can read Vault too); that is what RLS and keeping that role
-- unused are for. See docs: threat model.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- Functions the API must never expose. The API serves only the "public"
-- schema, and nobody but the owner may use this one.
create schema if not exists private;
revoke all on schema private from public;

create function private.column_key() returns text
language plpgsql stable security definer set search_path = ''
as $$
declare k text;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name = 'column_encryption_key';
  if k is null or length(k) < 32 then
    raise exception 'Column key missing: see the top of supabase/security.sql';
  end if;
  return k;
end $$;

create function private.seal(p text) returns bytea
language sql volatile security definer set search_path = ''
as $$ select extensions.pgp_sym_encrypt(p, private.column_key(), 'cipher-algo=aes256, compress-algo=0') $$;

-- Null for null or for bytes that do not open (fails closed, never half-read).
create function private.unseal(p bytea) returns text
language plpgsql stable security definer set search_path = ''
as $$
begin
  if p is null then return null; end if;
  return extensions.pgp_sym_decrypt(p, private.column_key());
exception when others then
  if sqlerrm like 'Column key missing%' then raise; end if;
  return null;
end $$;

revoke execute on function private.column_key(), private.seal(text), private.unseal(bytea) from public;

-- ---------- headcounts.other_need ----------

alter table public.headcounts add column other_need_enc bytea;

-- Runs after headcounts_before_write (triggers run in name order), which has
-- already trimmed the text and cleared it when "Other" is not chosen.
create function public.headcounts_seal_other_need() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.other_need <> '' then
    new.other_need_enc := private.seal(new.other_need);
    new.other_need := '';
  elsif not ('other' = any (new.needs)) or tg_op = 'INSERT' then
    new.other_need_enc := null;
  else
    -- An update without new text (e.g. "Arrived"): keep the stored text.
    -- Never taken from the client, who could otherwise write any bytes here.
    new.other_need_enc := old.other_need_enc;
  end if;
  return new;
end $$;
create trigger headcounts_seal_other_need before insert or update on public.headcounts
  for each row execute function public.headcounts_seal_other_need();

-- Existing rows: encrypt what is there now.
update public.headcounts set other_need = other_need where other_need <> '';

-- The "other" text of one household, for the household itself or staff who
-- cover its centre (the same rule as the hc_read policy). Null otherwise.
create function public.headcount_other_need(p_household uuid) returns text
language sql stable security definer set search_path = ''
as $$
  select coalesce(private.unseal(h.other_need_enc), '')
  from public.headcounts h
  where h.household_id = p_household
    and (h.household_id = (select auth.uid()) or public.staff_covers_centre_id(h.evacuation_point_id))
$$;

-- Same as household_groups.sql, with other_need decrypted.
create or replace function public.headcount_json(p_household uuid) returns json
language sql stable security invoker set search_path = ''
as $$
  select json_build_object(
    'total', h.total, 'babies', h.babies, 'children', h.children, 'adults', h.adults,
    'elderly', h.elderly, 'reduced_mobility', h.reduced_mobility, 'pets', h.pets,
    'daily_medicine', h.daily_medicine, 'power_machine', h.power_machine,
    'needs', to_json(h.needs), 'other_need', coalesce(public.headcount_other_need(h.household_id), ''),
    'status', h.status, 'updated_at', h.updated_at, 'expires_at', h.expires_at,
    'centre_id', h.evacuation_point_id, 'centre_name', e.name)
  from public.headcounts h
  left join public.evacuation_points e on e.id = h.evacuation_point_id
  where h.household_id = p_household
$$;

-- ---------- staff_profiles.phone ----------

alter table public.staff_profiles add column phone_enc bytea;

create function public.staff_profiles_seal_phone() returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.phone is not null and trim(new.phone) = '' then
    new.phone := null;
    new.phone_enc := null; -- an empty number removes it
  elsif new.phone is not null then
    new.phone := regexp_replace(new.phone, '[\s-]', '', 'g');
    if new.phone !~ '^\+?[0-9]{7,15}$' then raise exception 'Phone number is not valid'; end if;
    new.phone_enc := private.seal(new.phone);
    new.phone := null;
  elsif tg_op = 'INSERT' then
    new.phone_enc := null;
  else
    new.phone_enc := old.phone_enc;
  end if;
  return new;
end $$;
create trigger staff_profiles_seal_phone before insert or update on public.staff_profiles
  for each row execute function public.staff_profiles_seal_phone();

-- To remove a stored number: update ... set phone = ''.
update public.staff_profiles set phone = phone where phone is not null;

-- A staff member's own number, or anyone's for a Super Admin. Null otherwise.
create function public.staff_phone(p_staff uuid) returns text
language sql stable security definer set search_path = ''
as $$
  select private.unseal(s.phone_enc)
  from public.staff_profiles s
  where s.id = p_staff
    and (s.id = (select auth.uid()) or public.staff_role() = 'super_admin')
$$;

revoke execute on function public.headcount_other_need(uuid), public.staff_phone(uuid) from public;
grant execute on function public.headcount_other_need(uuid), public.staff_phone(uuid) to authenticated;
