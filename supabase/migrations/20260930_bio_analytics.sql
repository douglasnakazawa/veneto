-- Analytics do link na bio (Veneto Studio)
-- Tabela de eventos gravada direto da página via REST (chave publishable),
-- com RLS liberando apenas INSERT. Leitura só pela função bio_stats,
-- protegida por uma chave de acesso guardada no schema private.

create extension if not exists pgcrypto;

-- Schema privado (não exposto pela API) para a chave do dashboard
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.dashboard_keys (
  key        text primary key,
  label      text,
  created_at timestamptz not null default now()
);
-- Para criar uma chave de acesso ao dashboard:
--   insert into private.dashboard_keys (key, label) values ('sua-chave-secreta', 'Douglas');

-- Eventos
create table if not exists public.bio_events (
  id           bigint generated always as identity primary key,
  created_at   timestamptz not null default now(),
  event        text not null check (event in ('view', 'click')),
  page         text not null default '/bio/',
  button       text,
  href         text,
  session_id   text,
  referrer     text,
  utm_source   text,
  utm_medium   text,
  utm_campaign text,
  utm_content  text,
  device       text check (device in ('mobile', 'tablet', 'desktop')),
  lang         text
);

create index if not exists bio_events_created_at_idx on public.bio_events (created_at desc);
create index if not exists bio_events_event_created_idx on public.bio_events (event, created_at desc);

alter table public.bio_events enable row level security;

revoke all on public.bio_events from anon, authenticated;
grant insert on public.bio_events to anon;

drop policy if exists bio_events_insert_anon on public.bio_events;
create policy bio_events_insert_anon on public.bio_events
  for insert to anon
  with check (
    event in ('view', 'click')
    and length(page) <= 120
    and (button       is null or length(button)       <= 80)
    and (href         is null or length(href)         <= 300)
    and (session_id   is null or length(session_id)   <= 64)
    and (referrer     is null or length(referrer)     <= 300)
    and (utm_source   is null or length(utm_source)   <= 80)
    and (utm_medium   is null or length(utm_medium)   <= 80)
    and (utm_campaign is null or length(utm_campaign) <= 120)
    and (utm_content  is null or length(utm_content)  <= 120)
    and (lang         is null or length(lang)         <= 16)
  );

-- Agregados para o dashboard
create or replace function public.bio_stats(p_key text, p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  ok boolean;
begin
  select exists (select 1 from private.dashboard_keys k where k.key = p_key) into ok;
  if not ok then
    raise exception 'chave de acesso inválida' using errcode = '28000';
  end if;

  return jsonb_build_object(
    'from', p_from,
    'to',   p_to,
    'views',    (select count(*) from public.bio_events e where e.event = 'view'  and e.created_at >= p_from and e.created_at < p_to),
    'visitors', (select count(distinct e.session_id) from public.bio_events e where e.event = 'view' and e.created_at >= p_from and e.created_at < p_to),
    'clicks',   (select count(*) from public.bio_events e where e.event = 'click' and e.created_at >= p_from and e.created_at < p_to),
    'clickers', (select count(distinct e.session_id) from public.bio_events e where e.event = 'click' and e.created_at >= p_from and e.created_at < p_to),
    'buttons', (
      select coalesce(jsonb_agg(jsonb_build_object('button', t.button, 'href', t.href, 'clicks', t.c, 'clickers', t.u) order by t.c desc), '[]'::jsonb)
      from (
        select e.button, max(e.href) as href, count(*) as c, count(distinct e.session_id) as u
        from public.bio_events e
        where e.event = 'click' and e.created_at >= p_from and e.created_at < p_to
        group by e.button
      ) t
    ),
    'daily', (
      select coalesce(jsonb_agg(jsonb_build_object('day', t.d, 'views', t.v, 'clicks', t.c) order by t.d), '[]'::jsonb)
      from (
        select (e.created_at at time zone 'America/Sao_Paulo')::date as d,
               count(*) filter (where e.event = 'view')  as v,
               count(*) filter (where e.event = 'click') as c
        from public.bio_events e
        where e.created_at >= p_from and e.created_at < p_to
        group by 1
      ) t
    ),
    'sources', (
      select coalesce(jsonb_agg(jsonb_build_object('source', t.s, 'views', t.v) order by t.v desc), '[]'::jsonb)
      from (
        select coalesce(nullif(e.utm_source, ''), substring(e.referrer from '^https?://([^/]+)'), 'direto') as s,
               count(*) as v
        from public.bio_events e
        where e.event = 'view' and e.created_at >= p_from and e.created_at < p_to
        group by 1
        order by 2 desc
        limit 8
      ) t
    ),
    'devices', (
      select coalesce(jsonb_agg(jsonb_build_object('device', t.d, 'views', t.v) order by t.v desc), '[]'::jsonb)
      from (
        select coalesce(e.device, 'desconhecido') as d, count(*) as v
        from public.bio_events e
        where e.event = 'view' and e.created_at >= p_from and e.created_at < p_to
        group by 1
      ) t
    )
  );
end;
$$;

revoke all on function public.bio_stats(text, timestamptz, timestamptz) from public;
grant execute on function public.bio_stats(text, timestamptz, timestamptz) to anon;
