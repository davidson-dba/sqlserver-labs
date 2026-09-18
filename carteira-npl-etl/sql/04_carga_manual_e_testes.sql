/* =====================================================================
   04_carga_manual_e_testes.sql

   O QUE ESTE SCRIPT FAZ
   Executa o pipeline inteiro sem SSIS, usando BULK INSERT, e traz as
   consultas de conferencia.

   POR QUE ESTE SCRIPT EXISTE
   Duas razoes praticas.
   Primeira: permite testar e depurar toda a logica T-SQL antes de abrir
   o Visual Studio. Se o pipeline funciona aqui, o SSIS passa a ser
   apenas a camada de transporte, e qualquer erro que aparecer la sera
   de configuracao do pacote, nao de regra de negocio. Isso reduz muito o
   tempo de diagnostico.
   Segunda: mantem o projeto executavel por quem clonar o repositorio sem
   ter SSIS instalado.

   BULK INSERT E O EQUIVALENTE DO DATA FLOW
   Faz exatamente o que o Data Flow do SSIS faria: le o arquivo delimitado
   e joga em tabela, sem converter tipo. A diferenca e que o BULK INSERT
   le a partir do servidor, entao o caminho precisa existir na maquina
   onde o SQL Server roda, nao na sua estacao.
   ===================================================================== */

USE CarteiraNPL;
GO

/* =====================================================================
   PARTE 1 - CARGA MANUAL

   Ajuste @pasta conforme a sua VM.
   ===================================================================== */

DECLARE @pasta        VARCHAR(260) = 'C:\carteira-npl-etl\arquivos\entrada\';
DECLARE @arq_contrato VARCHAR(100) = 'CONTRATOS_237_20260911.csv';
DECLARE @arq_parcela  VARCHAR(100) = 'PARCELAS_237_20260911.csv';
DECLARE @cedente      VARCHAR(10)  = '237';
DECLARE @id_lote      INT;
DECLARE @sql          NVARCHAR(MAX);

/* 1. Abrir o lote.
      O resultado da procedure e capturado numa tabela temporaria porque
      ela devolve result set (formato que o SSIS consome). INSERT ... EXEC
      e a forma de ler isso a partir de outro script T-SQL.
      @fl_forcar = 1 aqui de proposito: durante o desenvolvimento voce vai
      querer rodar o mesmo arquivo varias vezes. Em producao seria 0. */
CREATE TABLE #lote (id_lote INT);
INSERT INTO #lote EXEC ctl.sp_abrir_lote @arq_contrato, @cedente, NULL, 1;
SELECT @id_lote = id_lote FROM #lote;
DROP TABLE #lote;

PRINT CONCAT('Lote aberto: ', @id_lote);

/* 2. Carregar contratos no staging.
      A tabela temporaria intermediaria existe porque o BULK INSERT exige
      que as colunas do arquivo batam exatamente com as da tabela de
      destino, e ele nao tem como preencher id_lote, que nao esta no
      arquivo. Entao le no formato do arquivo e depois insere em stg
      acrescentando o lote.
      O SSIS resolve isso de forma mais elegante com um Derived Column,
      que adiciona a coluna id_lote no meio do fluxo.

      Sobre as opcoes:
      FIRSTROW = 2      pula a linha de cabecalho
      FIELDTERMINATOR   o gerador grava com ponto e virgula
      ROWTERMINATOR 0x0a  quebra de linha estilo Unix. Se voce abrir o
                          arquivo no Bloco de Notas e salvar, vira 0x0d0a
                          e esta opcao passa a falhar
      CODEPAGE 65001    UTF-8, senao acento vira caractere estranho
      TABLOCK           bloqueia a tabela inteira e acelera a carga */
CREATE TABLE #contrato (
    cd_cedente VARCHAR(50), nu_contrato VARCHAR(50), nu_documento VARCHAR(50),
    nm_devedor VARCHAR(150), dt_nascimento VARCHAR(20), cd_produto VARCHAR(50),
    dt_contratacao VARCHAR(20), dt_vencimento VARCHAR(20), vl_principal VARCHAR(30),
    vl_atualizado VARCHAR(30), qt_dias_atraso VARCHAR(20), sg_uf VARCHAR(20),
    nu_telefone VARCHAR(30), ds_email VARCHAR(120)
);

