-- =============================================================================
-- 05_attack_simulation.sql
-- Projeto: Movimentador de Contas e Rastreabilidade
-- Etapa 3.2: Bateria de testes ofensivos (simulação de violações de segurança)
-- -----------------------------------------------------------------------------
-- Como executar: psql -U postgres -d movimentador_contas -f 05_attack_simulation.sql
--   > tee evidencias/05_attack_simulation_output.txt
-- (o "tee" grava a saída em arquivo para servir de evidência no README/relatório
-- forense; no Windows use `psql ... | Tee-Object -FilePath ...`).
--
-- Técnica usada para trocar de identidade dentro de UM ÚNICO script: em vez de
-- reconectar via `\c` (o que exigiria senha interativa e quebraria a execução
-- não interativa), usamos SET SESSION AUTHORIZATION. Diferente de SET ROLE,
-- SET SESSION AUTHORIZATION também troca session_user -- exatamente o campo
-- que a trigger de auditoria grava --, então o rastro fica idêntico ao de uma
-- conexão real como aquele usuário. Só um superusuário pode fazer essa troca
-- sem senha, por isso o script deve ser executado como "postgres".
--
-- Para a apresentação em sala (demonstração ao vivo pedida no enunciado),
-- também é possível reproduzir cada cenário com uma conexão de verdade:
--   psql -U usr_auditor_op -d movimentador_contas -h localhost -W
-- (a senha de demo está em 03_security_rbac.sql).
--
-- Erros são ESPERADOS neste script (é o objetivo do teste). Por isso
-- desligamos ON_ERROR_STOP -- o psql segue para o próximo comando mesmo
-- depois de um "permission denied".
-- =============================================================================

\connect movimentador_contas
\set ON_ERROR_STOP off
\pset pager off

\echo '================================================================='
\echo ' CENÁRIO A -- Tentativa de adulteração de histórico (DELETE/UPDATE'
\echo ' indevidos em workflow.movimentacoes por usr_auditor_op)'
\echo ' Resultado esperado: ERRO de permissão em ambos os comandos.'
\echo '================================================================='

SET SESSION AUTHORIZATION usr_auditor_op;
SELECT current_user AS conectado_como, session_user AS session_user_registrado_no_log;

\echo '--- (A1) DELETE indevido em movimentacoes ---'
DELETE FROM workflow.movimentacoes
 WHERE id = (
    SELECT mv.id FROM workflow.movimentacoes mv
    JOIN workflow.contas_workflow cw ON cw.id = mv.conta_id
    WHERE cw.codigo_conta = 'CTA-000010'
    LIMIT 1
 );

\echo '--- (A2) UPDATE indevido em movimentacoes (tentativa de reescrever histórico) ---'
UPDATE workflow.movimentacoes
   SET observacao = 'HISTORICO ADULTERADO'
 WHERE conta_id = (SELECT id FROM workflow.contas_workflow WHERE codigo_conta = 'CTA-000010');

RESET SESSION AUTHORIZATION;


\echo '================================================================='
\echo ' CENÁRIO B -- Tentativa de acesso a coluna restrita / PII'
\echo ' (SELECT de senha_hash em workflow.usuarios por usr_auditor_op)'
\echo ' Resultado esperado: ERRO de permissão nas colunas restritas;'
\echo ' a consulta apenas às colunas públicas deve funcionar normalmente.'
\echo '================================================================='

SET SESSION AUTHORIZATION usr_auditor_op;

\echo '--- (B1) SELECT * (inclui senha_hash) -- deve ser NEGADO ---'
SELECT * FROM workflow.usuarios;

\echo '--- (B2) SELECT explícito da coluna senha_hash -- deve ser NEGADO ---'
SELECT id, login_corporativo, senha_hash FROM workflow.usuarios;

\echo '--- (B3) Controle: SELECT apenas de colunas públicas -- deve FUNCIONAR ---'
SELECT id, login_corporativo, nome_completo, setor_id, perfil_acesso
FROM workflow.usuarios
ORDER BY id;

RESET SESSION AUTHORIZATION;


\echo '================================================================='
\echo ' CENÁRIO C -- Operação operacional válida, com rastreamento'
\echo ' (usr_auditor_op transfere a Conta 11 da Auditoria para a Central'
\echo ' de Guias e registra um comentário de fluxo)'
\echo ' Resultado esperado: SUCESSO, e o evento deve aparecer depois na'
\echo ' trilha de auditoria (ver 06_forensic_queries.sql) com autoria de'
\echo ' usr_auditor_op.'
\echo '================================================================='

