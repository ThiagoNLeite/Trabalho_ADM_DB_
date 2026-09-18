-- =============================================================================
-- 04_audit_setup.sql
-- Projeto: Movimentador de Contas e Rastreabilidade
-- Etapa 3.1: Implementação da trilha de auditoria
-- -----------------------------------------------------------------------------
-- Executar conectado ao banco movimentador_contas como superusuário (o dono da
-- função SECURITY DEFINER precisa ser um papel confiável -- aqui, postgres).
-- =============================================================================

\connect movimentador_contas

-- =============================================================================
-- 3.1.a Tabela de log (audit.logged_actions)
-- =============================================================================

CREATE TABLE audit.logged_actions (
    id                  BIGSERIAL     PRIMARY KEY,
    schema_name         TEXT          NOT NULL,
    table_name          TEXT          NOT NULL,
    row_pk              TEXT          NOT NULL,          -- id do registro afetado, em texto
    session_user_name   TEXT          NOT NULL,           -- quem executou (login de sessão no SGBD)
    application_name    TEXT,                             -- de onde partiu a conexão (psql, app, etc.)
    client_addr         INET,                              -- origem de rede, quando disponível
    transaction_id      BIGINT        NOT NULL DEFAULT txid_current(),
    action_tstamp       TIMESTAMPTZ   NOT NULL DEFAULT clock_timestamp(),
    action               CHAR(1)      NOT NULL CHECK (action IN ('I', 'U', 'D')),
    old_data            JSONB,                             -- estado anterior (UPDATE/DELETE)
    new_data            JSONB                              -- estado posterior (INSERT/UPDATE)
);

COMMENT ON TABLE audit.logged_actions IS
    'Trilha de auditoria imutável. Alimentada exclusivamente pela função '
    'audit.if_modified_func() via trigger SECURITY DEFINER -- nenhuma role de '
    'aplicação possui INSERT/UPDATE/DELETE direto nesta tabela.';

CREATE INDEX idx_audit_table_tstamp ON audit.logged_actions (table_name, action_tstamp);
CREATE INDEX idx_audit_session_user ON audit.logged_actions (session_user_name);
CREATE INDEX idx_audit_row_pk       ON audit.logged_actions (schema_name, table_name, row_pk);

-- Nenhum GRANT de INSERT/UPDATE/DELETE é concedido a ninguém (nem ao DBA --
-- ver 03_security_rbac.sql). Isso é o que garante a imutabilidade do histórico:
-- mesmo um superusuário mal-intencionado precisaria contornar o próprio SGBD
-- (ex.: editar arquivos no disco), o que foge do escopo de controle via SQL,
-- mas fica fora do alcance de qualquer sessão de aplicação.
--
-- O DBA (role_admin_workflow, definida em 03_security_rbac.sql) recebe apenas
-- SELECT, para poder investigar -- nunca para poder alterar.
GRANT SELECT ON audit.logged_actions TO role_admin_workflow;

-- =============================================================================
-- 3.1.b Função de trigger genérica (SECURITY DEFINER)
-- =============================================================================
-- SECURITY DEFINER faz a função executar com os privilégios do seu DONO
-- (postgres), e não com os privilégios de quem disparou o INSERT/UPDATE/DELETE
-- na tabela de negócio. É isso que permite que usr_auditor_op (role_operacional,
-- sem nenhum GRANT em audit.logged_actions) ainda assim gere um registro de
-- auditoria válido ao inserir uma movimentação.
--
-- SET search_path fixo evita "search_path hijacking" (prática recomendada para
-- toda função SECURITY DEFINER).

