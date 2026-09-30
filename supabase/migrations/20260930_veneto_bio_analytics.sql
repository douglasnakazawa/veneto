-- ============================================================
-- VENETO STUDIO / ESCOLA DO BRILHO — analytics do link na bio
-- Aplicada no projeto compartilhado "Grupo NKZ" (fscqqeakupldpdaaimkc)
-- em 30/09/2026 com o nome "veneto_bio_analytics".
--
-- Tudo da marca Veneto fica no schema "veneto" (não exposto pela API).
-- A API pública só tem duas funções, ambas com prefixo veneto_:
--   public.veneto_track      -> grava visita/clique (chamada pela página)
--   public.veneto_bio_stats  -> agregados para o dashboard (exige chave)
-- ============================================================

create extension if not exists pgcrypto with schema extensions;

create schema if not exists veneto;
comment on schema veneto is 'Marca Veneto Studio / Escola do Brilho. Dados do link na bio e futuros projetos da marca. Nada aqui é exposto pela API REST; acesso apenas pelas funções public.veneto_*.';
revoke all on schema veneto from public, anon, authenticated;

-- Eventos do link na bio
create table if not exists veneto.bio_events (
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
comment on table veneto.bio_events is 'Veneto: visitas (view) e cliques (click) da página de link na bio. Gravado por public.veneto_track.';
comment on column veneto.bio_events.button is 'Nome do botão clicado (data-track da página). Nulo em visitas.';
comment on column veneto.bio_events.session_id is 'Identificador anônimo do visitante, guardado no navegador.';

create index if not exists bio_events_created_at_idx on veneto.bio_events (created_at desc);
create index if not exists bio_events_event_created_idx on veneto.bio_events (event, created_at desc);
create index if not exists bio_events_session_created_idx on veneto.bio_events (session_id, created_at desc);

alter table veneto.bio_events enable row level security;
revoke all on veneto.bio_events from public, anon, authenticated;

-- Chaves de acesso ao dashboard
create table if not exists veneto.dashboard_keys (
  key        text primary key,
  label      text,
  created_at timestamptz not null default now()
);
comment on table veneto.dashboard_keys is 'Veneto: chaves de acesso ao dashboard do link na bio (conferidas por public.veneto_bio_stats).';
alter table veneto.dashboard_keys enable row level security;
revoke all on veneto.dashboard_keys from public, anon, authenticated;

-- ------------------------------------------------------------
-- Gravação de eventos (RPC chamada pela página)
-- ------------------------------------------------------------
create or replace function public.veneto_track(
  p_event        text,
  p_page         text default '/bio/',
  p_button       text default null,
  p_href         text default null,
  p_session_id   text default null,
  p_referrer     text default null,
  p_utm_source   text default null,
  p_utm_medium   text default null,
  p_utm_campaign text default null,
  p_utm_content  text default null,
  p_device       text default null,
  p_lang         text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  recent int;
begin
  if p_event is null or p_event not in ('view', 'click') then
    raise exception 'evento inválido' using errcode = '22023';
  end if;

  -- limite simples: no máximo 120 eventos por sessão por hora
  if p_session_id is not null then
    select count(*) into recent
    from veneto.bio_events e
    where e.session_id = p_session_id and e.created_at > now() - interval '1 hour';
    if recent >= 120 then
      return;
    end if;
  end if;

  insert into veneto.bio_events
    (event, page, button, href, session_id, referrer, utm_source, utm_medium, utm_campaign, utm_content, device, lang)
  values (
    p_event,
    left(coalesce(nullif(p_page, ''), '/bio/'), 120),
    left(p_button, 80),
    left(p_href, 300),
    left(p_session_id, 64),
    left(nullif(p_referrer, ''), 300),
    left(nullif(p_utm_source, ''), 80),
    left(nullif(p_utm_medium, ''), 80),
    left(nullif(p_utm_campaign, ''), 120),
    left(nullif(p_utm_content, ''), 120),
    case when p_device in ('mobile', 'tablet', 'desktop') then p_device else null end,
    left(nullif(p_lang, ''), 16)
  );
end;
$$;
comment on function public.veneto_track is 'Veneto: grava visita ou clique do link na bio em veneto.bio_events.';
revoke all on function public.veneto_track(text, text, text, text, text, text, text, text, text, text, text, text) from public;
grant execute on function public.veneto_track(text, text, text, text, text, text, text, text, text, text, text, text) to anon;

-- ------------------------------------------------------------
-- Agregados para o dashboard (exige chave de acesso)
-- ------------------------------------------------------------
create or replace function public.veneto_bio_stats(p_key text, p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  ok boolean;
begin
  select exists (select 1 from veneto.dashboard_keys k where k.key = p_key) into ok;
  if not ok then
    raise exception 'chave de acesso inválida' using errcode = '28000';
  end if;

  return jsonb_build_object(
    'from', p_from,
    'to',   p_to,
    'views',    (select count(*) from veneto.bio_events e where e.event = 'view'  and e.created_at >= p_from and e.created_at < p_to),
    'visitors', (select count(distinct e.session_id) from veneto.bio_events e where e.event = 'view' and e.created_at >= p_from and e.created_at < p_to),
    'clicks',   (select count(*) from veneto.bio_events e where e.event = 'click' and e.created_at >= p_from and e.created_at < p_to),
    'clickers', (select count(distinct e.session_id) from veneto.bio_events e where e.event = 'click' and e.created_at >= p_from and e.created_at < p_to),
    'buttons', (
      select coalesce(jsonb_agg(jsonb_build_object('button', t.button, 'href', t.href, 'clicks', t.c, 'clickers', t.u) order by t.c desc), '[]'::jsonb)
      from (
        select e.button, max(e.href) as href, count(*) as c, count(distinct e.session_id) as u
        from veneto.bio_events e
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
        from veneto.bio_events e
        where e.created_at >= p_from and e.created_at < p_to
        group by 1
      ) t
    ),
    'sources', (
      select coalesce(jsonb_agg(jsonb_build_object('source', t.s, 'views', t.v) order by t.v desc), '[]'::jsonb)
      from (
        select coalesce(nullif(e.utm_source, ''), substring(e.referrer from '^https?://([^/]+)'), 'direto') as s,
               count(*) as v
        from veneto.bio_events e
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
        from veneto.bio_events e
        where e.event = 'view' and e.created_at >= p_from and e.created_at < p_to
        group by 1
      ) t
    )
  );
end;
$$;
comment on function public.veneto_bio_stats is 'Veneto: agregados do link na bio para o dashboard. Exige chave cadastrada em veneto.dashboard_keys.';
revoke all on function public.veneto_bio_stats(text, timestamptz, timestamptz) from public;
grant execute on function public.veneto_bio_stats(text, timestamptz, timestamptz) to anon;
