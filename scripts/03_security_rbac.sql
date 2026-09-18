-- =============================================================================
-- 03_security_rbac.sql
-- Projeto: Movimentador de Contas e Rastreabilidade
-- Etapa 2: Controle de Acesso (RBAC) e Conformidade com a LGPD
-- -----------------------------------------------------------------------------
-- Executar conectado ao banco movimentador_contas como superusuário.
-- =============================================================================

\connect movimentador_contas

-- =============================================================================
-- 2.1 HIGIENIZAÇÃO DE ACESSOS PADRÃO (ZERO TRUST)
-- =============================================================================
-- Por padrão, o PostgreSQL concede USAGE em esquemas novos e CONNECT no banco
-- à role PUBLIC. Revogamos tudo explicitamente: nada é acessível até que um
-- privilégio seja concedido de forma nominal a uma role específica.

REVOKE ALL ON DATABASE movimentador_contas FROM PUBLIC;

REVOKE ALL ON SCHEMA workflow FROM PUBLIC;
REVOKE ALL ON SCHEMA audit    FROM PUBLIC;
REVOKE ALL ON SCHEMA public   FROM PUBLIC;

REVOKE ALL ON ALL TABLES    IN SCHEMA workflow FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA workflow FROM PUBLIC;
REVOKE ALL ON ALL TABLES    IN SCHEMA audit    FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA audit    FROM PUBLIC;

-- Garante que qualquer objeto futuro também nasça sem privilégios para PUBLIC.
ALTER DEFAULT PRIVILEGES IN SCHEMA workflow REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA audit    REVOKE ALL ON TABLES FROM PUBLIC;

-- =============================================================================
-- 2.2 DEFINIÇÃO DE PERFIS FUNCIONAIS (ROLES NOLOGIN)
-- =============================================================================
-- Roles de grupo consolidam permissões por perfil de negócio. Usuários de
-- login (2.3) apenas HERDAM dessas roles -- nunca recebem GRANT direto em
-- objetos, o que mantém a matriz de permissões auditável em um único lugar.

CREATE ROLE role_operacional    NOLOGIN;
CREATE ROLE role_gestao         NOLOGIN;
CREATE ROLE role_admin_workflow NOLOGIN;

COMMENT ON ROLE role_operacional    IS 'Perfil operacional: consulta contas/setores, registra movimentações e comentários. Sem DELETE e sem UPDATE em histórico imutável.';
COMMENT ON ROLE role_gestao         IS 'Perfil de gestão: SELECT estrito em visões/relatórios consolidados (sem acesso direto às tabelas base).';
COMMENT ON ROLE role_admin_workflow IS 'Perfil de administração do sistema satélite: controle total sobre as tabelas e sequências do esquema workflow, leitura da trilha de auditoria.';

-- Conexão ao banco é privilégio próprio (não vem de "IN ROLE"), então cada
-- role de grupo que poderá logar (via herança) precisa de CONNECT.
GRANT CONNECT ON DATABASE movimentador_contas TO role_operacional, role_gestao, role_admin_workflow;

-- -----------------------------------------------------------------------------
-- role_operacional
-- -----------------------------------------------------------------------------
GRANT USAGE ON SCHEMA workflow TO role_operacional;

-- Consulta de dados operacionais de contas e setores
GRANT SELECT ON workflow.setores          TO role_operacional;
GRANT SELECT ON workflow.contas_workflow  TO role_operacional;

-- Atualiza apenas os campos de "onde a conta está agora" (a movimentação em si
-- é gravada em workflow.movimentacoes, que é append-only para este perfil).
GRANT UPDATE (setor_atual_id, status_conta) ON workflow.contas_workflow TO role_operacional;

-- Registrar novas movimentações e comentários: apenas INSERT + SELECT.
-- Note a ausência proposital de UPDATE/DELETE em movimentacoes e comentarios:
-- histórico é imutável por design (regra de negócio nº 5 da proposta).
GRANT SELECT, INSERT ON workflow.movimentacoes TO role_operacional;
GRANT SELECT, INSERT ON workflow.comentarios   TO role_operacional;
REVOKE UPDATE, DELETE, TRUNCATE ON workflow.movimentacoes FROM role_operacional;
REVOKE UPDATE, DELETE, TRUNCATE ON workflow.comentarios   FROM role_operacional;

-- Sequências das tabelas em que o perfil pode inserir.
GRANT USAGE, SELECT ON SEQUENCE workflow.movimentacoes_id_seq TO role_operacional;
GRANT USAGE, SELECT ON SEQUENCE workflow.comentarios_id_seq   TO role_operacional;

-- Segurança em nível de coluna (LGPD): consulta apenas colunas públicas de
-- USUARIOS. A coluna senha_hash (credencial) fica fora do GRANT abaixo.
GRANT SELECT (id, login_corporativo, nome_completo, setor_id, perfil_acesso)
    ON workflow.usuarios TO role_operacional;

-- -----------------------------------------------------------------------------
-- role_gestao
-- -----------------------------------------------------------------------------
GRANT USAGE ON SCHEMA workflow TO role_gestao;

-- Leitura de referência (não sensível) para compor relatórios com nomes de setor.
GRANT SELECT ON workflow.setores TO role_gestao;

-- Mesma restrição de coluna aplicada ao perfil operacional.
GRANT SELECT (id, login_corporativo, nome_completo, setor_id, perfil_acesso)
    ON workflow.usuarios TO role_gestao;