CREATE OR REPLACE FUNCTION audit.if_modified_func()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = audit, pg_temp
AS $$
DECLARE
    v_row_pk TEXT;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_row_pk := (to_jsonb(OLD) ->> 'id');
        INSERT INTO audit.logged_actions
            (schema_name, table_name, row_pk, session_user_name, application_name,
             client_addr, action, old_data, new_data)
        VALUES
            (TG_TABLE_SCHEMA, TG_TABLE_NAME, v_row_pk, session_user,
             current_setting('application_name', true), inet_client_addr(),
             'D', to_jsonb(OLD), NULL);
        RETURN OLD;

    ELSIF TG_OP = 'UPDATE' THEN
        v_row_pk := (to_jsonb(NEW) ->> 'id');
        INSERT INTO audit.logged_actions
            (schema_name, table_name, row_pk, session_user_name, application_name,
             client_addr, action, old_data, new_data)
        VALUES
            (TG_TABLE_SCHEMA, TG_TABLE_NAME, v_row_pk, session_user,
             current_setting('application_name', true), inet_client_addr(),
             'U', to_jsonb(OLD), to_jsonb(NEW));
        RETURN NEW;

    ELSIF TG_OP = 'INSERT' THEN
        v_row_pk := (to_jsonb(NEW) ->> 'id');
        INSERT INTO audit.logged_actions
            (schema_name, table_name, row_pk, session_user_name, application_name,
             client_addr, action, old_data, new_data)
        VALUES
            (TG_TABLE_SCHEMA, TG_TABLE_NAME, v_row_pk, session_user,
             current_setting('application_name', true), inet_client_addr(),
             'I', NULL, to_jsonb(NEW));
        RETURN NEW;
    END IF;

    RETURN NULL;
END;
$$;

ALTER FUNCTION audit.if_modified_func() OWNER TO postgres;
REVOKE EXECUTE ON FUNCTION audit.if_modified_func() FROM PUBLIC;

COMMENT ON FUNCTION audit.if_modified_func() IS
    'Função de trigger genérica (SECURITY DEFINER) que grava OLD/NEW, usuário '
    'de sessão e timestamp em audit.logged_actions para qualquer INSERT, '
    'UPDATE ou DELETE nas tabelas monitoradas.';

-- =============================================================================
-- 3.1.c Triggers nas tabelas monitoradas
-- =============================================================================
-- Requisito mínimo do enunciado: MOVIMENTACOES e CONTAS_WORKFLOW.
-- Estendemos também a COMENTARIOS por coerência (mesma sensibilidade de
-- histórico), o que fortalece o relatório forense sem contrariar o escopo.

CREATE TRIGGER trg_audit_movimentacoes
    AFTER INSERT OR UPDATE OR DELETE ON workflow.movimentacoes
    FOR EACH ROW EXECUTE FUNCTION audit.if_modified_func();

CREATE TRIGGER trg_audit_contas_workflow
    AFTER INSERT OR UPDATE OR DELETE ON workflow.contas_workflow
    FOR EACH ROW EXECUTE FUNCTION audit.if_modified_func();

CREATE TRIGGER trg_audit_comentarios
    AFTER INSERT OR UPDATE OR DELETE ON workflow.comentarios
    FOR EACH ROW EXECUTE FUNCTION audit.if_modified_func();

-- =============================================================================
-- 3.1.d Sanidade: confirmar que o backfill inicial (script 02) NÃO aparece no
-- log, pois os triggers só foram criados agora -- e provar que uma alteração
-- feita a partir deste ponto já é capturada.
-- =============================================================================
\echo '--- Trilha de auditoria antes de qualquer alteração pós-trigger (deve estar vazia) ---'
SELECT count(*) AS total_eventos FROM audit.logged_actions;

-- Sanidade funcional (executada como superusuário, apenas para provar que a
-- trigger está ativa; os testes de RBAC de verdade ficam no script 05).
UPDATE workflow.contas_workflow
   SET status_conta = 'EM_ANALISE'
 WHERE codigo_conta = 'CTA-000011';

\echo '--- Evento gerado automaticamente pela trigger ---'
SELECT id, table_name, action, session_user_name, action_tstamp, row_pk
FROM audit.logged_actions
ORDER BY id DESC
LIMIT 1;

-- Fim do script 04.
