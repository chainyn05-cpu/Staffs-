-- YOKI Attendance Security Upgrade (additive migration)
-- Run this file in Supabase SQL Editor. Do NOT rerun schema.sql.
-- No selfie/photo collection is used by this upgrade.

create table if not exists public.employee_devices (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  device_id text not null,
  device_label text,
  user_agent text,
  status text not null default 'pending' check (status in ('pending','approved','blocked')),
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  unique(employee_id, device_id)
);
create unique index if not exists one_approved_device_per_employee
  on public.employee_devices(employee_id) where status = 'approved';

create table if not exists public.attendance_security_events (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid references public.employees(id) on delete set null,
  event_type text not null,
  severity text not null default 'info' check (severity in ('info','warning','critical')),
  device_id text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.employee_devices enable row level security;
alter table public.attendance_security_events enable row level security;
drop policy if exists "admin read employee devices" on public.employee_devices;
create policy "admin read employee devices" on public.employee_devices
  for select to authenticated using (public.is_admin());
drop policy if exists "admin read attendance security events" on public.attendance_security_events;
create policy "admin read attendance security events" on public.attendance_security_events
  for select to authenticated using (public.is_admin());

create or replace function public.register_attendance_device(
  p_device_id text, p_device_label text default null, p_user_agent text default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare emp public.employees%rowtype; dev public.employee_devices%rowtype; new_status text;
begin
  if auth.uid() is null then raise exception 'Please login first'; end if;
  if p_device_id is null or length(trim(p_device_id)) < 12 or length(p_device_id) > 200 then
    raise exception 'Invalid device identifier';
  end if;
  select * into emp from public.employees where user_id = auth.uid() and is_active;
  if not found then raise exception 'Employee account is inactive or missing'; end if;

  select * into dev from public.employee_devices where employee_id = emp.id and device_id = p_device_id;
  if found then
    update public.employee_devices set last_seen_at = now(), device_label = coalesce(p_device_label,device_label),
      user_agent = coalesce(p_user_agent,user_agent) where id = dev.id returning * into dev;
    if dev.status = 'blocked' then
      insert into public.attendance_security_events(employee_id,event_type,severity,device_id,details)
      values(emp.id,'blocked_device_login','warning',p_device_id,jsonb_build_object('device_label',p_device_label));
      return jsonb_build_object('status','blocked','message','This device is blocked');
    end if;
    return jsonb_build_object('status',dev.status,'device_row_id',dev.id);
  end if;

  if emp.role = 'admin' and not exists(select 1 from public.employee_devices where employee_id=emp.id and status='approved') then
    new_status := 'approved';
  else
    new_status := 'pending';
  end if;
  insert into public.employee_devices(employee_id,device_id,device_label,user_agent,status,approved_by,approved_at)
  values(emp.id,p_device_id,p_device_label,p_user_agent,new_status,
    case when new_status='approved' then auth.uid() else null end,
    case when new_status='approved' then now() else null end)
  returning * into dev;
  insert into public.attendance_security_events(employee_id,event_type,severity,device_id,details)
  values(emp.id,'new_device_registered','warning',p_device_id,jsonb_build_object('device_label',p_device_label,'status',new_status));
  return jsonb_build_object('status',dev.status,'device_row_id',dev.id);
end;
$$;

create or replace function public.admin_set_attendance_device(p_device_row_id uuid, p_status text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare target public.employee_devices%rowtype;
begin
  if auth.uid() is null or not public.is_admin() then raise exception 'Admin access required'; end if;
  if p_status not in ('approved','blocked') then raise exception 'Status must be approved or blocked'; end if;
  select * into target from public.employee_devices where id = p_device_row_id for update;
  if not found then raise exception 'Device not found'; end if;
  if p_status = 'approved' then
    update public.employee_devices set status='blocked' where employee_id=target.employee_id and status='approved' and id<>target.id;
  end if;
  update public.employee_devices set status=p_status,
    approved_by=case when p_status='approved' then auth.uid() else approved_by end,
    approved_at=case when p_status='approved' then now() else approved_at end
  where id=target.id;
  insert into public.attendance_security_events(employee_id,event_type,severity,device_id,details)
  values(target.employee_id,case when p_status='approved' then 'device_approved' else 'device_blocked' end,
    'info',target.device_id,jsonb_build_object('changed_by',auth.uid()));
  return jsonb_build_object('success',true,'status',p_status);
end;
$$;

-- New attendance endpoint: validates the approved device, then calls the existing
-- attendance function so the existing QR, GPS, shift, grace-period and payroll logic stays intact.
create or replace function public.record_attendance_scan_secure(
  p_qr_token text, p_lat double precision, p_lng double precision,
  p_accuracy_m integer, p_device_id text
) returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare emp public.employees%rowtype; result jsonb;
begin
  if auth.uid() is null then raise exception 'Please login first'; end if;
  select * into emp from public.employees where user_id=auth.uid() and is_active;
  if not found then raise exception 'Employee account is inactive or missing'; end if;
  if not exists(select 1 from public.employee_devices
    where employee_id=emp.id and device_id=p_device_id and status='approved') then
    insert into public.attendance_security_events(employee_id,event_type,severity,device_id,details)
    values(emp.id,'attendance_blocked_unapproved_device','critical',p_device_id,
      jsonb_build_object('gps_accuracy_m',p_accuracy_m));
    raise exception 'This device is not approved. Please contact your YOKI admin.';
  end if;
  update public.employee_devices set last_seen_at=now()
    where employee_id=emp.id and device_id=p_device_id and status='approved';
  result := public.record_attendance_scan(p_qr_token,p_lat,p_lng,p_accuracy_m);
  return result;
exception when others then
  insert into public.attendance_security_events(employee_id,event_type,severity,device_id,details)
  values(emp.id,'attendance_scan_failed','warning',p_device_id,
    jsonb_build_object('error',sqlerrm,'gps_accuracy_m',p_accuracy_m,'latitude',p_lat,'longitude',p_lng));
  raise;
end;
$$;

revoke all on function public.register_attendance_device(text,text,text) from public;
revoke all on function public.admin_set_attendance_device(uuid,text) from public;
revoke all on function public.record_attendance_scan_secure(text,double precision,double precision,integer,text) from public;
grant execute on function public.register_attendance_device(text,text,text) to authenticated;
grant execute on function public.admin_set_attendance_device(uuid,text) to authenticated;
grant execute on function public.record_attendance_scan_secure(text,double precision,double precision,integer,text) to authenticated;

-- IMPORTANT: after the updated frontend is deployed and confirmed working,
-- run the following two statements to close the legacy RPC bypass:
-- revoke all on function public.record_attendance_scan(text,double precision,double precision,integer) from public;
-- revoke all on function public.record_attendance_scan(text,double precision,double precision,integer) from authenticated;
