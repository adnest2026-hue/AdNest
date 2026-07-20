-- =============================================
-- AdNest / Anaar Platform – Supabase Schema
-- Run this in your Supabase SQL Editor
-- =============================================

-- Enable UUID extension
create extension if not exists "uuid-ossp";

-- ── USERS ──────────────────────────────────────
create table if not exists users (
  id           uuid primary key default uuid_generate_v4(),
  phone        text unique not null,
  name         text,
  email        text,
  role         text not null default 'viewer' check (role in ('viewer', 'advertiser', 'admin')),
  pincode      text,
  district     text,
  state        text,
  created_at   timestamptz default now()
);

-- ── COIN WALLETS ────────────────────────────────
create table if not exists coin_wallets (
  id           uuid primary key default uuid_generate_v4(),
  user_id      uuid not null references users(id) on delete cascade,
  coins        bigint not null default 0,
  cash_value   numeric(10,2) not null default 0.00,
  updated_at   timestamptz default now(),
  unique(user_id)
);

-- ── ADVERTISER PROFILES ─────────────────────────
create table if not exists advertisers (
  id              uuid primary key default uuid_generate_v4(),
  user_id         uuid not null references users(id) on delete cascade,
  business_name   text,
  whatsapp_number text,
  wallet_balance  numeric(12,2) not null default 0.00,
  gstin           text,
  created_at      timestamptz default now(),
  unique(user_id)
);

-- ── ADS ─────────────────────────────────────────
create table if not exists ads (
  id              uuid primary key default uuid_generate_v4(),
  advertiser_id   uuid not null references advertisers(id) on delete cascade,
  title           text not null,
  ad_type         text not null check (ad_type in ('image', 'video', 'social_link', 'app_website')),
  content_url     text,
  target_area     text not null check (target_area in ('pincode', 'district', 'state', 'nationwide')),
  target_value    text,
  views_ordered   integer not null default 1000,
  views_delivered integer not null default 0,
  rate_per_1k     numeric(8,2) not null,
  budget_base     numeric(10,2) not null,
  budget_gst      numeric(10,2) not null,
  budget_total    numeric(10,2) not null,
  status          text not null default 'pending' check (status in ('pending', 'approved', 'active', 'paused', 'completed', 'rejected')),
  created_at      timestamptz default now(),
  approved_at     timestamptz,
  completed_at    timestamptz
);

-- ── AD VIEWS (viewer tracking) ──────────────────
create table if not exists ad_views (
  id            uuid primary key default uuid_generate_v4(),
  ad_id         uuid not null references ads(id) on delete cascade,
  viewer_id     uuid not null references users(id) on delete cascade,
  coins_earned  integer not null default 0,
  viewed_at     timestamptz default now(),
  unique(ad_id, viewer_id)
);

-- ── COIN TRANSACTIONS ────────────────────────────
create table if not exists coin_transactions (
  id            uuid primary key default uuid_generate_v4(),
  user_id       uuid not null references users(id) on delete cascade,
  ad_id         uuid references ads(id) on delete set null,
  type          text not null check (type in ('earn', 'redeem', 'bonus')),
  coins         integer not null,
  description   text,
  created_at    timestamptz default now()
);

-- ── PAYMENTS ─────────────────────────────────────
create table if not exists payments (
  id              uuid primary key default uuid_generate_v4(),
  advertiser_id   uuid not null references advertisers(id) on delete cascade,
  ad_id           uuid references ads(id) on delete set null,
  amount          numeric(10,2) not null,
  gst_amount      numeric(10,2) not null,
  total_amount    numeric(10,2) not null,
  payment_method  text default 'gateway',
  transaction_ref text,
  status          text not null default 'pending' check (status in ('pending', 'success', 'failed', 'refunded')),
  paid_at         timestamptz default now()
);

-- ── INDEXES ──────────────────────────────────────
create index if not exists idx_ads_advertiser    on ads(advertiser_id);
create index if not exists idx_ads_status        on ads(status);
create index if not exists idx_ad_views_ad       on ad_views(ad_id);
create index if not exists idx_ad_views_viewer   on ad_views(viewer_id);
create index if not exists idx_coin_tx_user      on coin_transactions(user_id);
create index if not exists idx_payments_adv      on payments(advertiser_id);

-- ── ROW LEVEL SECURITY ───────────────────────────
alter table users             enable row level security;
alter table coin_wallets      enable row level security;
alter table advertisers       enable row level security;
alter table ads               enable row level security;
alter table ad_views          enable row level security;
alter table coin_transactions enable row level security;
alter table payments          enable row level security;

-- Users can read/update their own data
create policy "users_own" on users
  for all using (auth.uid() = id);

-- Viewers see their own wallet
create policy "wallet_own" on coin_wallets
  for all using (auth.uid() = user_id);

-- Advertisers manage their own profile
create policy "advertiser_own" on advertisers
  for all using (auth.uid() = user_id);

-- Advertisers manage their own ads
create policy "ads_own" on ads
  for all using (
    advertiser_id in (select id from advertisers where user_id = auth.uid())
  );

-- Viewers see active ads
create policy "ads_active_read" on ads
  for select using (status = 'active');

-- Viewers log their own views
create policy "views_own" on ad_views
  for all using (auth.uid() = viewer_id);

-- Users see their own coin history
create policy "coin_tx_own" on coin_transactions
  for all using (auth.uid() = user_id);

-- Advertisers see their own payments
create policy "payments_own" on payments
  for all using (
    advertiser_id in (select id from advertisers where user_id = auth.uid())
  );

-- ── FUNCTION: earn coins after viewing ad ────────
create or replace function earn_coins_for_view(
  p_viewer_id uuid,
  p_ad_id     uuid,
  p_coins     integer
) returns void language plpgsql security definer as $$
begin
  insert into ad_views(ad_id, viewer_id, coins_earned)
    values (p_ad_id, p_viewer_id, p_coins)
    on conflict (ad_id, viewer_id) do nothing;

  if found then
    insert into coin_transactions(user_id, ad_id, type, coins, description)
      values (p_viewer_id, p_ad_id, 'earn', p_coins, 'Earned from ad view');

    insert into coin_wallets(user_id, coins, cash_value)
      values (p_viewer_id, p_coins, round(p_coins * 0.0005, 4))
      on conflict (user_id) do update
        set coins      = coin_wallets.coins + excluded.coins,
            cash_value = coin_wallets.cash_value + excluded.cash_value,
            updated_at = now();

    update ads
      set views_delivered = views_delivered + 1
      where id = p_ad_id;
  end if;
end;
$$;
