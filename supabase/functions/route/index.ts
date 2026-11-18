// Edge Function: road route to a relief centre. Deploy with:
//   npx supabase functions deploy route --no-verify-jwt
// (The login is checked inside, by the database, so it works with both the
// new and the legacy Supabase keys.) Secret needed: ORS_API_KEY.
import { handleRoute } from '../_shared/route.ts';

Deno.serve((req) => handleRoute(req, { env: (k) => Deno.env.get(k), fetch }));
