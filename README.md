# YOKI Coffee Staff Attendance System

Single-branch React + Supabase starter for YOKI Coffee.

## Attendance rules
- One night shift: 7:00 PM–3:00 AM (crosses midnight)
- Grace period: 10 minutes
- Late deduction: USD 1/hour, prorated by minute after the grace period
- Timezone: Asia/Phnom_Penh (UTC+7)
- GPS geofence: default 100m; configure the real shop coordinates

## Included
- Employee ID + 4-digit PIN login through Supabase Auth
- QR camera scanner
- GPS capture and database-side geofence validation
- Check In / Check Out
- Overnight shift calculation (12 AM–3 AM belongs to the previous evening's shift)
- Attendance history and monthly deduction summary
- YOKI-only branch configuration

## Setup
1. Create a Supabase project.
2. Run `supabase/schema.sql` in Supabase SQL Editor.
3. Set YOKI's real GPS coordinates in `branches`:
   `update public.branches set latitude=YOUR_LATITUDE, longitude=YOUR_LONGITUDE, allowed_radius_m=100 where name='YOKI Coffee';`
4. In Supabase Authentication, create employee accounts. Add a matching `employees` row for each user, using its Auth UUID, employee code, full name, branch ID for YOKI Coffee, monthly salary, and role. Set one trusted manager to `role='admin'`.
5. Configure QR tokens using a trusted admin/server process: generate a cryptographically random token, store only its SHA-256 hex digest in `qr_tokens.token_hash`, and display the raw token as JSON QR content: `{"token":"RAW_RANDOM_TOKEN"}`. Use short expiry and rotate regularly. QR token admin UI is not included in this starter.
6. Copy `.env.example` to `.env` and add Supabase URL and anon key.
7. Run `npm install` then `npm run dev`.

## Deploy
Deploy to Vercel as a Vite project. Add `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` as environment variables, then redeploy.

## Important
- Never expose Supabase `service_role` key in browser code.
- The starter expects a valid, active QR token before every scan.
- GPS geofencing is a deterrent; some devices can spoof GPS.
- Late deduction is calculated for management review, not automatically paid/deducted. Confirm Cambodian labour-law compliance and review exceptions before applying payroll deductions.
- Before production, add secure admin screens for staff/shift/QR management, approval/audit workflow, testing, and appropriate access controls.

## Employee ID + PIN authentication
The login screen accepts an Employee ID and 4-digit PIN. For this starter, each employee's Supabase Auth account must be provisioned by an administrator with a synthetic email `lowercase_employee_id@yoki-staff.com` and password `<4-digit-PIN>Yoki!` (for example `YOKI001` and `1234` are provisioned as `yoki001@yoki-staff.com` and `1234Yoki!`). Confirm the synthetic email when creating the Auth user. The employee table must reference that Auth user's UUID. Reset PINs by changing the Auth password using the same suffix. Do not give staff the synthetic email or suffix.

A 4-digit PIN is low entropy. Supabase Auth rate limiting helps, but this starter does not implement a dedicated per-account lockout or admin PIN-reset screen. Use controlled account provisioning, monitor failed logins, and consider a longer PIN/passkey before production.

## Shared QR Code (admin)
- Run the updated `supabase/schema.sql` additions in Supabase SQL Editor after the original schema.
- Sign in as an active admin and open the **Shared QR** tab.
- Select **Generate / Renew Shared QR**. The raw QR payload is returned only to the authenticated admin; the database stores only its SHA-256 hash.
- The token expires after 12 hours. Generating a replacement disables the previous active token.
- Keep the QR display inside YOKI Coffee. Employees must log in with their own Employee ID + PIN and pass GPS validation.
