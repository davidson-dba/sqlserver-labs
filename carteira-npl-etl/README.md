# Pipeline de ingestão de carteira de crédito inadimplente

Lab de ETL em SQL Server e SSIS que simula a operação de uma empresa de recuperação de crédito: receber arquivos de carteira cedida por bancos, validar, carregar de forma incremental e devolver um arquivo de retorno ao cedente.

> Projeto de estudo. Todos os dados são gerados sinteticamente, nenhum dado real é usado.

## O problema

Uma empresa que compra carteiras inadimplentes recebe diariamente arquivos de vários cedentes. Cada arquivo traz milhares de contratos com formatos inconsistentes: datas em três padrões diferentes, valores ora com vírgula ora com ponto, CPF com e sem máscara, registros duplicados e parcelas apontando para contratos que não existem.

Carregar isso direto na base de negócio gera cobrança indevida. Rejeitar o arquivo inteiro por causa de 3% de linhas ruins trava a operação.

A solução é um pipeline que separa o que é confiável do que não é, sem perder nada pelo caminho.

## O fluxo

```
arquivo do cedente
        |
        v
  [ ctl.sp_abrir_lote ]          abre o lote, barra arquivo já carregado
        |
        v
  [ SSIS Data Flow ]             move texto puro para o staging, sem converter nada
        |
        v
  stg.contrato_carteira
  stg.parcela_contrato
        |
        v
  [ stg.sp_validar_lote ]        15 regras cadastradas em tabela
        |
        +--- BLOQUEIA --> qua.registro_rejeitado   (quarentena, reprocessável)
        |
        v  ALERTA ou OK
  [ crd.sp_carregar_lote ]       MERGE por chave natural, idempotente
        |
        v
  crd.devedor / crd.contrato / crd.parcela
        |
        v
  [ exp.sp_gerar_retorno ]       arquivo de retorno com desfecho por linha
```

Tudo registrado em `ctl.lote` e `ctl.log_etapa`.

## Decisões técnicas

| Decisão | Por quê |
|---|---|
| Staging com todas as colunas em `VARCHAR` | Conversão é regra de negócio. Uma data mal formatada vira rejeição rastreável, não falha de pacote. |
| Regras de validação em tabela (`ctl.regra_validacao`) | Adicionar regra não exige refatorar a procedure de status. Severidade `BLOQUEIA` ou `ALERTA` é dado, não código. |
| Quarentena em vez de descarte | O registro rejeitado é insumo para o time de negócio corrigir a origem, não lixo. |
| `MERGE` por chave natural | Carga incremental idempotente. Rodar o mesmo arquivo duas vezes não duplica. |
| `WHEN MATCHED AND EXISTS (... EXCEPT ...)` | Só grava UPDATE quando algo realmente mudou, tratando NULL corretamente. |
| Índice único filtrado em `ctl.lote` | Barra o reprocessamento acidental antes de qualquer linha entrar no staging. |
| Regra de negócio fora do Data Flow | T-SQL é versionável, testável e legível sem abrir o Visual Studio. |

## Estrutura

```
sql/01_estrutura.sql              banco, schemas, tabelas, seed das regras
sql/02_functions.sql              validação de CPF/CNPJ, conversão defensiva
sql/03_procedures.sql             abertura de lote, validação, MERGE, exportação
sql/04_carga_manual_e_testes.sql  carga via BULK INSERT e consultas de conferência
gerador/gerar_carteira.py         gera arquivos sintéticos com defeitos propositais
docs/                             plano de execução, SSIS passo a passo, entrevista

Todos os scripts são comentados explicando o que cada bloco faz, por que
foi feito daquele jeito e qual alternativa foi descartada.
```

## Como rodar

Requisitos: SQL Server 2017 ou superior (usa `STRING_AGG`), Python 3.8+, e Visual Studio com a extensão Integration Services Projects para a parte de SSIS.

```bash
# 1. Gerar a massa de teste
cd gerador
python gerar_carteira.py --contratos 3000 --defeitos 0.10 --cedente 237
```

```sql
-- 2. No SSMS, na ordem
:r sql\01_estrutura.sql
:r sql\02_functions.sql
:r sql\03_procedures.sql

-- 3. Carga e conferência (ajuste o caminho da pasta no início do script)
:r sql\04_carga_manual_e_testes.sql

Para a versão com SSIS, ver `docs/02-ssis-passo-a-passo.md`.

## Regras de validação implementadas

**Contrato**: documento inválido pelo dígito verificador, nome ausente, data de contratação não convertível, data de contratação no futuro, valor principal inválido, valor atualizado menor que o principal (alerta), dias de atraso negativo, UF desconhecida (alerta), produto fora do catálogo, contrato duplicado no lote.

**Parcela**: parcela órfã sem contrato correspondente, vencimento inválido, valor inválido, número de parcela inválido, parcela duplicada no lote.

## Camada analítica

O schema `exp` expõe um modelo estrela para consumo no Power BI: um fato
de carteira no grão de contrato, um fato de qualidade de ingestão no grão
de lote, um fato de rejeição no grão de violação, mais dimensões de
cedente, produto, faixa de atraso e calendário.

O dashboard tem duas páginas: a visão da carteira (aging, composição por
produto, distribuição geográfica) e a visão de qualidade da ingestão
(taxa de rejeição por cedente ao longo do tempo, ranking de motivos,
drill-through para os registros concretos).

A segunda página é o ponto do projeto: mostrar não só o que foi carregado,
mas a qualidade do que chegou. O script `05_views_powerbi.sql` traz o
passo a passo da conexão, os relacionamentos e as medidas DAX.

## Limitações conhecidas

- As funções escalares de validação usadas em predicado do `WHERE` limitam paralelismo. Em volume alto, a abordagem seria materializar as colunas convertidas numa única passada ou usar função inline com valor de tabela.
- O `MERGE` em cargas de altíssima concorrência tem comportamentos documentados que exigem cuidado. Para volume industrial, vale comparar com `UPDATE` e `INSERT` separados.
- Não há particionamento nem estratégia de retenção do staging. Em produção, staging precisa de expurgo por data de lote.
