-- 004: real ticket uploads (private storage + review queue) and admins
create table if not exists admins (user_id uuid primary key references auth.users on delete cascade);
alter table admins enable row level security;
create policy self_read on admins for select using (user_id = auth.uid());
insert into storage.buckets (id, name, public) values ('tickets','tickets',false) on conflict (id) do nothing;
create policy "fans upload own tickets" on storage.objects for insert to authenticated
  with check (bucket_id = 'tickets' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "fans read own tickets" on storage.objects for select to authenticated
  using (bucket_id = 'tickets' and ((storage.foldername(name))[1] = auth.uid()::text or exists(select 1 from admins where user_id = auth.uid())));


alter table ticket_uploads add column if not exists reward int not null default 10;
alter table ticket_uploads add column if not exists reviewed_at timestamptz;

-- Submit: max 3 a day, signed-in fans only
create or replace function submit_ticket(p_movie text, p_first_day boolean, p_path text) returns json
language plpgsql security definer set search_path=public as $$
declare n int;
begin
  if is_guest() then raise exception 'sign in to upload tickets'; end if;
  select count(*) into n from ticket_uploads where user_id = auth.uid() and created_at > now() - interval '24 hours';
  if n >= 3 then raise exception '3 tickets a day max'; end if;
  insert into ticket_uploads(user_id, entity_id, image_path, first_day, reward)
    values (auth.uid(), p_movie, p_path, p_first_day, case when p_first_day then 20 else 10 end);
  return json_build_object('ok', true);
end $$;

-- Review (admins only)
create or replace function review_ticket(p_id bigint, p_ok boolean) returns void
language plpgsql security definer set search_path=public as $$
declare t ticket_uploads;
begin
  if not exists(select 1 from admins where user_id = auth.uid()) then raise exception 'admins only'; end if;
  update ticket_uploads set status = case when p_ok then 'approved' else 'rejected' end, reviewed_at = now()
   where id = p_id and status = 'pending' returning * into t;
  if t.id is not null and p_ok then
    update profiles set wallet = wallet + t.reward where id = t.user_id;
    insert into ledger(user_id, kind, source, amount, entity_id) values (t.user_id, 'earn', 'ticket', t.reward, t.entity_id);
  end if;
end $$;

create policy admin_read on ticket_uploads for select using (exists(select 1 from admins where user_id = auth.uid()));

-- Heroines are paused for now
update entities set active = false where category = 'heroes' and id in ('nayanthara','samantha-ruth-prabhu','rashmika-mandanna','sai-pallavi','deepika-padukone','alia-bhatt');
