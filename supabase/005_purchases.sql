-- 005: paid ticket packs (credited only by the verify-payment function)
create table if not exists purchases (
  id bigserial primary key, user_id uuid references profiles(id), order_id text unique not null,
  payment_id text, pack text not null, amount_paise int not null, tickets int not null,
  status text not null default 'created' check (status in ('created','paid','failed')),
  created_at timestamptz default now(), paid_at timestamptz
);
alter table purchases enable row level security;
create policy own_read on purchases for select using (user_id = auth.uid());
alter table ledger drop constraint if exists ledger_kind_check;
alter table ledger add constraint ledger_kind_check check (kind in ('earn','give','adjust','buy'));

-- Atomic credit, callable only with the service key (from the Edge Function)
create or replace function credit_purchase(p_order text, p_payment text) returns json
language plpgsql security definer set search_path=public as $$
declare pu purchases; w int;
begin
  update purchases set status='paid', payment_id=p_payment, paid_at=now() where order_id=p_order and status='created' returning * into pu;
  if pu.id is null then select wallet into w from profiles p join purchases x on x.user_id=p.id where x.order_id=p_order; return json_build_object('ok', w is not null, 'wallet', w, 'already', true); end if;
  update profiles set wallet = wallet + pu.tickets where id = pu.user_id returning wallet into w;
  insert into ledger(user_id, kind, source, amount) values (pu.user_id, 'buy', pu.pack, pu.tickets);
  return json_build_object('ok', true, 'wallet', w);
end $$;
revoke execute on function credit_purchase(text,text) from public, anon, authenticated;
