-- =============================================
-- Anaar Platform – Complete Backend SQL
-- Run this AFTER supabase-schema.sql
-- Paste in: Supabase Dashboard → SQL Editor
-- =============================================

-- ══════════════════════════════════════════════
-- 1. AUTO-CREATE COIN WALLET ON USER SIGNUP
-- ══════════════════════════════════════════════
create or replace function handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  -- Insert profile into users table (from auth metadata)
  insert into public.users (id, email, name, role)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'name', 'User'),
    coalesce(new.raw_user_meta_data->>'role', 'viewer')
  )
  on conflict (id) do nothing;

  -- Auto-create coin wallet
  insert into public.coin_wallets (user_id, coins, cash_value)
  values (new.id, 0, 0.00)
  on conflict (user_id) do nothing;

  -- Auto-create advertiser profile if role is advertiser or both
  if (new.raw_user_meta_data->>'role') in ('advertiser', 'both') then
    insert into public.advertisers (user_id, wallet_balance)
    values (new.id, 0.00)
    on conflict (user_id) do nothing;
  end if;

  return new;
end;
$$;

-- Attach trigger to auth.users
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure handle_new_user();


-- ══════════════════════════════════════════════
-- 2. IMPROVED earn_coins_for_view
--    • Awards viewer coins
--    • Deducts from advertiser wallet
--    • Auto-completes ad when quota filled
-- ══════════════════════════════════════════════
drop function if exists earn_coins_for_view(uuid,uuid,integer);
create or replace function earn_coins_for_view(
  p_viewer_id uuid,
  p_ad_id     uuid,
  p_coins     integer
) returns jsonb language plpgsql security definer as $$
declare
  v_ad          record;
  v_already     boolean;
  v_adv_balance numeric;
  v_cost        numeric;
begin
  -- Fetch ad details
  select * into v_ad from ads where id = p_ad_id;
  if not found then
    return jsonb_build_object('success', false, 'message', 'Ad not found');
  end if;
  if v_ad.status <> 'active' then
    return jsonb_build_object('success', false, 'message', 'Ad is not active');
  end if;

  -- Check already watched
  select exists(
    select 1 from ad_views where ad_id = p_ad_id and viewer_id = p_viewer_id
  ) into v_already;
  if v_already then
    return jsonb_build_object('success', false, 'message', 'Already watched');
  end if;

  -- Cost per view = budget_total / views_ordered
  v_cost := round(v_ad.budget_total / greatest(v_ad.views_ordered, 1), 4);

  -- Check advertiser has enough balance
  select wallet_balance into v_adv_balance
    from advertisers where id = v_ad.advertiser_id;
  if v_adv_balance < v_cost then
    return jsonb_build_object('success', false, 'message', 'Advertiser has insufficient balance');
  end if;

  -- Record the view
  insert into ad_views (ad_id, viewer_id, coins_earned)
    values (p_ad_id, p_viewer_id, p_coins);

  -- Credit viewer coins
  insert into coin_wallets (user_id, coins, cash_value)
    values (p_viewer_id, p_coins, round(p_coins * 0.0005, 4))
    on conflict (user_id) do update
      set coins      = coin_wallets.coins + excluded.coins,
          cash_value = coin_wallets.cash_value + excluded.cash_value,
          updated_at = now();

  -- Log coin transaction
  insert into coin_transactions (user_id, ad_id, type, coins, description)
    values (p_viewer_id, p_ad_id, 'earn', p_coins, 'Earned from watching ad: ' || v_ad.title);

  -- Deduct from advertiser wallet
  update advertisers
    set wallet_balance = wallet_balance - v_cost
    where id = v_ad.advertiser_id;

  -- Log payment record
  insert into payments (advertiser_id, ad_id, amount, gst_amount, total_amount, payment_method, status)
    values (v_ad.advertiser_id, p_ad_id, v_cost, 0, v_cost, 'wallet', 'success');

  -- Increment views delivered
  update ads
    set views_delivered = views_delivered + 1
    where id = p_ad_id;

  -- Auto-complete ad if quota reached
  update ads
    set status = 'completed', completed_at = now()
    where id = p_ad_id
      and views_delivered >= views_ordered
      and status = 'active';

  return jsonb_build_object('success', true, 'coins', p_coins, 'message', 'Coins earned!');
end;
$$;


-- ══════════════════════════════════════════════
-- 3. ADMIN: APPROVE / REJECT AD
-- ══════════════════════════════════════════════
create or replace function admin_approve_ad(p_ad_id uuid)
returns jsonb language plpgsql security definer as $$
begin
  update ads
    set status = 'active', approved_at = now()
    where id = p_ad_id and status = 'pending';
  if not found then
    return jsonb_build_object('success', false, 'message', 'Ad not found or not pending');
  end if;
  return jsonb_build_object('success', true, 'message', 'Ad approved and now active');
end;
$$;

create or replace function admin_reject_ad(p_ad_id uuid, p_reason text default 'Does not meet guidelines')
returns jsonb language plpgsql security definer as $$
begin
  update ads set status = 'rejected' where id = p_ad_id and status = 'pending';
  return jsonb_build_object('success', true, 'message', 'Ad rejected');
end;
$$;


-- ══════════════════════════════════════════════
-- 4. ADVERTISER: TOP UP WALLET
-- ══════════════════════════════════════════════
create or replace function topup_advertiser_wallet(
  p_advertiser_id uuid,
  p_amount        numeric,
  p_txn_ref       text default null
) returns jsonb language plpgsql security definer as $$
begin
  update advertisers
    set wallet_balance = wallet_balance + p_amount
    where id = p_advertiser_id;

  insert into payments (advertiser_id, amount, gst_amount, total_amount, payment_method, transaction_ref, status)
    values (p_advertiser_id, p_amount, 0, p_amount, 'gateway', p_txn_ref, 'success');

  return jsonb_build_object('success', true, 'new_balance', (
    select wallet_balance from advertisers where id = p_advertiser_id
  ));