SET @sql = N'BULK INSERT #contrato FROM ''' + @pasta + @arq_contrato + N'''
             WITH (FIRSTROW = 2, FIELDTERMINATOR = '';'', ROWTERMINATOR = ''0x0a'',
                   CODEPAGE = ''65001'', TABLOCK)';
EXEC sp_executesql @sql;

INSERT INTO stg.contrato_carteira
    (id_lote, cd_cedente, nu_contrato, nu_documento, nm_devedor, dt_nascimento,
     cd_produto, dt_contratacao, dt_vencimento, vl_principal, vl_atualizado,
     qt_dias_atraso, sg_uf, nu_telefone, ds_email)
SELECT @id_lote, cd_cedente, nu_contrato, nu_documento, nm_devedor, dt_nascimento,
       cd_produto, dt_contratacao, dt_vencimento, vl_principal, vl_atualizado,
       qt_dias_atraso, sg_uf, nu_telefone, ds_email
  FROM #contrato;

DROP TABLE #contrato;

/* 3. Carregar parcelas no staging, mesma logica. */
CREATE TABLE #parcela (
    cd_cedente VARCHAR(50), nu_contrato VARCHAR(50), nu_parcela VARCHAR(20),
    dt_vencimento VARCHAR(20), vl_parcela VARCHAR(30), ds_situacao VARCHAR(30)
);

SET @sql = N'BULK INSERT #parcela FROM ''' + @pasta + @arq_parcela + N'''
             WITH (FIRSTROW = 2, FIELDTERMINATOR = '';'', ROWTERMINATOR = ''0x0a'',
                   CODEPAGE = ''65001'', TABLOCK)';
EXEC sp_executesql @sql;

INSERT INTO stg.parcela_contrato
    (id_lote, cd_cedente, nu_contrato, nu_parcela, dt_vencimento, vl_parcela, ds_situacao)
SELECT @id_lote, cd_cedente, nu_contrato, nu_parcela, dt_vencimento, vl_parcela, ds_situacao
  FROM #parcela;

DROP TABLE #parcela;

/* 4. Validar e carregar.
      Sao as mesmas duas chamadas que o Execute SQL Task faz no SSIS. */
EXEC stg.sp_validar_lote  @id_lote;
EXEC crd.sp_carregar_lote @id_lote;

PRINT 'Pipeline executado.';
GO


/* =====================================================================
   PARTE 2 - CONSULTAS DE CONFERENCIA

   Estas sao as consultas que voce roda depois de cada carga e as que
   viram print no README. Cada uma responde a uma pergunta que alguem
   de verdade faria.
   ===================================================================== */

-- "O arquivo de hoje entrou?"
-- Panorama dos lotes com duracao de cada execucao.
SELECT id_lote, nm_arquivo, ds_status, qt_linhas_lidas, qt_linhas_ok, qt_linhas_rej,
       DATEDIFF(SECOND, dt_inicio, ISNULL(dt_fim, SYSDATETIME())) AS segundos
  FROM ctl.lote
 ORDER BY id_lote DESC;

-- "Em que etapa parou?"
-- Linha do tempo da execucao. E o primeiro lugar a olhar quando algo
-- falha de madrugada.
SELECT id_lote, ds_etapa, ds_mensagem, qt_linhas, ms_duracao, dt_registro
  FROM ctl.log_etapa
 ORDER BY id_log DESC;

-- "Por que tanta linha foi recusada?"
-- Ranking de motivos. E o relatorio mais util do projeto inteiro: quando
-- um motivo dispara de repente, quase sempre significa que o cedente
-- mudou o layout sem avisar.
SELECT g.cd_erro, g.ds_entidade, g.ds_severidade, g.ds_regra,
       COUNT(*) AS qt_ocorrencias
  FROM qua.registro_rejeitado r
  JOIN ctl.regra_validacao g ON g.cd_erro = r.cd_erro
 GROUP BY g.cd_erro, g.ds_entidade, g.ds_severidade, g.ds_regra
 ORDER BY qt_ocorrencias DESC;

-- "Me mostra exemplos do que foi recusado"
SELECT TOP (20) r.id_lote, r.ds_entidade, r.ds_chave, r.cd_erro, r.ds_valor, g.ds_regra
  FROM qua.registro_rejeitado r
  JOIN ctl.regra_validacao g ON g.cd_erro = r.cd_erro
 ORDER BY r.id_rejeicao DESC;

-- "Quanto entrou na base?"
SELECT (SELECT COUNT(*) FROM crd.devedor)  AS devedores,
       (SELECT COUNT(*) FROM crd.contrato) AS contratos,
       (SELECT COUNT(*) FROM crd.parcela)  AS parcelas;

-- "Como esta composta a carteira?"
-- O * 1.0 no AVG e proposital: sem ele, media de INT devolve INT e voce
-- perde as casas decimais sem receber nenhum aviso.
SELECT p.ds_produto,
       COUNT(*)                  AS qt_contratos,
       SUM(c.vl_atualizado)      AS vl_total,
       AVG(c.qt_dias_atraso * 1.0) AS media_dias_atraso
  FROM crd.contrato c
  JOIN crd.produto p ON p.cd_produto = c.cd_produto
 GROUP BY p.ds_produto
 ORDER BY vl_total DESC;

-- "Qual o aging da carteira?"
-- Visao classica de carteira inadimplente: quanto mais antigo o atraso,
-- menor a expectativa de recuperacao, e e isso que define a precificacao.
-- O prefixo numerico na faixa existe para a ordenacao alfabetica sair na
-- ordem correta.
SELECT CASE
         WHEN c.qt_dias_atraso <= 90  THEN '01. ate 90'
         WHEN c.qt_dias_atraso <= 180 THEN '02. 91 a 180'
         WHEN c.qt_dias_atraso <= 360 THEN '03. 181 a 360'
         WHEN c.qt_dias_atraso <= 720 THEN '04. 361 a 720'
         ELSE '05. acima de 720'
       END AS faixa_atraso,
       COUNT(*)             AS qt_contratos,
       SUM(c.vl_atualizado) AS vl_total
  FROM crd.contrato c
 GROUP BY CASE
         WHEN c.qt_dias_atraso <= 90  THEN '01. ate 90'
         WHEN c.qt_dias_atraso <= 180 THEN '02. 91 a 180'
         WHEN c.qt_dias_atraso <= 360 THEN '03. 181 a 360'
         WHEN c.qt_dias_atraso <= 720 THEN '04. 361 a 720'
         ELSE '05. acima de 720'
       END
 ORDER BY 1;

-- "O que eu devolvo para o cedente?"
DECLARE @ultimo INT = (SELECT MAX(id_lote) FROM ctl.lote);
EXEC exp.sp_gerar_retorno @ultimo;
GO


/* =====================================================================
   PARTE 3 - TESTE DE IDEMPOTENCIA

   POR QUE ESTE TESTE E O MAIS IMPORTANTE DO PROJETO
   Carga incremental que duplica dado e o defeito mais caro de pipeline
   de carteira, porque o erro so aparece semanas depois, na conciliacao,
   com o saldo inflado. Provar que rodar duas vezes nao muda a contagem e
   o que da confianca no desenho.

   Rode os passos abaixo em sequencia.
   ===================================================================== */
/*
-- Passo 1: contar antes
SELECT COUNT(*) AS contratos_antes FROM crd.contrato;

-- Passo 2: reexecutar a PARTE 1 inteira

-- Passo 3: contar depois
SELECT COUNT(*) AS contratos_depois FROM crd.contrato;
-- Esperado: exatamente o mesmo numero.
-- O MERGE identifica pela chave natural e atualiza em vez de inserir.

-- Passo 4: confirmar que a protecao de lote funciona.
-- Sem o @fl_forcar, a abertura precisa falhar.
EXEC ctl.sp_abrir_lote 'CONTRATOS_237_20260911.csv', '237';
-- Esperado: erro avisando que o arquivo ja foi carregado.

-- Passo 5: conferir que houve UPDATE e nao INSERT nas linhas que mudaram
SELECT TOP 10 nu_contrato, vl_atualizado, dt_inclusao, dt_atualizacao
  FROM crd.contrato
 WHERE dt_atualizacao IS NOT NULL
 ORDER BY dt_atualizacao DESC;
-- dt_inclusao continua a original, dt_atualizacao mostra a ultima carga.
*/