SET SESSION AUTHORIZATION usr_auditor_op;

\echo '--- (C1) Registrar movimentação Auditoria -> Central de Guias ---'
INSERT INTO workflow.movimentacoes (conta_id, setor_origem_id, setor_destino_id, usuario_executor_id, observacao)
SELECT
    c.id,
    (SELECT id FROM workflow.setores WHERE nome = 'Auditoria'),
    (SELECT id FROM workflow.setores WHERE nome = 'Central de Guias'),
    (SELECT id FROM workflow.usuarios WHERE login_corporativo = 'auditor.op'),
    'Auditoria concluída sem pendências. Encaminhada para conferência de guias.'
FROM workflow.contas_workflow c
WHERE c.codigo_conta = 'CTA-000010';

\echo '--- (C2) Atualizar setor atual / status da conta (permitido: colunas liberadas) ---'
UPDATE workflow.contas_workflow
   SET setor_atual_id = (SELECT id FROM workflow.setores WHERE nome = 'Central de Guias'),
       status_conta    = 'ENCAMINHADA'
 WHERE codigo_conta = 'CTA-000010';

\echo '--- (C3) Registrar comentário de fluxo ---'
INSERT INTO workflow.comentarios (conta_id, usuario_autor_id, descricao)
SELECT
    c.id,
    (SELECT id FROM workflow.usuarios WHERE login_corporativo = 'auditor.op'),
    'Guia recebida. Iniciada conferência.'
FROM workflow.contas_workflow c
WHERE c.codigo_conta = 'CTA-000010';

RESET SESSION AUTHORIZATION;

\echo '--- Conferência (executada como DBA/superusuário) ---'
SELECT codigo_conta, status_conta, setor_atual_id FROM workflow.contas_workflow WHERE codigo_conta = 'CTA-000010';


\echo '================================================================='
\echo ' CENÁRIO D (bônus) -- role_gestao tentando ler tabela base'
\echo ' diretamente em vez de usar a view segura'
\echo ' Resultado esperado: ERRO de permissão na tabela base; SUCESSO na'
\echo ' consulta à view workflow.vw_dashboard_gestao.'
\echo '================================================================='

SET SESSION AUTHORIZATION usr_coordenador_gestao;

\echo '--- (D1) SELECT direto em contas_workflow -- deve ser NEGADO ---'
SELECT * FROM workflow.contas_workflow;

\echo '--- (D2) SELECT direto em movimentacoes -- deve ser NEGADO ---'
SELECT * FROM workflow.movimentacoes;

\echo '--- (D3) Controle: consulta pela view segura -- deve FUNCIONAR ---'
SELECT * FROM workflow.vw_dashboard_gestao;

RESET SESSION AUTHORIZATION;


\echo '================================================================='
\echo ' CENÁRIO E (bônus) -- Tentativa de adulterar a própria trilha de'
\echo ' auditoria, mesmo pelo usuário administrador do workflow'
\echo ' Resultado esperado: ERRO de permissão (imutabilidade garantida'
\echo ' mesmo para o perfil ADMINISTRADOR de negócio).'
\echo '================================================================='

SET SESSION AUTHORIZATION usr_dba_admin;

\echo '--- (E1) Controle: usr_dba_admin CONSEGUE ler audit.logged_actions ---'
SELECT count(*) AS total_eventos_visiveis_ao_dba FROM audit.logged_actions;

\echo '--- (E2) usr_dba_admin tentando UPDATE em audit.logged_actions -- deve ser NEGADO ---'
UPDATE audit.logged_actions SET action = 'U' WHERE id = 1;

\echo '--- (E3) usr_dba_admin tentando DELETE em audit.logged_actions -- deve ser NEGADO ---'
DELETE FROM audit.logged_actions WHERE id = 1;

RESET SESSION AUTHORIZATION;

\set ON_ERROR_STOP on
\echo '================================================================='
\echo ' Fim da bateria de testes ofensivos. Copie a saída acima (ou o'
\echo ' conteúdo de evidencias/05_attack_simulation_output.txt, se você'
\echo ' usou o "tee" sugerido no topo do script) para a seção de'
\echo ' Relatório Forense do README.md.'
\echo '================================================================='
-- Fim do script 05.
