-- cutout.lol v1 schema (free-first: tickets are earned, not bought)
create extension if not exists pg_cron;

create table entities (
  id text primary key,                 -- slug, e.g. 'prabhas'
  name text not null, nick text, category text not null default 'heroes',
  industry text, is_pan_india boolean default false, color text,
  art_url text, poster_url text, active boolean default true,
  tonight int not null default 0, week int not null default 0, all_time bigint not null default 0,
  rank_night_start int, rank_week_start int
);

create table profiles (
  id uuid primary key references auth.users on delete cascade,
  display_name text not null, city text, wallet int not null default 0,
  last_daily date, shares_today int default 0, shares_day date,
  referred_by uuid references profiles(id), created_at timestamptz default now()
);

create table ledger (              -- immutable record of every ticket movement
  id bigserial primary key, user_id uuid references profiles(id),
  kind text not null check (kind in ('earn','give','adjust')),
  source text not null, amount int not null, entity_id text references entities(id),
  created_at timestamptz default now()
);
create index on ledger(entity_id, created_at);
create index on ledger(user_id, created_at);

create table follows (user_id uuid references profiles(id) on delete cascade, entity_id text references entities(id), primary key(user_id, entity_id));

create table night_results (day date, entity_id text references entities(id), rank int, tickets int, primary key(day, entity_id));
create table week_results (week_end date, entity_id text references entities(id), rank int, tickets int, primary key(week_end, entity_id));

create table ticket_uploads (
  id bigserial primary key, user_id uuid references profiles(id), entity_id text references entities(id),
  image_path text, booking_hash text unique, first_day boolean default false,
  status text default 'pending' check (status in ('pending','approved','rejected')), created_at timestamptz default now()
);

-- Give tickets: one atomic step, server-side only
create or replace function give_tickets(p_entity text, p_amount int, p_source text default 'give')
returns json language plpgsql security definer set search_path=public as $$
declare w int;
begin
  if p_amount <= 0 or p_amount > 500 then raise exception 'bad amount'; end if;
  update profiles set wallet = wallet - p_amount where id = auth.uid() and wallet >= p_amount returning wallet into w;
  if w is null then raise exception 'not enough tickets'; end if;
  update entities set tonight = tonight + p_amount, week = week + p_amount, all_time = all_time + p_amount where id = p_entity and active;
  if not found then raise exception 'unknown entity'; end if;
  insert into ledger(user_id, kind, source, amount, entity_id) values (auth.uid(), 'give', p_source, p_amount, p_entity);
  return json_build_object('wallet', w);
end $$;

-- Daily free gift (10/day, IST)
create or replace function claim_daily() returns json language plpgsql security definer set search_path=public as $$
declare today date := (now() at time zone 'Asia/Kolkata')::date; w int;
begin
  update profiles set wallet = wallet + 10, last_daily = today
   where id = auth.uid() and (last_daily is null or last_daily < today) returning wallet into w;
  if w is null then raise exception 'already claimed'; end if;
  insert into ledger(user_id, kind, source, amount) values (auth.uid(), 'earn', 'daily', 10);
  return json_build_object('wallet', w);
end $$;

-- Share reward (+5, max 3/day)
create or replace function reward_share() returns json language plpgsql security definer set search_path=public as $$
declare today date := (now() at time zone 'Asia/Kolkata')::date; w int;
begin
  update profiles set shares_today = case when shares_day = today then shares_today + 1 else 1 end, shares_day = today, wallet = wallet + 5
   where id = auth.uid() and (shares_day is distinct from today or shares_today < 3) returning wallet into w;
  if w is null then return json_build_object('rewarded', false); end if;
  insert into ledger(user_id, kind, source, amount) values (auth.uid(), 'earn', 'share', 5);
  return json_build_object('rewarded', true, 'wallet', w);
end $$;

-- Top fans for an entity (tonight)
create or replace view top_fans_tonight as
select l.entity_id, p.display_name, p.city, sum(l.amount) as tickets,
       rank() over (partition by l.entity_id order by sum(l.amount) desc) as rnk
from ledger l join profiles p on p.id = l.user_id
where l.kind = 'give' and l.created_at >= date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata'
group by l.entity_id, p.display_name, p.city;

-- Midnight IST reset (18:30 UTC)
create or replace function reset_night() returns void language plpgsql security definer set search_path=public as $$
begin
  insert into night_results(day, entity_id, rank, tickets)
  select (now() at time zone 'Asia/Kolkata')::date - 1, id, rank() over (order by tonight desc), tonight
  from entities where category = 'heroes' and active order by tonight desc limit 15;
  update entities e set rank_night_start = r.rk from (select id, rank() over (partition by category order by tonight desc) rk from entities) r where r.id = e.id;
  update entities set tonight = 0;
end $$;
create or replace function reset_week() returns void language plpgsql security definer set search_path=public as $$
begin
  insert into week_results(week_end, entity_id, rank, tickets)
  select (now() at time zone 'Asia/Kolkata')::date - 1, id, rank() over (order by week desc), week
  from entities where category = 'heroes' and active order by week desc limit 15;
  update entities e set rank_week_start = r.rk from (select id, rank() over (partition by category order by week desc) rk from entities) r where r.id = e.id;
  update entities set week = 0;
end $$;
select cron.schedule('night-reset', '30 18 * * *', 'select reset_night()');
select cron.schedule('week-reset',  '31 18 * * 0', 'select reset_week()');

-- Security: everyone can read boards; nobody writes directly
alter table entities enable row level security;  create policy read_all on entities for select using (true);
alter table night_results enable row level security; create policy read_all on night_results for select using (true);
alter table week_results enable row level security;  create policy read_all on week_results for select using (true);
alter table profiles enable row level security;
create policy own_read on profiles for select using (id = auth.uid());
create policy own_insert on profiles for insert with check (id = auth.uid() and wallet = 0);
alter table ledger enable row level security; create policy own_read on ledger for select using (user_id = auth.uid());
alter table follows enable row level security; create policy own_all on follows for all using (user_id = auth.uid()) with check (user_id = auth.uid());
alter table ticket_uploads enable row level security; create policy own_read on ticket_uploads for select using (user_id = auth.uid());

-- Live board updates
alter publication supabase_realtime add table entities;
