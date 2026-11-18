// Invites a staff member by e-mail and adds them to the business with a role.
// The caller must have the staff.manage permission (checked with the caller's own JWT through has_perm).
// Deploy: supabase functions deploy invite-staff
import { createClient } from 'npm:@supabase/supabase-js@2'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}
const ROLES = ['manager', 'supervisor', 'cashier', 'accountant', 'staff']

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
  try {
    const { tenant_id, email, display_name, role } = await req.json()
    if (!tenant_id || !email || !ROLES.includes(role)) return json({ error: 'tenant_id, email and a valid role are required' }, 400)

    const url = Deno.env.get('SUPABASE_URL')!
    const caller = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } })
    const { data: allowed, error: permErr } = await caller.rpc('has_perm', { p_tenant: tenant_id, p_perm: 'staff.manage' })
    if (permErr || !allowed) return json({ error: 'You are not allowed to manage staff' }, 403)

    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
    let userId: string | undefined
    const invited = await admin.auth.admin.inviteUserByEmail(email, { data: { display_name } })
    if (invited.error) {
      // already registered: look the user up instead
      const { data: list } = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 })
      userId = list?.users.find((u) => u.email?.toLowerCase() === String(email).toLowerCase())?.id
      if (!userId) return json({ error: invited.error.message }, 400)
    } else userId = invited.data.user?.id

    const { error } = await admin.from('memberships').upsert({ tenant_id, user_id: userId, role, display_name: display_name ?? email, is_active: true })
    if (error) return json({ error: error.message }, 400)
    return json({ message: `Invitation sent to ${email}` })
  } catch (e) {
    return json({ error: (e as Error).message }, 500)
  }
})