-- Importante: NENHUM GRANT direto em contas_workflow, movimentacoes ou
-- comentarios. O acesso de gestão é servido exclusivamente pela view
-- workflow.vw_dashboard_gestao (criada mais abaixo), que já chega agregada e
-- sem identificadores sensíveis.

-- -----------------------------------------------------------------------------
-- role_admin_workflow
-- -----------------------------------------------------------------------------
GRANT USAGE ON SCHEMA workflow TO role_admin_workflow;

GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA workflow TO role_admin_workflow;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA workflow TO role_admin_workflow;

ALTER DEFAULT PRIVILEGES IN SCHEMA workflow
    GRANT ALL PRIVILEGES ON TABLES TO role_admin_workflow;
ALTER DEFAULT PRIVILEGES IN SCHEMA workflow
    GRANT ALL PRIVILEGES ON SEQUENCES TO role_admin_workflow;

-- O DBA pode investigar a trilha de auditoria, mas mesmo ele não recebe
-- INSERT/UPDATE/DELETE em audit.logged_actions: a tabela só é escrita pela
-- função de trigger SECURITY DEFINER. Como audit.logged_actions só é criada
-- no próximo script, o GRANT de SELECT correspondente fica em
-- 04_audit_setup.sql (logo após o CREATE TABLE), mantendo a ordem de
-- execução consistente e sem erros.
GRANT USAGE ON SCHEMA audit TO role_admin_workflow;

-- =============================================================================
-- 2.3 CRIAÇÃO DE USUÁRIOS E ASSOCIAÇÃO ÀS ROLES
-- =============================================================================
-- password_encryption = scram-sha-256 já foi definido no script 01; toda senha
-- abaixo é automaticamente armazenada com esse algoritmo (nunca MD5/texto puro).
-- As senhas aqui são apenas para fins didáticos/demo -- em produção viriam de
-- um cofre de segredos, nunca de um script versionado (ver seção "Segurança"
-- do README).

DROP ROLE IF EXISTS usr_auditor_op;
DROP ROLE IF EXISTS usr_coordenador_gestao;
DROP ROLE IF EXISTS usr_dba_admin;

CREATE ROLE usr_auditor_op
    LOGIN
    PASSWORD 'Operacional#2026'
    IN ROLE role_operacional;

CREATE ROLE usr_coordenador_gestao
    LOGIN
    PASSWORD 'Gestao#2026'
    IN ROLE role_gestao;

CREATE ROLE usr_dba_admin
    LOGIN
    PASSWORD 'AdminWorkflow#2026'
    IN ROLE role_admin_workflow;

COMMENT ON ROLE usr_auditor_op         IS 'Usuário de teste do perfil operacional (setor Auditoria).';
COMMENT ON ROLE usr_coordenador_gestao IS 'Usuário de teste do perfil de gestão (dashboards/relatórios).';
COMMENT ON ROLE usr_dba_admin          IS 'Usuário de teste do perfil administrador do workflow.';

-- Endurecimento básico de sessão para os usuários operacionais/gestão
-- (o DBA precisa de mais liberdade para manutenção).
ALTER ROLE usr_auditor_op         CONNECTION LIMIT 5;
ALTER ROLE usr_coordenador_gestao CONNECTION LIMIT 5;

-- =============================================================================
-- 2.4 MASCARAMENTO E MINIMIZAÇÃO DE DADOS (LGPD) -- VIEW SEGURA
-- =============================================================================
-- View gerencial: agrega tempos de atendimento e totalizadores por setor.
-- Não expõe nome de paciente (esta tabela nunca guarda dados clínicos -- o MV
-- é a fonte oficial disso), nem qualquer coluna de workflow.usuarios.
CREATE OR REPLACE VIEW workflow.vw_dashboard_gestao AS
SELECT
    s.nome                                   AS setor,
    COUNT(c.id)                              AS total_contas,
    COUNT(c.id) FILTER (WHERE c.status_conta <> 'FINALIZADA')  AS contas_abertas,
    COUNT(c.id) FILTER (WHERE c.status_conta =  'FINALIZADA')  AS contas_concluidas,
    ROUND(
        AVG(EXTRACT(EPOCH FROM (now() - c.data_entrada)) / 3600.0)
        FILTER (WHERE c.status_conta <> 'FINALIZADA')
    , 2)                                      AS tempo_medio_aberto_horas
FROM workflow.setores s
LEFT JOIN workflow.contas_workflow c ON c.setor_atual_id = s.id
GROUP BY s.nome
ORDER BY s.nome;

COMMENT ON VIEW workflow.vw_dashboard_gestao IS
    'View segura (LGPD): consolida indicadores por setor sem expor identificadores pessoais, senha_hash ou dados sensíveis de pacientes.';

GRANT SELECT ON workflow.vw_dashboard_gestao TO role_gestao, role_admin_workflow;

-- =============================================================================
-- 2.5 VERIFICAÇÃO RÁPIDA DA MATRIZ DE PRIVILÉGIOS
-- =============================================================================
\echo '--- Privilégios em tabelas do esquema workflow por role ---'
SELECT grantee, table_schema, table_name, privilege_type
FROM information_schema.role_table_grants
WHERE table_schema IN ('workflow', 'audit')
  AND grantee IN ('role_operacional', 'role_gestao', 'role_admin_workflow')
ORDER BY grantee, table_name, privilege_type;

\echo '--- Colunas visíveis em workflow.usuarios por role (column privileges) ---'
SELECT grantee, table_name, column_name, privilege_type
FROM information_schema.role_column_grants
WHERE table_schema = 'workflow' AND table_name = 'usuarios'
ORDER BY grantee, column_name;

-- Fim do script 03.
