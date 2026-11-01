import React, { useEffect, useMemo, useState } from 'react';
import { createClient } from '@supabase/supabase-js';
import { Html5QrcodeScanner } from 'html5-qrcode';
import { MapPin, ScanLine, Clock3, Users, Wallet, LogOut, ShieldCheck, QrCode } from 'lucide-react';
import { QRCodeSVG } from 'qrcode.react';

const url = import.meta.env.VITE_SUPABASE_URL;
const anon = import.meta.env.VITE_SUPABASE_ANON_KEY;
const supabase = url && anon ? createClient(url, anon) : null;
const money = n => '$' + Number(n || 0).toFixed(2);

export default function App() {
  const [session, setSession] = useState(null);
  const [profile, setProfile] = useState(null);
  const [tab, setTab] = useState('attendance');
  const [branch, setBranch] = useState('BAT AFTER');
  const [status, setStatus] = useState('');
  const [busy, setBusy] = useState(false);
  const [records, setRecords] = useState([]);
  const [staff, setStaff] = useState([]);
  const [employeeCode, setEmployeeCode] = useState('');
  const [pin, setPin] = useState('');
  const [month, setMonth] = useState(new Date().toISOString().slice(0,7));
  const [qrOpen, setQrOpen] = useState(false);
  const [sharedQrPayload, setSharedQrPayload] = useState('');
  const [sharedQrExpiresAt, setSharedQrExpiresAt] = useState('');
  const [creatingQr, setCreatingQr] = useState(false);

  useEffect(() => {
    if (!supabase) return;
    supabase.auth.getSession().then(({data}) => setSession(data.session));
    const { data: listener } = supabase.auth.onAuthStateChange((_e,s) => setSession(s));
    return () => listener.subscription.unsubscribe();
  }, []);

  useEffect(() => {
  if (!session || !supabase) {
    setProfile(null);
    return;
  }

  supabase
    .from('employees')
    .select('*, branches(name)')
    .eq('user_id', session.user.id)
    .maybeSingle()
    .then(({ data, error }) => {
      if (error) {
        setProfile(null);
        setStatus(error.message);
        return;
      }

      if (!data) {
        setProfile(null);
        setStatus('Employee profile not found. Please contact admin.');
        return;
      }

      setProfile(data);
      setBranch(data.branches?.name || 'YOKI Coffee');
      setStatus('');
    });
}, [session]);

  useEffect(() => {
    if (!profile || !supabase) return;
    loadData();
  }, [profile, month]);

  async function loadData() {
    const {data,error} = await supabase.from('attendance')
      .select('*, employees(full_name, employee_code, branches(name))')
       .gte('check_in', `${month}-01T00:00:00`).lt('check_in', new Date(Number(month.slice(0,4)), Number(month.slice(5,7)), 1).toISOString())
      .order('check_in', {ascending:false}).limit(500);
    if (!error) setRecords(data || []);
    if (profile?.role === 'admin') {
      const r = await supabase.from('employees').select('*, branches(name)').order('full_name');
      if (!r.error) setStaff(r.data || []);
    }
  }

  async function login(e) {
    e.preventDefault();
    if (!/^\d{4}$/.test(pin)) { setStatus('PIN ត្រូវមាន 4 ខ្ទង់'); return; }
    const code = employeeCode.trim().toUpperCase();
    if (!/^[A-Z0-9_-]{3,20}$/.test(code)) { setStatus('សូមបញ្ចូល Employee ID ឱ្យបានត្រឹមត្រូវ'); return; }
    setBusy(true); setStatus('');
    // Employee ID is mapped to a synthetic Supabase Auth email.
    // The PIN is combined with an app suffix to satisfy Supabase password-length rules.
    const syntheticEmail = `${code.toLowerCase()}@yoki-staff.com`;
    const authPassword = `${pin}Yoki!`;
    const {error} = await supabase.auth.signInWithPassword({email:syntheticEmail,password:authPassword});
    setBusy(false); if(error) setStatus('Employee ID ឬ PIN មិនត្រឹមត្រូវ ឬគណនីមិនទាន់បង្កើត');
  }
  async function logout() { await supabase?.auth.signOut(); setProfile(null); }

  async function createSharedQr() {
    if (!isAdmin) return;
    setCreatingQr(true);
    setStatus('កំពុងបង្កើត Shared QR Code...');
    const { data, error } = await supabase.rpc('create_shared_qr_token');
    setCreatingQr(false);
    if (error) { setStatus(error.message); return; }
    setSharedQrPayload(data?.payload || '');
    setSharedQrExpiresAt(data?.expires_at || '');
    setStatus('បានបង្កើត Shared QR Code ថ្មី។ QR ចាស់ត្រូវបានបិទ។');
  }

  async function getPosition() {
    return new Promise((resolve,reject) => {
      if (!navigator.geolocation) return reject(new Error('ឧបករណ៍នេះមិនគាំទ្រ GPS'));
      navigator.geolocation.getCurrentPosition(
        p => resolve({lat:p.coords.latitude,lng:p.coords.longitude,accuracy:p.coords.accuracy}),
        e => reject(new Error('មិនអាចចាប់ទីតាំងបាន៖ ' + e.message)),
        {enableHighAccuracy:true,timeout:15000,maximumAge:0}
      );
    });
  }

  async function submitScan(payload) {
    if (!supabase || !profile) return;
    setBusy(true); setStatus('កំពុងផ្ទៀងផ្ទាត់ QR និង GPS...');
    try {
      const pos = await getPosition();
      const parsed = typeof payload === 'string' ? JSON.parse(payload) : payload;
      const {data,error} = await supabase.rpc('record_attendance_scan', {
        p_qr_token: parsed.token,
        p_lat: pos.lat,
        p_lng: pos.lng,
        p_accuracy_m: Math.round(pos.accuracy)
      });
      if (error) throw error;
      setStatus(data?.message || 'បានរក្សាទុក Attendance');
      await loadData();
    } catch(e) { setStatus(e.message || 'Scan មិនជោគជ័យ'); }
    finally { setBusy(false); setQrOpen(false); }
  }

  useEffect(() => {
    if (!qrOpen) return;
    const scanner = new Html5QrcodeScanner('qr-reader', {fps:10, qrbox:{width:230,height:230}}, false);
    scanner.render(decoded => { scanner.clear().catch(()=>{}); submitScan(decoded); }, () => {});
    return () => { scanner.clear().catch(()=>{}); };
  }, [qrOpen]);

  const totalDeduction = useMemo(() => records.reduce((s,r)=>s+Number(r.deduction_amount||0),0),[records]);
  const isAdmin = profile?.role === 'admin';

  if (!supabase) return <main className="setup"><div className="panel"><h1>Employee Attendance</h1><p>សូមភ្ជាប់ Supabase ជាមុនសិន។</p><ol><li>បង្កើត Supabase Project</li><li>Run <code>supabase/schema.sql</code> ក្នុង SQL Editor</li><li>ចម្លង <code>.env.example</code> ទៅជា <code>.env</code> ហើយបញ្ចូល Project URL និង Anon Key</li><li>Run <code>npm install</code> និង <code>npm run dev</code></li></ol></div></main>;

  if (!session) return <main className="login-wrap"><form className="login panel" onSubmit={login}><div className="logo">Y</div><p className="eyebrow">YOKI COFFEE · STAFF SYSTEM</p><h1>Welcome Back</h1><p className="muted">ចូលប្រើប្រព័ន្ធបុគ្គលិក YOKI</p><label>Employee ID<input type="text" autoCapitalize="characters" autoComplete="username" value={employeeCode} onChange={e=>setEmployeeCode(e.target.value.toUpperCase())} placeholder="ឧ. YOKI001" required /></label><label>4-Digit PIN<input type="password" inputMode="numeric" autoComplete="current-password" maxLength={4} pattern="[0-9]{4}" value={pin} onChange={e=>setPin(e.target.value.replace(/\D/g,'').slice(0,4))} placeholder="••••" required /></label><button disabled={busy}>{busy?'កំពុងចូល...':'Login'}</button>{status&&<p className="notice">{status}</p>}</form></main>;

  if (!profile) return <main className="setup"><div className="panel">កំពុងផ្ទុកព័ត៌មានបុគ្គលិក... {status}</div></main>;

  return <div className="app">
    <aside className="sidebar"><div className="brand"><div className="logo">EA</div><div><b>YOKI ATTENDANCE</b><small>STAFF SYSTEM</small></div></div>
      <nav><button className={tab==='attendance'?'active':''} onClick={()=>setTab('attendance')}><ScanLine/> Attendance</button>
      {isAdmin&&<><button className={tab==='staff'?'active':''} onClick={()=>setTab('staff')}><Users/> Employees</button><button className={tab==='qr'?'active':''} onClick={()=>setTab('qr')}><QrCode/> Shared QR</button><button className={tab==='payroll'?'active':''} onClick={()=>setTab('payroll')}><Wallet/> Payroll Report</button></>}</nav>
      <div className="side-bottom"><span><ShieldCheck size={16}/> {profile.role}</span><button className="logout" onClick={logout}><LogOut size={17}/> Logout</button></div>
    </aside>
    <main className="content">
      <header><div><p className="eyebrow">YOKI COFFEE · YOKI STAFF SYSTEM</p><h1>{tab==='attendance'?'Attendance':tab==='staff'?'Employees':'Monthly Payroll'}</h1></div><div className="user"><span>{profile.full_name}</span><b>{profile.employee_code}</b></div></header>
      {status&&<div className="notice">{status}</div>}
      {tab==='attendance'&&<><section className="stats"><Stat icon={<Clock3/>} label="Grace Period" value="10 min"/><Stat icon={<Wallet/>} label="Late Rate" value="$1 / hour"/><Stat icon={<MapPin/>} label="GPS Check" value="Required"/></section>
        <section className="panel scan-panel"><div><p className="eyebrow">TODAY'S YOKI ATTENDANCE</p><h2>ស្កេន QR Code ដើម្បីចូល / ចេញ</h2><p className="muted">សូមបើក Location និងអនុញ្ញាត Camera មុនពេល Scan។</p><button onClick={()=>setQrOpen(!qrOpen)} disabled={busy}><ScanLine size={18}/>{qrOpen?'បិទ Scanner':'Start QR Scanner'}</button></div><div className="scan-icon"><ScanLine size={58}/></div></section>
        {qrOpen&&<section className="panel"><div id="qr-reader"></div><p className="muted">ដាក់ QR Code របស់ហាងនៅក្នុងស៊ុម។</p></section>}
        <section className="panel"><div className="section-head"><h2>Attendance History</h2><input type="month" value={month} onChange={e=>setMonth(e.target.value)}/></div><AttendanceTable rows={records.filter(r=>isAdmin||r.employee_id===profile.id)} isAdmin={isAdmin}/></section>
      </>}
      {tab==='staff'&&<section className="panel"><h2>Employee Directory</h2><div className="table-wrap"><table><thead><tr><th>Employee</th><th>Code</th><th>Branch</th><th>Role</th><th>Salary</th></tr></thead><tbody>{staff.map(s=><tr key={s.id}><td>{s.full_name}</td><td>{s.employee_code}</td><td>{s.branches?.name}</td><td>{s.role}</td><td>{money(s.monthly_salary)}</td></tr>)}</tbody></table></div><p className="muted">បង្កើត / កែ Employee Account តាម Supabase Dashboard ក្នុងជំនាន់ Starter នេះ។</p></section>}
      {tab==='qr'&&isAdmin&&<section className="panel">
        <p className="eyebrow">YOKI COFFEE · ADMIN ONLY</p>
        <h2>Shared Attendance QR Code</h2>
        <p className="muted">បង្កើត QR មួយសម្រាប់បុគ្គលិកទាំងអស់ Scan នៅហាង។ QR នីមួយៗមានសុពលភាព 12 ម៉ោង ហើយការបង្កើត QR ថ្មីនឹងបិទ QR ចាស់។</p>
        <button onClick={createSharedQr} disabled={creatingQr}>{creatingQr?'កំពុងបង្កើត...':'Generate / Renew Shared QR'}</button>
        {sharedQrPayload&&<div className="shared-qr-card">
          <QRCodeSVG value={sharedQrPayload} size={280} level="H" includeMargin />
          <p><b>YOKI Coffee Shared QR</b></p>
          <p className="muted">សុពលភាព៖ រហូតដល់ Admin ប្តូរ QR</p>
          <p className="muted">បង្ហាញ QR នេះនៅហាង។ បុគ្គលិក Login ដោយ Employee ID + PIN នៅលើទូរស័ព្ទរបស់ខ្លួន រួច Scan QR នេះ។</p>
        </div>}
      </section>}
      {tab==='payroll'&&<section className="panel"><div className="section-head"><div><h2>Monthly Deduction Summary</h2><p className="muted">សរុបសម្រាប់ខែ {month}</p></div><input type="month" value={month} onChange={e=>setMonth(e.target.value)}/></div><div className="payroll-total"><span>Total recorded deductions</span><strong>{money(totalDeduction)}</strong></div><AttendanceTable rows={records} isAdmin={true}/><p className="muted">ត្រូវពិនិត្យ និងអនុម័តមុនបញ្ចូលក្នុងប្រាក់ខែ។</p></section>}
      <footer>YOKI Coffee · Internal Staff System</footer>
    </main>
  </div>;
}
function Stat({icon,label,value}) {return <div className="stat panel"><span>{icon}</span><div><small>{label}</small><b>{value}</b></div></div>}
function AttendanceTable({rows,isAdmin}) {return <div className="table-wrap"><table><thead><tr>{isAdmin&&<th>Employee</th>}<th>Check In</th><th>Check Out</th><th>Late</th><th>Deduction</th><th>Status</th></tr></thead><tbody>{rows.length?rows.map(r=><tr key={r.id}>{isAdmin&&<td>{r.employees?.full_name||'—'}</td>}<td>{new Date(r.check_in).toLocaleString()}</td><td>{r.check_out?new Date(r.check_out).toLocaleString():'—'}</td><td>{r.late_minutes||0} min</td><td className="red">{money(r.deduction_amount)}</td><td><span className="pill">{r.check_out?'Completed':'Checked In'}</span></td></tr>):<tr><td colSpan={isAdmin?6:5} className="empty">មិនទាន់មានទិន្នន័យ</td></tr>}</tbody></table></div>}
