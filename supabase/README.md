# Supabase — projeto compartilhado "Grupo NKZ"

Tudo da marca Veneto vive no schema **`veneto`**, que não é exposto pela API.
A API pública tem apenas duas funções, ambas com prefixo `veneto_`:

| Objeto | Para quê |
|---|---|
| `veneto.bio_events` | visitas e cliques por página (bio e páginas de venda) |
| `veneto.leads` | leads captados nos pop-ups das páginas de venda |
| `veneto.dashboard_keys` | chaves de acesso ao dashboard |
| `public.veneto_track(...)` | RPC chamada pela página para gravar um evento |
| `public.veneto_lead(...)` | RPC do pop-up: grava em `veneto.leads` e espelha na `00. Central de Leads` (utm_funil `veneto-<página>`) |
| `public.veneto_bio_stats(key, from, to, page)` | RPC chamada pelo dashboard; exige chave; filtra por página |

Para criar uma nova chave de acesso ao dashboard, no SQL Editor:

```sql
insert into veneto.dashboard_keys (key, label) values ('sua-chave', 'Nome de quem usa');
```

A migração aplicada está em `migrations/`.
