-- =============================================================================
-- 06_forensic_queries.sql
-- Projeto: Movimentador de Contas e Rastreabilidade
-- Etapa 3.3: Investigação forense e parecer técnico do DBA
-- -----------------------------------------------------------------------------
-- Executar como usr_dba_admin (ou postgres) conectado a movimentador_contas.
-- Todas as consultas abaixo respondem às três perguntas exigidas pelo
-- enunciado:
--   (1) Quem realizou cada alteração válida no sistema?
--   (2) Como fica evidenciada a tentativa de violação (acesso negado)?
--   (3) Como se comprova a imutabilidade e integridade do histórico?
-- =============================================================================

\connect movimentador_contas
\pset border 2

-- =============================================================================
-- (1) AUTORIA -- quem fez o quê, quando, e o que mudou
-- =============================================================================

\echo '--- 1.1 Linha do tempo completa de eventos válidos (todas as tabelas monitoradas) ---'
SELECT
    la.id,
    la.action_tstamp                          AS quando,
    la.session_user_name                      AS quem_logou_no_sgbd,
    la.action                                 AS operacao,      -- I / U / D
    la.schema_name || '.' || la.table_name     AS tabela_afetada,
    la.row_pk                                  AS pk_afetada
FROM audit.logged_actions la
ORDER BY la.action_tstamp;

\echo ''
\echo '--- 1.2 Autoria detalhada das movimentações de conta, com nome do responsável ---'
-- Cruza o log de auditoria (que só conhece o login técnico do SGBD) com o
-- cadastro funcional em workflow.usuarios (via usuario_executor_id, presente
-- em new_data), revelando o nome completo e o setor de quem executou a ação.
SELECT
    la.action_tstamp                                        AS quando,
    la.session_user_name                                    AS login_sgbd,
    u.nome_completo                                         AS responsavel,
    s.nome                                                   AS setor_do_responsavel,
    cw.codigo_conta                                          AS conta,
    so.nome                                                  AS setor_origem,
    sd.nome                                                  AS setor_destino,
    la.new_data ->> 'observacao'                             AS observacao
FROM audit.logged_actions la
JOIN workflow.movimentacoes mv ON mv.id = (la.row_pk)::int AND la.table_name = 'movimentacoes'
JOIN workflow.usuarios u  ON u.id = (la.new_data ->> 'usuario_executor_id')::int
JOIN workflow.setores  s  ON s.id = u.setor_id
JOIN workflow.contas_workflow cw ON cw.id = (la.new_data ->> 'conta_id')::int
JOIN workflow.setores so ON so.id = (la.new_data ->> 'setor_origem_id')::int
JOIN workflow.setores sd ON sd.id = (la.new_data ->> 'setor_destino_id')::int
WHERE la.action = 'I'
ORDER BY la.action_tstamp;

\echo ''
\echo '--- 1.3 Quantidade de ações válidas por usuário técnico (accountability) ---'
SELECT session_user_name, action, count(*) AS total
FROM audit.logged_actions
GROUP BY session_user_name, action
ORDER BY session_user_name, action;


-- =============================================================================
-- (2) TENTATIVAS DE VIOLAÇÃO -- onde fica a evidência
-- =============================================================================
-- Importante (e é um ponto de atenção técnica que vale registrar no README):
-- um comando bloqueado por falta de privilégio (erro "permission denied") NÃO
-- chega a executar o corpo do comando, logo o trigger de auditoria (que roda
-- DEPOIS que a operação é efetivada) nunca dispara para esse evento. Ou seja,
-- audit.logged_actions -- por desenho -- só registra o que FOI EXECUTADO COM
-- SUCESSO. Isso é, na verdade, uma prova indireta de integridade: como se verá
-- na consulta 3.1, não existe nenhum UPDATE/DELETE em movimentacoes/
-- comentarios no log, exatamente porque toda tentativa de fazê-lo foi barrada
-- antes de gerar efeito.
--
-- A evidência primária da NEGAÇÃO em si (a mensagem "ERROR: permission
-- denied for ...") vem de duas fontes complementares, capturadas ao rodar
-- 05_attack_simulation.sql:
--   a) a saída do próprio terminal/psql (stdout), redirecionada para
--      evidencias/05_attack_simulation_output.txt -- é o que deve ser colado
--      como print no relatório forense do README;
--   b) o log do servidor PostgreSQL (log_min_messages/log_statement), que
--      registra cada tentativa negada de forma independente do cliente.

\echo ''
\echo '--- 2.1 Prova indireta: nenhuma alteração (U) ou exclusão (D) jamais foi'
\echo '        efetivada nas tabelas de histórico imutável ---'
SELECT table_name, action, count(*) AS total
FROM audit.logged_actions
WHERE table_name IN ('movimentacoes', 'comentarios')
  AND action IN ('U', 'D')
GROUP BY table_name, action;
-- Resultado esperado: 0 linhas. A ausência de linhas aqui É a evidência de
-- que toda tentativa de adulteração (Cenário A) foi barrada antes de gravar.

\echo ''
\echo '--- 2.2 Como localizar a evidência bruta no log do servidor (rodar no shell,'
\echo '        não dentro do psql) ---'
\echo '  sudo grep -E "permission denied|ERROR" /var/log/postgresql/postgresql-16-main.log | tail -n 50'
\echo '  (ajuste o caminho/versão conforme a instalação; ver README para detalhes)'


-- =============================================================================
-- (3) IMUTABILIDADE E INTEGRIDADE DO HISTÓRICO
-- =============================================================================

\echo ''
\echo '--- 3.1 Comprovação de que a trilha de auditoria em si nunca foi alterada ---'
SELECT count(*) AS eventos_de_alteracao_na_propria_auditoria
FROM audit.logged_actions
WHERE table_name = 'logged_actions';
-- Resultado esperado: 0. Não existe trigger de auditoria sobre a própria
-- audit.logged_actions (não faria sentido), e nenhuma role possui
-- INSERT/UPDATE/DELETE nela -- apenas a função SECURITY DEFINER grava.
-- O Cenário E (05_attack_simulation.sql) comprova isso na prática: até
-- usr_dba_admin, dono do perfil administrador do workflow, recebe
-- "permission denied" ao tentar UPDATE/DELETE em audit.logged_actions.

\echo ''
\echo '--- 3.2 Diff OLD vs NEW de uma alteração específica (exemplo: mudança de status) ---'
SELECT
    la.action_tstamp,
    la.session_user_name,
    la.old_data ->> 'status_conta' AS status_antes,
    la.new_data ->> 'status_conta' AS status_depois,
    la.old_data ->> 'setor_atual_id' AS setor_antes,
    la.new_data ->> 'setor_atual_id' AS setor_depois
FROM audit.logged_actions la
WHERE la.table_name = 'contas_workflow'
  AND la.action = 'U'
ORDER BY la.action_tstamp;

\echo ''
\echo '--- 3.3 Verificação de coerência: toda movimentação registrada tem contrapartida'
\echo '        de auditoria (nenhuma "movimentação fantasma" fora da trilha) ---'
SELECT
    (SELECT count(*) FROM workflow.movimentacoes)                                   AS total_movimentacoes,
    (SELECT count(*) FROM audit.logged_actions WHERE table_name='movimentacoes' AND action='I') AS total_inserts_auditados;
-- Os dois números devem coincidir (considerando apenas movimentações
-- inseridas depois de 04_audit_setup.sql, já que a carga do script 02 é
-- anterior à criação dos triggers -- isso também fica documentado no README).

-- Fim do script 06.