end;
$$;


-- ══════════════════════════════════════════════
-- 5. VIEWER: REDEEM COINS TO CASH
-- ══════════════════════════════════════════════
create or replace function redeem_coins(
  p_user_id uuid,
  p_coins   integer
) returns jsonb language plpgsql security definer as $$
declare
  v_wallet record;
  v_cash   numeric;
begin
  select * into v_wallet from coin_wallets where user_id = p_user_id;
  if not found then
    return jsonb_build_object('success', false, 'message', 'Wallet not found');
  end if;
  if v_wallet.coins < p_coins then
    return jsonb_build_object('success', false, 'message', 'Not enough coins');
  end if;
  if p_coins < 1000 then
    return jsonb_build_object('success', false, 'message', 'Minimum redemption is 1000 coins');
  end if;

  v_cash := round(p_coins * 0.0005, 2);

  update coin_wallets
    set coins      = coins - p_coins,
        cash_value = cash_value - v_cash,
        updated_at = now()
    where user_id = p_user_id;

  insert into coin_transactions (user_id, type, coins, description)
    values (p_user_id, 'redeem', -p_coins, 'Redeemed ' || p_coins || ' coins for ₹' || v_cash);

  return jsonb_build_object('success', true, 'coins_redeemed', p_coins, 'cash_value', v_cash);
end;
$$;


-- ══════════════════════════════════════════════
-- 6. GET DASHBOARD STATS (ADVERTISER)
-- ══════════════════════════════════════════════
create or replace function get_advertiser_stats(p_user_id uuid)
returns jsonb language plpgsql security definer as $$
declare
  v_adv record;
begin
  select * into v_adv from advertisers where user_id = p_user_id;
  if not found then
    return jsonb_build_object('success', false, 'message', 'Advertiser not found');
  end if;

  return jsonb_build_object(
    'success',         true,
    'wallet_balance',  v_adv.wallet_balance,
    'total_ads',       (select count(*) from ads where advertiser_id = v_adv.id),
    'active_ads',      (select count(*) from ads where advertiser_id = v_adv.id and status = 'active'),
    'total_views',     (select coalesce(sum(views_delivered), 0) from ads where advertiser_id = v_adv.id),
    'total_spent',     (select coalesce(sum(total_amount), 0) from payments where advertiser_id = v_adv.id and status = 'success')
  );
end;
$$;


-- ══════════════════════════════════════════════
-- 7. GET DASHBOARD STATS (VIEWER)
-- ══════════════════════════════════════════════
create or replace function get_viewer_stats(p_user_id uuid)
returns jsonb language plpgsql security definer as $$
declare
  v_wallet record;
begin
  select * into v_wallet from coin_wallets where user_id = p_user_id;

  return jsonb_build_object(
    'success',       true,
    'total_coins',   coalesce(v_wallet.coins, 0),
    'cash_value',    coalesce(v_wallet.cash_value, 0),
    'ads_watched',   (select count(*) from ad_views where viewer_id = p_user_id),
    'available_ads', (select count(*) from ads
                       where status = 'active'
                         and id not in (select ad_id from ad_views where viewer_id = p_user_id))
  );
end;
$$;


-- ══════════════════════════════════════════════
-- 8. ROW LEVEL SECURITY – additional policies
-- ══════════════════════════════════════════════

-- Allow viewers to read all active ads (already in schema, safe to repeat)
drop policy if exists "ads_active_read" on ads;
create policy "ads_active_read" on ads
  for select using (status = 'active');

-- Viewers can insert their own views
drop policy if exists "views_insert_own" on ad_views;
create policy "views_insert_own" on ad_views
  for insert with check (auth.uid() = viewer_id);

-- Allow users to read their own coin_transactions
drop policy if exists "coin_tx_select_own" on coin_transactions;
create policy "coin_tx_select_own" on coin_transactions
  for select using (auth.uid() = user_id);

-- Advertisers can read their own payments
drop policy if exists "payments_select_own" on payments;
create policy "payments_select_own" on payments
  for select using (
    advertiser_id in (select id from advertisers where user_id = auth.uid())
  );


-- ══════════════════════════════════════════════
-- 9. COIN RATE TABLE (lookup)
-- ══════════════════════════════════════════════
create table if not exists coin_rates (
  id          serial primary key,
  label       text not null,
  coins       integer not null,
  cash_inr    numeric(8,2) not null,
  description text
);

insert into coin_rates (label, coins, cash_inr, description) values
  ('Starter',  500,  0.25, 'Minimum earn threshold'),
  ('Basic',   1000,  0.50, 'Redeemable milestone'),
  ('Silver',  5000,  2.50, 'Silver tier reward'),
  ('Gold',   10000,  5.00, 'Gold tier reward'),
  ('Platinum',50000, 25.00,'Platinum tier reward')
on conflict do nothing;

alter table coin_rates enable row level security;

do $$
begin
  if exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'coin_rates'
      and policyname = 'coin_rates_read'
  ) then
    drop policy "coin_rates_read" on public.coin_rates;
  end if;
end
$$;

create policy "coin_rates_read" on public.coin_rates
  for select using (true);


-- ══════════════════════════════════════════════
-- DONE — Run supabase-schema.sql first, then this file
-- ══════════════════════════════════════════════
