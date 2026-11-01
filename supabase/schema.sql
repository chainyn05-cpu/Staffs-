-- YOKI Coffee Attendance System
-- Run in Supabase SQL Editor. Configure the real YOKI GPS coordinates before launch.
create extension if not exists pgcrypto;

create table if not exists public.branches (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  latitude double precision,
  longitude double precision,
  allowed_radius_m integer not null default 100 check (allowed_radius_m between 20 and 1000),
  created_at timestamptz not null default now()
);

insert into public.branches(name) values ('YOKI Coffee')
on conflict (name) do nothing;

-- Remove legacy sample branches if this project was initialized from the multi-branch starter.
delete from public.branches where name in ('BAT AFTER','PUZZLE','POS TRAIN');

create table if not exists public.employees (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references auth.users(id) on delete set null,
  branch_id uuid not null references public.branches(id),
  employee_code text not null unique,
  full_name text not null,
  role text not null default 'staff' check (role in ('staff','admin')),
  monthly_salary numeric(10,2) not null default 0 check (monthly_salary >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.shifts (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches(id),
  name text not null,
  start_time time not null,
  end_time time not null,
  grace_minutes integer not null default 10 check (grace_minutes between 0 and 120),
  late_rate_per_hour numeric(8,2) not null default 1.00 check (late_rate_per_hour >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- YOKI standard night shift: 7:00 PM to 3:00 AM next day.
insert into public.shifts(branch_id,name,start_time,end_time,grace_minutes,late_rate_per_hour,active)
select id,'YOKI Night Shift','19:00','03:00',10,1.00,true
from public.branches where name='YOKI Coffee'
and not exists (select 1 from public.shifts s join public.branches b on b.id=s.branch_id where b.name='YOKI Coffee' and s.name='YOKI Night Shift');

create table if not exists public.qr_tokens (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches(id),
  token_hash text not null unique,
  expires_at timestamptz not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.attendance (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id),
  branch_id uuid not null references public.branches(id),
  shift_id uuid references public.shifts(id),
  check_in timestamptz not null default now(),
  check_out timestamptz,
  late_minutes integer not null default 0,
  deduction_amount numeric(10,2) not null default 0,
  check_in_lat double precision,
  check_in_lng double precision,
  check_in_accuracy_m integer,
  check_out_lat double precision,
  check_out_lng double precision,
  check_out_accuracy_m integer,
  created_at timestamptz not null default now()
);
create unique index if not exists one_open_shift_per_employee
on public.attendance(employee_id) where check_out is null;

create table if not exists public.attendance_audit (
  id uuid primary key default gen_random_uuid(),
  attendance_id uuid not null references public.attendance(id),
  changed_by uuid references auth.users(id),
  action text not null,
  old_data jsonb,
  new_data jsonb,
  created_at timestamptz not null default now()
);

alter table public.branches enable row level security;
alter table public.employees enable row level security;
alter table public.shifts enable row level security;
alter table public.qr_tokens enable row level security;
alter table public.attendance enable row level security;
alter table public.attendance_audit enable row level security;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.employees where user_id=auth.uid() and role='admin' and is_active); $$;

drop policy if exists "employees read own or admin" on public.employees;
create policy "employees read own or admin" on public.employees for select to authenticated
using (user_id=auth.uid() or public.is_admin());
drop policy if exists "branches authenticated read" on public.branches;
create policy "branches authenticated read" on public.branches for select to authenticated using (true);
drop policy if exists "shifts authenticated read" on public.shifts;
create policy "shifts authenticated read" on public.shifts for select to authenticated using (true);
drop policy if exists "attendance own or admin read" on public.attendance;
create policy "attendance own or admin read" on public.attendance for select to authenticated
using (employee_id in (select id from public.employees where user_id=auth.uid()) or public.is_admin());
drop policy if exists "audit admin read" on public.attendance_audit;
create policy "audit admin read" on public.attendance_audit for select to authenticated using (public.is_admin());

-- Short-lived QR payload format: {"token":"RAW_RANDOM_TOKEN"}.
-- Store only SHA-256 hex digest in qr_tokens.token_hash.
create or replace function public.record_attendance_scan(
  p_qr_token text, p_lat double precision, p_lng double precision, p_accuracy_m integer
) returns jsonb
language plpgsql security definer set search_path=public
as $$
declare
  emp public.employees%rowtype;
  br public.branches%rowtype;
  sh public.shifts%rowtype;
  tok public.qr_tokens%rowtype;
  open_row public.attendance%rowtype;
  now_local timestamp;
  shift_start timestamp;
  shift_end timestamp;
  distance_m double precision;
  late_m integer;
  deduction numeric(10,2);
  token_digest text;
begin
  if auth.uid() is null then raise exception 'Please login first'; end if;
  if p_lat is null or p_lng is null or p_accuracy_m is null then raise exception 'GPS location is required'; end if;
  if p_accuracy_m > 100 then raise exception 'GPS accuracy is too low. Try again outside.'; end if;

  select * into emp from public.employees where user_id=auth.uid() and is_active;
  if not found then raise exception 'Employee account is inactive or missing'; end if;
  select * into br from public.branches where id=emp.branch_id;
  if not found or br.name <> 'YOKI Coffee' then raise exception 'Employee is not assigned to YOKI Coffee'; end if;
  if br.latitude is null or br.longitude is null then raise exception 'YOKI GPS location has not been configured'; end if;

  token_digest := encode(digest(p_qr_token,'sha256'),'hex');
  select * into tok from public.qr_tokens where token_hash=token_digest and branch_id=br.id
    and active and expires_at > now() order by created_at desc limit 1;
  if not found then raise exception 'QR code is invalid or expired'; end if;

  distance_m := 6371000 * 2 * asin(sqrt(
    power(sin(radians(p_lat-br.latitude)/2),2) +
    cos(radians(br.latitude))*cos(radians(p_lat))*power(sin(radians(p_lng-br.longitude)/2),2)
  ));
  if distance_m > br.allowed_radius_m then raise exception 'You are outside the allowed YOKI attendance area'; end if;

  select * into open_row from public.attendance where employee_id=emp.id and check_out is null limit 1;
  if found then
    update public.attendance set check_out=now(), check_out_lat=p_lat, check_out_lng=p_lng,
      check_out_accuracy_m=p_accuracy_m where id=open_row.id;
    return jsonb_build_object('type','check_out','message','YOKI Check Out recorded successfully');
  end if;

  select * into sh from public.shifts where branch_id=br.id and active
    order by created_at desc limit 1;
  if not found then raise exception 'YOKI night shift is not configured'; end if;

  now_local := now() at time zone 'Asia/Phnom_Penh';
  shift_start := date_trunc('day',now_local) + sh.start_time;
  shift_end := date_trunc('day',now_local) + sh.end_time;
  if sh.end_time < sh.start_time then
    shift_end := shift_end + interval '1 day';
    -- Between midnight and 3 AM belongs to the shift that began the previous evening.
    if now_local::time < sh.end_time then
      shift_start := shift_start - interval '1 day';
      shift_end := shift_end - interval '1 day';
    end if;
  end if;

  -- Permit early arrivals up to 4 hours before shift start; reject scans outside this shift window.
  if now_local < shift_start - interval '4 hours' or now_local > shift_end then
    raise exception 'YOKI attendance is available from 3:00 PM until 3:00 AM';
  end if;

  late_m := greatest(0, floor(extract(epoch from (now_local-shift_start))/60)::int - sh.grace_minutes);
  deduction := round((late_m::numeric / 60) * sh.late_rate_per_hour,2);

  insert into public.attendance(employee_id,branch_id,shift_id,late_minutes,deduction_amount,
    check_in_lat,check_in_lng,check_in_accuracy_m)
  values(emp.id,br.id,sh.id,late_m,deduction,p_lat,p_lng,p_accuracy_m);
  return jsonb_build_object('type','check_in','message','YOKI Check In recorded successfully',
    'late_minutes',late_m,'deduction_amount',deduction);
end; $$;

grant execute on function public.record_attendance_scan(text,double precision,double precision,integer) to authenticated;


-- Admin-only shared QR issuer. Raw token is returned once; only its hash is stored.
create or replace function public.create_shared_qr_token()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_branch_id uuid;
  v_raw_token text;
  v_expires_at timestamptz;
begin
  if auth.uid() is null or not public.is_admin() then
    raise exception 'Only an active YOKI admin can create the shared QR code';
  end if;

  select id into v_branch_id from public.branches where name = 'YOKI Coffee';
  if v_branch_id is null then raise exception 'YOKI Coffee branch not found'; end if;

  update public.qr_tokens set active = false
  where branch_id = v_branch_id and active = true;

  v_raw_token := encode(gen_random_bytes(32), 'hex');
  v_expires_at := now() + interval '12 hours';

  insert into public.qr_tokens(branch_id, token_hash, expires_at, active)
  values (v_branch_id, encode(digest(v_raw_token, 'sha256'), 'hex'), v_expires_at, true);

  return jsonb_build_object(
    'payload', jsonb_build_object('token', v_raw_token)::text,
    'expires_at', v_expires_at
  );
end;
$$;

revoke all on function public.create_shared_qr_token() from public;
grant execute on function public.create_shared_qr_token() to authenticated;
