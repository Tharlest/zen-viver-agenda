-- ============================================================
--  ZEN VIVER — Migracao: Painel de Administracao
--  Config por empresa (jsonb), celular do cliente e RPCs de admin.
--  Idempotente: pode rodar mais de uma vez sem quebrar nada.
-- ============================================================
set search_path = public, extensions;

-- ---------- COLUNAS NOVAS ----------
alter table empresas      add column if not exists config jsonb not null default '{}'::jsonb;
alter table colaboradores add column if not exists celular text;

-- ---------- CONFIG DA EMPRESA: LER ----------
-- Master le qualquer empresa; Gestor so a dele.
create or replace function app_empresa_config(p_token uuid, p_empresa uuid)
  returns jsonb language plpgsql security definer set search_path=public, extensions as $$
declare v_role text; v_ref uuid; e record;
begin
  select (s).v_role,(s).v_ref into v_role,v_ref from (select _sessao(p_token, array['master','gestor']) s) z;
  if v_role='gestor' then p_empresa := v_ref; end if;
  select * into e from empresas where id=p_empresa;
  if e.id is null then raise exception 'EMPRESA_NAO_ENCONTRADA'; end if;
  return jsonb_build_object('id',e.id,'nome',e.nome,'slug',e.slug,'dias',to_jsonb(e.dias),
    'limiteSemana',e.limite_semana,'gestorNome',e.gestor_nome,'gestorEmail',e.gestor_email,
    'config',coalesce(e.config,'{}'::jsonb));
end; $$;

-- ---------- CONFIG DA EMPRESA: SALVAR (merge) ----------
-- Master altera tudo; Gestor so a propria empresa e NAO altera 'servico'.
create or replace function app_empresa_config_set(p_token uuid, p_empresa uuid, p_patch jsonb)
  returns jsonb language plpgsql security definer set search_path=public, extensions as $$
declare v_role text; v_ref uuid; e record;
begin
  select (s).v_role,(s).v_ref into v_role,v_ref from (select _sessao(p_token, array['master','gestor']) s) z;
  if v_role='gestor' then p_empresa := v_ref; p_patch := coalesce(p_patch,'{}'::jsonb) - 'servico'; end if;
  select * into e from empresas where id=p_empresa;
  if e.id is null then raise exception 'EMPRESA_NAO_ENCONTRADA'; end if;
  update empresas set config = coalesce(config,'{}'::jsonb) || coalesce(p_patch,'{}'::jsonb) where id=p_empresa;
  return jsonb_build_object('ok',true,'config',(select config from empresas where id=p_empresa));
end; $$;

-- ---------- CLIENTES (colaboradores) COM HISTORICO ----------
create or replace function app_listar_clientes(p_token uuid, p_empresa uuid)
  returns jsonb language plpgsql security definer set search_path=public, extensions as $$
declare v_role text; v_ref uuid;
begin
  select (s).v_role,(s).v_ref into v_role,v_ref from (select _sessao(p_token, array['master','gestor']) s) z;
  if v_role='gestor' then p_empresa := v_ref; end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',c.id,'nome',c.nome,'email',c.email,'celular',c.celular,
      'empresa',e.nome,
      'incluidoEm',to_char(c.criado_em,'YYYY-MM-DD'),
      'totalAtend',(select count(*) from agendamentos a where a.empresa_id=c.empresa_id and lower(a.colaborador_email)=lower(c.email)),
      'compareceu',(select count(*) from agendamentos a where a.empresa_id=c.empresa_id and lower(a.colaborador_email)=lower(c.email) and a.status='COMPARECEU'),
      'faltou',(select count(*) from agendamentos a where a.empresa_id=c.empresa_id and lower(a.colaborador_email)=lower(c.email) and a.status='FALTOU'),
      'datas',(select coalesce(jsonb_agg(d order by d desc),'[]'::jsonb)
               from (select distinct a.data d from agendamentos a
                     where a.empresa_id=c.empresa_id and lower(a.colaborador_email)=lower(c.email)) t)
    ) order by c.nome), '[]'::jsonb)
    from colaboradores c join empresas e on e.id=c.empresa_id
    where (p_empresa is null or c.empresa_id=p_empresa)
  );
end; $$;

-- ---------- CADASTRO DE COLABORADOR PASSA A CAPTURAR CELULAR ----------
drop function if exists app_cadastrar_colaborador(text, text, text);
create or replace function app_cadastrar_colaborador(p_slug text, p_nome text, p_email text, p_celular text default null)
  returns jsonb language plpgsql security definer set search_path=public, extensions as $$
declare e record; v_nome text; v_email text; v_cel text; v_id uuid; c record;
begin
  v_nome := trim(p_nome); v_email := lower(trim(p_email)); v_cel := nullif(trim(coalesce(p_celular,'')),'');
  if length(v_nome)<2 then raise exception 'NOME_COLAB'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'EMAIL_INVALIDO'; end if;
  select * into e from empresas where slug=p_slug and ativa;
  if e.id is null then raise exception 'EMPRESA_NAO_ENCONTRADA'; end if;
  select * into c from colaboradores where empresa_id=e.id and lower(email)=v_email;
  if c.id is not null then
    update colaboradores set nome=v_nome, celular=coalesce(v_cel,celular) where id=c.id;
    return jsonb_build_object('id',c.id,'nome',v_nome,'email',v_email);
  end if;
  insert into colaboradores(empresa_id,nome,email,celular) values (e.id,v_nome,v_email,v_cel) returning id into v_id;
  return jsonb_build_object('id',v_id,'nome',v_nome,'email',v_email);
end; $$;

-- ---------- GRANTS (anon/authenticated executam as funcoes app_*) ----------
grant execute on function app_empresa_config(uuid,uuid)            to anon, authenticated;
grant execute on function app_empresa_config_set(uuid,uuid,jsonb)  to anon, authenticated;
grant execute on function app_listar_clientes(uuid,uuid)           to anon, authenticated;
grant execute on function app_cadastrar_colaborador(text,text,text,text) to anon, authenticated;
