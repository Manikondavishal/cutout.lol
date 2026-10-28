-- 002: real login rules, streaks, fan levels, rally links, city battles
alter table profiles add column if not exists streak int not null default 0;
alter table profiles add column if not exists given_total bigint not null default 0;
alter table profiles add column if not exists rally_rewarded boolean not null default false;

create or replace function is_guest() returns boolean language sql stable as $$
  select coalesce((auth.jwt()->>'is_anonymous')::boolean, false) $$;

-- Daily gift with streaks. Guests get their first 10 only; signing in unlocks the daily gift.
create or replace function claim_daily() returns json language plpgsql security definer set search_path=public as $$
declare today date := (now() at time zone 'Asia/Kolkata')::date; p profiles; bonus int := 0; s int;
begin
  select * into p from profiles where id = auth.uid() for update;
  if p.id is null then raise exception 'no profile'; end if;
  if p.last_daily = today then raise exception 'already claimed'; end if;
  if is_guest() and p.last_daily is not null then raise exception 'sign in to claim daily tickets'; end if;
  s := case when p.last_daily = today - 1 then p.streak + 1 else 1 end;
  if s % 7 = 0 then bonus := 20; end if;
  update profiles set wallet = wallet + 10 + bonus, last_daily = today, streak = s where id = p.id;
  insert into ledger(user_id, kind, source, amount) values (p.id, 'earn', 'daily', 10 + bonus);
  return json_build_object('wallet', p.wallet + 10 + bonus, 'streak', s, 'bonus', bonus);
end $$;

-- Give tickets; also pays the rally referrer +10 on a referred fan's first give
create or replace function give_tickets(p_entity text, p_amount int, p_source text default 'give')
returns json language plpgsql security definer set search_path=public as $$
declare w int; p profiles;
begin
  if p_amount <= 0 or p_amount > 500 then raise exception 'bad amount'; end if;
  update profiles set wallet = wallet - p_amount, given_total = given_total + p_amount
   where id = auth.uid() and wallet >= p_amount returning * into p;
  if p.id is null then raise exception 'not enough tickets'; end if;
  update entities set tonight = tonight + p_amount, week = week + p_amount, all_time = all_time + p_amount where id = p_entity and active;
  if not found then raise exception 'unknown entity'; end if;
  insert into ledger(user_id, kind, source, amount, entity_id) values (p.id, 'give', p_source, p_amount, p_entity);
  if p.referred_by is not null and not p.rally_rewarded and not is_guest() then
    update profiles set rally_rewarded = true where id = p.id;
    update profiles set wallet = wallet + 10 where id = p.referred_by;
    insert into ledger(user_id, kind, source, amount) values (p.referred_by, 'earn', 'rally', 10);
  end if;
  return json_build_object('wallet', p.wallet, 'given_total', p.given_total);
end $$;

-- Who rallied you (set once, on your own profile)
create or replace function set_referrer(p_ref uuid) returns void language plpgsql security definer set search_path=public as $$
begin
  if p_ref = auth.uid() then return; end if;
  update profiles set referred_by = p_ref where id = auth.uid() and referred_by is null and exists(select 1 from profiles where id = p_ref);
end $$;

-- Rally count: fans you brought in
create or replace function my_rally() returns int language sql stable security definer set search_path=public as $$
  select count(*)::int from profiles where referred_by = auth.uid() $$;

-- City battle per hero (tonight)
create or replace view city_battle_tonight as
select l.entity_id, coalesce(p.city,'Other') as city, sum(l.amount) as tickets,
       rank() over (partition by l.entity_id order by sum(l.amount) desc) as rnk
from ledger l join profiles p on p.id = l.user_id
where l.kind = 'give' and l.created_at >= date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata'
group by l.entity_id, coalesce(p.city,'Other');

-- Allow a fan to edit their own name/city (not wallet)
create policy own_update on profiles for update using (id = auth.uid()) with check (id = auth.uid());
revoke update on profiles from anon, authenticated;
grant update (display_name, city) on profiles to authenticated;
insert into entities(id,name,nick,category,industry,is_pan_india,color,art_url) values
('naga-chaitanya','Naga Chaitanya','Chay','heroes','Tollywood',false,'#364fc7',null),
('ram-pothineni','Ram Pothineni','Ustaad','heroes','Tollywood',false,'#e8590c',null),
('varun-tej','Varun Tej','Mega Prince','heroes','Tollywood',false,'#2b8a3e',null),
('sai-dharam-tej','Sai Dharam Tej','Supreme Hero','heroes','Tollywood',false,'#1971c2',null),
('siddhu-jonnalagadda','Siddhu Jonnalagadda','Tillu','heroes','Tollywood',false,'#f08c00',null),
('nikhil-siddhartha','Nikhil Siddhartha','Nikhil','heroes','Tollywood',false,'#862e9c',null),
('adivi-sesh','Adivi Sesh','Sesh','heroes','Tollywood',false,'#495057',null),
('jayam-ravi','Jayam Ravi','Jayam','heroes','Kollywood',false,'#1864ab',null),
('arya','Arya','Arya','heroes','Kollywood',false,'#2f9e44',null),
('vishal','Vishal','Puratchi Thalapathy','heroes','Kollywood',false,'#c92a2a',null),
('shahid-kapoor','Shahid Kapoor','Shasha','heroes','Bollywood',false,'#212529',null),
('sidharth-malhotra','Sidharth Malhotra','Sid','heroes','Bollywood',false,'#1c7ed6',null),
('ayushmann-khurrana','Ayushmann Khurrana','Ayush','heroes','Bollywood',false,'#f59f00',null),
('rajkummar-rao','Rajkummar Rao','Raj','heroes','Bollywood',false,'#5c940d',null),
('sunny-deol','Sunny Deol','Dhai Kilo','heroes','Bollywood',false,'#e03131',null),
('saif-ali-khan','Saif Ali Khan','Nawab','heroes','Bollywood',false,'#495057',null),
('basil-joseph','Basil Joseph','Basil','heroes','Mollywood',false,'#fab005',null),
('asif-ali','Asif Ali','Asif','heroes','Mollywood',false,'#0b7285',null),
('unni-mukundan','Unni Mukundan','Unni','heroes','Mollywood',false,'#c92a2a',null),
('rakshit-shetty','Rakshit Shetty','Simple Star','heroes','Sandalwood',false,'#2b8a3e',null),
('dhruva-sarja','Dhruva Sarja','Action Prince','heroes','Sandalwood',false,'#212529',null),
('ganesh','Ganesh','Golden Star','heroes','Sandalwood',false,'#f59f00',null),
('jeet','Jeet','Super Hero','heroes','Bengali',false,'#c92a2a',null),
('prosenjit-chatterjee','Prosenjit Chatterjee','Bumba Da','heroes','Bengali',false,'#495057',null),
('gippy-grewal','Gippy Grewal','Gippy','heroes','Punjabi',false,'#e8590c',null),
('ammy-virk','Ammy Virk','Ammy','heroes','Punjabi',false,'#2f9e44',null)
on conflict (id) do nothing;
